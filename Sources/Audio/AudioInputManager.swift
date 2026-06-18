import Foundation
import AVFoundation
import Observation
import os

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

    /// 현재 입력 소스 선택. nil이면 자동 선택 규칙(§5.2)에 따른다(BlackHole 우선 → 시스템 Tap).
    /// `.device(uid)` 또는 `.systemTap` 으로 사용자가 수동 강제할 수 있다.
    ///
    /// 초기값 결정(태스크 A):
    /// - SettingsStore에 사용자가 명시 선택한 값이 영속돼 있으면 **그 값 우선**.
    /// - 미설정(최초 실행 등)이면 14.4+에서 `.systemTap`(시스템 오디오 직접 캡처) 기본,
    ///   14.4 미만이면 `.auto`(BlackHole/마이크 폴백).
    private(set) var selection: InputSelection = .auto

    /// 입력 소스 선택 영속화 저장소. 수동 선택 시 저장하고, 초기 1회 복원한다.
    private let settings: SettingsStore?

    /// macOS 14.4+ 여부 — 시스템 오디오 직접 캡처(Core Audio Tap) 가용성.
    let systemTapAvailable: Bool = {
        if #available(macOS 14.4, *) { return true } else { return false }
    }()

    /// 캡처 실행 중 여부.
    private(set) var isCapturing = false

    /// 입력 레벨 (RMS, 0.0 ~ 1.0). 메뉴바 레벨 미터가 관찰한다.
    private(set) var level: Float = 0

    /// 마지막 캡처 오류 메시지 (권한 거부 등 UI 안내용).
    private(set) var lastErrorMessage: String? {
        didSet {
            // 오류 메시지 설정 시 진단 로그(키/URL 비포함 — UI 안내 문구).
            if let msg = lastErrorMessage {
                log.error("lastErrorMessage 설정: \(msg, privacy: .public)")
            }
        }
    }

    /// 진단 로그용 Logger(오디오 입력 흐름 추적). 민감정보(키) 미포함.
    /// 오디오 스레드(nonisolated 청크 콜백)에서도 쓰므로 nonisolated로 노출.
    nonisolated private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "AudioInput")

    /// 청크 forward 로그 스로틀 카운터(고빈도 경로). 오디오 스레드에서 증가하므로 스레드 안전 박스.
    /// 첫 1회 + 50회마다 1회만 로그한다.
    private let forwardLogCounter = ThrottleCounter()

    // MARK: - VAD (M1b)

    /// VAD 게이트 on/off (기본 on, 스펙 §9.4). off면 모든 청크를 그대로 forward(기존 동작).
    /// 캡처 중 토글 가능 — 다음 청크부터 즉시 반영된다.
    var vadEnabled = true {
        didSet { vadEnabledBox.value = vadEnabled }
    }

    /// 현재 발화중 여부(메뉴 상태 표시용). VAD off면 항상 false.
    private(set) var isSpeaking = false

    /// VAD 모델 준비 상태(다운로드 중/준비됨/사용 불가).
    private(set) var vadStatus: VADModelStatus = .notLoaded

    /// 오디오 스레드에서 읽는 VAD on/off 플래그 박스(메인 액터 격리 우회).
    private let vadEnabledBox = AtomicBool(true)

    /// Silero VAD 게이트(actor). 발화 구간만 `forwardBox`로 흘린다.
    private let vadGate: VADGate

    /// 외부(향후 VAD/Gemini)로 100ms 청크를 전달하는 훅.
    /// ⚠️ 실시간 오디오 스레드에서 호출됨 — 구현 측이 hop 책임.
    /// 실제 저장은 스레드 안전 박스(`forwardBox`)에 위임해 오디오 스레드가 안전하게 읽도록 한다.
    var onChunk: (@Sendable ([Float]) -> Void)? {
        get { forwardBox.handler }
        set { forwardBox.handler = newValue }
    }

    /// 오디오 스레드에서 읽는 전달 훅 박스 (메인 액터 격리 우회용).
    private let forwardBox = ChunkForwardBox()

    private var source: AudioSource?

    /// 캡처 세대 토큰. stop()/재시작마다 증가해 "이전 시작 의도"를 무효화한다.
    /// 비동기 권한 콜백(`AVCaptureDevice.requestAccess`)이 reconciler의 직렬 불변식
    /// 밖에서 도착하므로, 세대 토큰으로 정지 후 뒤늦은 start를 무효화한다.
    private var captureGeneration = 0

    init(settings: SettingsStore? = nil) {
        self.settings = settings
        // 게이트 콜백은 actor/오디오 스레드에서 호출되므로 @Sendable + 스레드 안전 박스 경유.
        let forwardBox = self.forwardBox
        // self 캡처 회피를 위해 콜백에서 쓰는 핸들들을 지역 상수로 먼저 만든다.
        let speakingSink = SpeakingSink()
        let statusSink = StatusSink()
        self.speakingSink = speakingSink
        self.statusSink = statusSink
        self.vadGate = VADGate(
            onSpeechChunk: { chunk in
                // 발화로 판정된 청크만 외부로 forward.
                forwardBox.handler?(chunk)
            },
            onSpeechStateChange: { speaking in
                speakingSink.update(speaking)
            },
            onStatusChange: { status in
                statusSink.update(status)
            }
        )
        speakingSink.onChange = { [weak self] speaking in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isSpeaking != speaking {
                    self.log.info("VAD 발화 전이: \(speaking ? "발화 시작" : "발화 종료", privacy: .public)")
                }
                self.isSpeaking = speaking
            }
        }
        statusSink.onChange = { [weak self] status in
            Task { @MainActor [weak self] in self?.vadStatus = status }
        }
        refreshDevices()
        applyInitialSelection()
        // 모델 로드(필요 시 HF 다운로드)는 1회. 실패해도 bypass로 graceful degrade.
        Task { await vadGate.prepare() }
    }

    /// 초기 입력 소스 선택을 결정한다(태스크 A).
    /// 1) 사용자가 영속한 값이 있으면 그것 우선(기존 영속 로직 존중).
    /// 2) 미설정이면 14.4+에서 `.systemTap` 기본, 미만이면 `.auto`(BlackHole/마이크 폴백).
    private func applyInitialSelection() {
        if let persisted = settings?.loadInputSelection() {
            selection = persisted
            return
        }
        selection = systemTapAvailable ? .systemTap : .auto
    }

    /// 발화 상태 변화를 메인 액터로 전달하는 싱크(콜백 → @Observable hop).
    private let speakingSink: SpeakingSink
    /// VAD 모델 상태 변화를 메인 액터로 전달하는 싱크.
    private let statusSink: StatusSink

    /// 현재 선택된 장치 (UID 매칭, 없으면 기본 입력, 그것도 없으면 첫 장치).
    /// `.systemTap` 선택 시에는 nil(장치가 아님).
    var selectedDevice: AudioInputDevice? {
        if case .systemTap = effectiveSelection { return nil }
        let uid: String?
        if case .device(let u) = effectiveSelection { uid = u } else { uid = selectedDeviceUID }
        if let uid, let match = devices.first(where: { $0.uid == uid }) {
            return match
        }
        if let defaultID = AudioDeviceEnumerator.defaultInputDeviceID(),
           let match = devices.first(where: { $0.id == defaultID }) {
            return match
        }
        return devices.first
    }

    /// 첫 BlackHole(루프백) 장치 — 자동 선택 §5.2(A) 판별용.
    var blackHoleDevice: AudioInputDevice? {
        devices.first(where: { $0.isLikelyLoopback })
    }

    /// 실제 사용할 소스 결정(자동/수동 통합). 스펙 §5.2 자동 선택 규칙:
    /// 사용자 수동 선택이 있으면 그것을 우선. `.auto`면 BlackHole 감지 시 BlackHole,
    /// 없고 14.4+면 시스템 Tap, 둘 다 아니면 기본/첫 입력 장치(마이크).
    var effectiveSelection: InputSelection {
        switch selection {
        case .device, .systemTap:
            return selection
        case .auto:
            if let bh = blackHoleDevice {
                return .device(bh.uid)
            }
            if systemTapAvailable {
                return .systemTap
            }
            if let dev = selectedDevice ?? devices.first {
                return .device(dev.uid)
            }
            return .auto
        }
    }

    /// 현재 사용 중(또는 사용 예정) 캡처 방식 사람이 읽는 라벨(메뉴 표시용).
    var activeSourceLabel: String {
        switch effectiveSelection {
        case .systemTap:
            return "시스템 오디오 (직접 캡처)"
        case .device:
            return selectedDevice?.name ?? "기본 입력"
        case .auto:
            return "자동"
        }
    }

    /// 입력 장치 목록 갱신.
    func refreshDevices() {
        devices = AudioDeviceEnumerator.inputDevices()
    }

    /// 입력 장치 선택(수동). 캡처 중이면 새 소스로 재시작한다(hot-swap).
    func selectDevice(_ device: AudioInputDevice) {
        log.info("selectDevice: 이전=\(self.selectionLabel, privacy: .public) → 이후=device(\(device.name, privacy: .public)) isCapturing=\(self.isCapturing, privacy: .public) hotSwap=\(self.isCapturing, privacy: .public)")
        selection = .device(device.uid)
        selectedDeviceUID = device.uid
        settings?.saveInputSelection(selection)
        restartIfCapturing()
    }

    /// 시스템 오디오 직접 캡처(Core Audio Tap) 선택(수동, 14.4+에서만).
    func selectSystemTap() {
        guard systemTapAvailable else {
            lastErrorMessage = AudioSourceError.systemTapUnavailable.errorDescription
            return
        }
        log.info("selectSystemTap: 이전=\(self.selectionLabel, privacy: .public) → 이후=systemTap isCapturing=\(self.isCapturing, privacy: .public) hotSwap=\(self.isCapturing, privacy: .public)")
        selection = .systemTap
        settings?.saveInputSelection(selection)
        restartIfCapturing()
    }

    /// 자동 선택으로 되돌린다(BlackHole 우선 → 시스템 Tap).
    func selectAuto() {
        log.info("selectAuto: 이전=\(self.selectionLabel, privacy: .public) → 이후=auto isCapturing=\(self.isCapturing, privacy: .public) hotSwap=\(self.isCapturing, privacy: .public)")
        selection = .auto
        settings?.saveInputSelection(selection)
        restartIfCapturing()
    }

    /// 현재 selection을 사람이 읽는 라벨로(로깅용 — 키/민감정보 없음).
    private var selectionLabel: String {
        switch selection {
        case .systemTap: return "systemTap"
        case .device(let uid): return "device(\(uid))"
        case .auto: return "auto"
        }
    }

    /// 캡처 중이면 현재 선택으로 재시작(입력 소스 hot-swap).
    ///
    /// 견고화(버그 수정): 이전에는 `try? start()`로 재시작 실패(-10877 등)를 삼켜
    /// `isCapturing`이 조용히 false로 남고, 그 값을 분기 기준으로 쓰던 상위 토글이
    /// 오작동했다. 이제 실패를 명시적으로 처리한다:
    /// - 성공: `isCapturing == true`, `lastErrorMessage == nil`.
    /// - 실패: `isCapturing == false`(좀비 상태 금지), `lastErrorMessage`에 안내 설정.
    ///   onChunk 배선(forwardBox)은 stop()이 건드리지 않으므로 그대로 유지된다 →
    ///   상위가 재시작 성공 시 즉시 청크가 다시 흐른다(번역 세션 배선 보존).
    ///
    /// 정지(`stop()`)와 시작(`start()`) 사이는 같은 MainActor 동기 구간이라
    /// 이전 소스 teardown이 새 소스 start보다 먼저 완료된다.
    private func restartIfCapturing() {
        guard isCapturing else { return }
        log.info("restartIfCapturing: 재시작 시도(hot-swap)")
        stop()
        do {
            try start()
            log.info("restartIfCapturing: 재시작 성공")
        } catch {
            // -10877(kAudioUnitErr_InvalidElement 류)은 입력 전환 과도기에 흔히 발생하나 무해할 수 있다.
            let ns = error as NSError
            let harmless = ns.code == -10877 ? " (-10877 — 입력 전환 과도기, 보통 무해)" : ""
            log.error("restartIfCapturing: 재시작 실패 code=\(ns.code, privacy: .public)\(harmless, privacy: .public)")
            // start() 내부에서 lastErrorMessage가 이미 설정된다. isCapturing은 false 유지.
            // 상위(AppState)는 isRunning(사용자 의도)을 단일 진실로 쓰므로, 여기서
            // isCapturing이 false여도 "정지" 버튼이 "시작"으로 뒤집히지 않는다.
        }
    }

    /// 캡처 시작. 권한을 먼저 요청한 뒤 엔진을 켠다.
    func start() throws {
        guard !isCapturing else { return }

        // 진단: 시작 시점의 선택 소스/장치/세대/VAD 상태(저빈도 — 매번).
        let sourceLabel: String
        switch effectiveSelection {
        case .systemTap: sourceLabel = "systemTap"
        case .device: sourceLabel = "device"
        case .auto: sourceLabel = "auto"
        }
        log.info("start() 진입: 소스=\(sourceLabel, privacy: .public) 장치=\(self.selectedDevice?.name ?? "(none)", privacy: .public) captureGeneration=\(self.captureGeneration, privacy: .public) VAD=\(self.vadEnabled ? "on" : "off", privacy: .public)")

        // 선택(자동/수동)에 따라 적절한 AudioSource 구현을 만든다.
        let source: AudioSource
        do {
            source = try makeSource()
        } catch {
            log.error("start() 실패(makeSource): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let forwardBox = self.forwardBox
        let vadEnabledBox = self.vadEnabledBox
        let vadGate = self.vadGate
        let log = self.log
        let forwardLogCounter = self.forwardLogCounter
        source.onChunk = { [weak self] chunk in
            // 실시간 오디오 스레드. RMS는 여기서 계산하고 메인 액터로 hop.
            let rms = Self.computeRMS(chunk)
            Task { @MainActor [weak self] in
                self?.level = rms
            }
            // 진단(고빈도 — 스로틀: 첫 1회 + 50회마다): VAD on/off 분기와 RMS 레벨.
            if forwardLogCounter.shouldLog(every: 50) {
                if vadEnabledBox.value {
                    log.debug("청크 수신: 분기=VAD 게이트로 제출 rms=\(rms, privacy: .public) samples=\(chunk.count, privacy: .public)")
                } else {
                    log.debug("청크 수신: 분기=직접 forward rms=\(rms, privacy: .public) samples=\(chunk.count, privacy: .public)")
                }
            }
            // M1b VAD 게이트: on이면 actor로 넘겨 발화 구간만 forward, off면 그대로 forward.
            if vadEnabledBox.value {
                vadGate.submit(chunk)
            } else {
                forwardBox.handler?(chunk)
            }
        }
        // 새 캡처 시작 시 스트림 상태 초기화(이전 발화 흔적 제거).
        Task { await vadGate.resetStream() }

        do {
            try source.start()
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("start() 실패(source.start): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        self.source = source
        isCapturing = true
        lastErrorMessage = nil
        log.info("start() 성공: isCapturing=true 소스=\(sourceLabel, privacy: .public)")
    }

    /// 현재 선택(자동/수동)에 맞는 AudioSource 구현을 생성한다.
    /// - `.systemTap`: Core Audio Process Tap(14.4+) 직접 캡처.
    /// - 그 외: 마이크/BlackHole 등 입력 장치 → AVAudioEngine 캡처.
    private func makeSource() throws -> AudioSource {
        switch effectiveSelection {
        case .systemTap:
            guard systemTapAvailable else { throw AudioSourceError.systemTapUnavailable }
            return SystemTapAudioSource()
        case .device, .auto:
            guard let device = selectedDevice else {
                throw AudioSourceError.invalidInputFormat
            }
            return EngineAudioSource(device: device)
        }
    }

    /// 캡처 정지.
    func stop() {
        // 세대 증가 → 진행 중인 비동기 권한 콜백의 늦은 start()를 무효화(좀비 캡처 방지).
        captureGeneration += 1
        log.info("stop(): captureGeneration=\(self.captureGeneration, privacy: .public)")
        source?.stop()
        source = nil
        isCapturing = false
        level = 0
        isSpeaking = false
        // 게이트 스트림 상태도 정리(발화중 false 통지 포함).
        Task { await vadGate.resetStream() }
    }

    /// 권한 처리 후 캡처 시작 (메뉴 "번역 시작" 진입점).
    ///
    /// - 시스템 Tap 선택 시: 마이크 권한 불필요. 첫 tap 생성 시 OS가 시스템 오디오 캡처 TCC
    ///   프롬프트를 띄운다. 거부/대기면 `start()`가 throw → `lastErrorMessage`로 안내(앱은 살아있음).
    /// - 그 외(마이크/BlackHole): 기존대로 마이크 권한 요청 후 시작.
    func requestPermissionAndStart() {
        if case .systemTap = effectiveSelection {
            // 시스템 오디오 직접 캡처 — 마이크 권한 단계 없이 바로 시작 시도.
            log.info("requestPermissionAndStart: 경로=systemTap(권한 단계 없음)")
            refreshDevices()
            do {
                try start()
            } catch {
                // start 내부에서 lastErrorMessage 설정됨(권한 거부 안내 포함).
            }
            return
        }
        log.info("requestPermissionAndStart: 경로=mic(권한 요청)")
        // 비동기 권한 콜백은 reconciler의 직렬 불변식 밖에서 도착한다. 권한 요청 직전의
        // 세대를 캡처해 두고, 콜백에서 start() 직전에 동일 세대인지 확인한다. 그 사이
        // stop()이 호출됐다면(세대 증가) 시작을 취소해 정지 후 좀비 캡처를 막는다.
        let gen = captureGeneration
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log.info("마이크 권한 결과: \(granted ? "granted" : "denied", privacy: .public)")
                guard granted else {
                    self.lastErrorMessage = AudioSourceError.permissionDenied.errorDescription
                    return
                }
                // 권한 프롬프트 동안 stop()이 끼어들었으면(세대 불일치) 시작하지 않는다.
                guard gen == self.captureGeneration else {
                    self.log.info("권한 콜백 늦은 start 취소: captureGeneration 가드(요청시=\(gen, privacy: .public) 현재=\(self.captureGeneration, privacy: .public))")
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

/// 고빈도 경로의 로그 스로틀용 스레드 안전 카운터.
/// 오디오 스레드 등 여러 스레드에서 호출될 수 있어 락으로 보호한다.
/// `shouldLog(every:)`는 1번째 호출과 N번째마다 true를 반환한다.
final class ThrottleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func shouldLog(every n: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count == 1 || count % n == 0
    }
}

/// 오디오 스레드에서 읽고 메인 액터에서 쓰는 VAD on/off 플래그(락 기반).
private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ initial: Bool) { _value = initial }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// VAD actor의 발화 상태 콜백을 받아 메인 액터로 중계하는 싱크.
/// 콜백은 actor 컨텍스트(@Sendable)에서, `onChange` 설정은 메인 액터에서 일어나므로 락 보호.
private final class SpeakingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _onChange: (@Sendable (Bool) -> Void)?
    var onChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }
    func update(_ speaking: Bool) { onChange?(speaking) }
}

/// VAD actor의 모델 상태 콜백을 받아 메인 액터로 중계하는 싱크.
private final class StatusSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _onChange: (@Sendable (VADModelStatus) -> Void)?
    var onChange: (@Sendable (VADModelStatus) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }
    func update(_ status: VADModelStatus) { onChange?(status) }
}
