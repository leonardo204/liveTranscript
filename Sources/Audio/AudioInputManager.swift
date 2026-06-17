import Foundation
import AVFoundation
import Observation

/// 입력 소스 목록/선택/캡처 수명주기 + 레벨 미터를 관리하는 상위 코디네이터 (스펙 §4.1).
///
/// - 입력 장치 목록 노출 (`devices`)
/// - 현재 선택 장치 관리 (`selectedDeviceID`)
/// - start/stop으로 `EngineAudioSource` 생성/해제
/// - tap 청크에서 RMS 레벨 계산 → `level`(0~1)로 메인 액터에 발행 (메뉴바 미터용)
/// - 청크를 외부(향후 VAD/GeminiLiveClient)로 전달하는 훅(`onChunk`) 제공
///
/// VAD 삽입 지점(M1b): `EngineAudioSource.onChunk` → 여기서 RMS 계산 후
/// `forwardChunk(_:)`를 통해 외부로 전달한다. M1b에서는 이 사이에 Silero VAD 게이트를 끼운다.
@MainActor
@Observable
final class AudioInputManager {

    /// 열거된 입력 장치 목록.
    private(set) var devices: [AudioInputDevice] = []

    /// 현재 선택된 입력 장치 UID (영속화 친화적 식별자). nil이면 기본 입력.
    private(set) var selectedDeviceUID: String?

    /// 캡처 실행 중 여부.
    private(set) var isCapturing = false

    /// 입력 레벨 (RMS, 0.0 ~ 1.0). 메뉴바 레벨 미터가 관찰한다.
    private(set) var level: Float = 0

    /// 마지막 캡처 오류 메시지 (권한 거부 등 UI 안내용).
    private(set) var lastErrorMessage: String?

    /// 외부(향후 VAD/Gemini)로 100ms 청크를 전달하는 훅.
    /// ⚠️ 실시간 오디오 스레드에서 호출됨 — 구현 측이 hop 책임.
    /// 실제 저장은 스레드 안전 박스(`forwardBox`)에 위임해 오디오 스레드가 안전하게 읽도록 한다.
    var onChunk: (@Sendable ([Float]) -> Void)? {
        get { forwardBox.handler }
        set { forwardBox.handler = newValue }
    }

    /// 오디오 스레드에서 읽는 전달 훅 박스 (메인 액터 격리 우회용).
    private let forwardBox = ChunkForwardBox()

    private var source: EngineAudioSource?

    init() {
        refreshDevices()
    }

    /// 현재 선택된 장치 (UID 매칭, 없으면 기본 입력, 그것도 없으면 첫 장치).
    var selectedDevice: AudioInputDevice? {
        if let uid = selectedDeviceUID,
           let match = devices.first(where: { $0.uid == uid }) {
            return match
        }
        if let defaultID = AudioDeviceEnumerator.defaultInputDeviceID(),
           let match = devices.first(where: { $0.id == defaultID }) {
            return match
        }
        return devices.first
    }

    /// 입력 장치 목록 갱신.
    func refreshDevices() {
        devices = AudioDeviceEnumerator.inputDevices()
    }

    /// 입력 소스 선택. 캡처 중이면 새 장치로 재시작한다(hot-swap).
    func selectDevice(_ device: AudioInputDevice) {
        selectedDeviceUID = device.uid
        guard isCapturing else { return }
        stop()
        try? start()
    }

    /// 캡처 시작. 권한을 먼저 요청한 뒤 엔진을 켠다.
    func start() throws {
        guard !isCapturing else { return }
        guard let device = selectedDevice else {
            throw AudioSourceError.invalidInputFormat
        }

        let source = EngineAudioSource(device: device)
        let forwardBox = self.forwardBox
        source.onChunk = { [weak self] chunk in
            // 실시간 오디오 스레드. RMS는 여기서 계산하고 메인 액터로 hop.
            let rms = Self.computeRMS(chunk)
            Task { @MainActor [weak self] in
                self?.level = rms
            }
            // 외부 전달 훅 (M1b VAD 삽입 지점). 스레드 안전 박스를 통해 읽는다.
            forwardBox.handler?(chunk)
        }

        do {
            try source.start()
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }

        self.source = source
        isCapturing = true
        lastErrorMessage = nil
    }

    /// 캡처 정지.
    func stop() {
        source?.stop()
        source = nil
        isCapturing = false
        level = 0
    }

    /// 마이크 권한 요청 후 캡처 시작 (메뉴 "번역 시작" 진입점).
    func requestPermissionAndStart() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.lastErrorMessage = AudioSourceError.permissionDenied.errorDescription
                    return
                }
                self.refreshDevices()
                do {
                    try self.start()
                } catch {
                    // start 내부에서 lastErrorMessage 설정됨.
                }
            }
        }
    }

    // MARK: - RMS

    /// 청크의 RMS(0~1)를 계산한다. 무음=0, 풀스케일 사인≈0.707.
    /// 가독성을 위해 살짝 부스트(×1.4)하되 1.0 클램프.
    nonisolated private static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        return min(rms * 1.4, 1.0)
    }
}

/// 청크 전달 훅을 메인 액터와 오디오 스레드 간에 안전하게 공유하는 박스.
/// 락으로 핸들러 참조 읽기/쓰기를 보호한다(핸들러 교체는 드물고, 읽기는 매 청크).
private final class ChunkForwardBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: (@Sendable ([Float]) -> Void)?

    var handler: (@Sendable ([Float]) -> Void)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
}
