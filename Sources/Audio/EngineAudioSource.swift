import Foundation
import AVFoundation
import CoreAudio

/// AVAudioEngine 기반 `AudioSource` 구현 (스펙 §5.2 공통 파이프라인).
///
/// 마이크와 BlackHole 같은 가상 루프백 장치를 **동일 코드로** 캡처한다.
/// 둘 다 Core Audio 입력 장치이므로 inputNode의 AUAudioUnit `deviceID`만 바꿔주면 된다.
///
/// 흐름:
///   inputNode tap (장치 native 포맷)
///     → AVAudioConverter (→ 16kHz / mono / Float32)
///     → 1600-sample(100ms) 청크로 누적
///     → onChunk 콜백
///
/// ⚠️ 동시성: tap 블록과 청크 누적 버퍼는 실시간 오디오 스레드에서 실행된다.
/// 직렬 처리(같은 스레드에서 tap이 순차 호출됨)이며 외부 공유 가변 상태를 만지지 않는다.
/// `onChunk`는 `@Sendable`이라 메인 액터 hop 책임을 콜백 측에 위임한다.
final class EngineAudioSource: AudioSource, @unchecked Sendable {

    let name: String
    let kind: AudioSourceKind

    /// nonisolated(unsafe): tap 스레드에서 읽기만 한다. start 이후 변경하지 않는다.
    var onChunk: (@Sendable ([Float]) -> Void)?

    private let deviceID: AudioDeviceID
    private let engine = AVAudioEngine()

    /// 목표 출력 포맷: 16kHz mono Float32 (비-interleaved).
    private let targetFormat: AVAudioFormat

    /// 변환기는 입력 포맷이 정해지는 start 시점에 생성한다.
    private var converter: AVAudioConverter?

    /// 100ms 청크 누적 버퍼. tap 스레드 단독 접근.
    private var pendingSamples: [Float] = []

    private var isRunning = false

    init(device: AudioInputDevice) {
        self.deviceID = device.id
        self.name = device.name
        self.kind = device.isLikelyLoopback ? .loopback : .microphone
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AppConfig.audioSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("16kHz mono Float32 포맷 생성 실패 (불가능한 경우)")
        }
        self.targetFormat = format
        self.pendingSamples.reserveCapacity(AppConfig.audioChunkSampleCount * 2)
    }

    func start() throws {
        guard !isRunning else { return }

        // 입력 장치를 엔진 inputNode의 하드웨어 장치로 지정.
        // AVAudioEngine은 inputNode를 만질 때 내부적으로 AUHAL을 구성하므로
        // auAudioUnit.deviceID 설정으로 캡처 대상 장치를 강제한다.
        let inputNode = engine.inputNode
        try setDevice(deviceID, on: inputNode)

        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioSourceError.invalidInputFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioSourceError.converterUnavailable
        }
        self.converter = converter
        pendingSamples.removeAll(keepingCapacity: true)

        // tap 버퍼 크기는 장치 native sampleRate 기준 ~100ms. 변환 후 청크화는 누적기로 정밀 제어.
        let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1)

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) {
            [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        pendingSamples.removeAll(keepingCapacity: true)
        isRunning = false
    }

    // MARK: - Capture pipeline (실시간 오디오 스레드)

    /// tap 버퍼를 목표 포맷으로 변환하고 100ms 청크로 누적/방출한다.
    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        // 변환 후 프레임 수 추정 (sampleRate 비율). 여유분 포함.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard capacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        // 단일 입력 버퍼를 한 번만 공급. strict concurrency가 inputBlock을 @Sendable로
        // 추론하므로, 가변 플래그/버퍼는 참조 박스에 담아 캡처 안전성을 확보한다.
        let feed = ConverterFeed(buffer: buffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            feed.next(outStatus)
        }

        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
        guard status == .haveData || status == .inputRanDry,
              let channelData = outBuffer.floatChannelData,
              outBuffer.frameLength > 0
        else { return }

        let frames = Int(outBuffer.frameLength)
        let samples = UnsafeBufferPointer(start: channelData[0], count: frames)
        pendingSamples.append(contentsOf: samples)

        emitChunksIfReady()
    }

    /// 누적 버퍼에서 1600-sample 청크를 가능한 만큼 떼어내 콜백한다.
    private func emitChunksIfReady() {
        let chunkSize = AppConfig.audioChunkSampleCount
        while pendingSamples.count >= chunkSize {
            let chunk = Array(pendingSamples.prefix(chunkSize))
            pendingSamples.removeFirst(chunkSize)
            onChunk?(chunk)
        }
    }

    // MARK: - Device selection

    /// inputNode의 AUAudioUnit에 캡처 장치를 지정한다.
    /// macOS의 `AUAudioUnit.setDeviceID(_:)`는 AUHAL의 현재 입력 장치를 바꾼다.
    private func setDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) throws {
        do {
            try inputNode.auAudioUnit.setDeviceID(deviceID)
        } catch {
            throw AudioSourceError.deviceSelectionFailed(OSStatus((error as NSError).code))
        }
    }
}

/// AVAudioConverter 입력 블록용 1회성 버퍼 공급 박스.
/// strict concurrency가 입력 블록을 @Sendable로 추론하므로 가변 상태를 클래스로 격리한다.
private final class ConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// 첫 호출에만 버퍼를 내주고, 이후에는 데이터 없음을 알린다.
    func next(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        guard let b = buffer else {
            outStatus.pointee = .noDataNow
            return nil
        }
        buffer = nil
        outStatus.pointee = .haveData
        return b
    }
}

/// 캡처 백엔드 오류.
enum AudioSourceError: Error, LocalizedError {
    case invalidInputFormat
    case converterUnavailable
    case deviceSelectionFailed(OSStatus)
    case permissionDenied
    // MARK: - System Tap (M1c)
    /// macOS 14.4 미만 — Core Audio Process Tap 미지원.
    case systemTapUnavailable
    /// AudioHardwareCreateProcessTap 실패(권한 거부/대기 포함 가능).
    case systemTapCreationFailed(OSStatus)
    /// AudioHardwareCreateAggregateDevice 실패.
    case systemTapAggregateFailed(OSStatus)
    /// kAudioTapPropertyFormat 읽기 실패.
    case systemTapFormatFailed(OSStatus)
    /// AudioDeviceCreateIOProcIDWithBlock 실패.
    case systemTapIOProcFailed(OSStatus)
    /// AudioDeviceStart 실패.
    case systemTapStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "입력 장치의 오디오 포맷을 읽을 수 없습니다."
        case .converterUnavailable:
            return "오디오 포맷 변환기를 생성할 수 없습니다."
        case .deviceSelectionFailed(let status):
            return "입력 장치 선택 실패 (OSStatus \(status))."
        case .permissionDenied:
            return "마이크 권한이 거부되었습니다. 시스템 설정에서 허용해 주세요."
        case .systemTapUnavailable:
            return "시스템 오디오 직접 캡처는 macOS 14.4 이상이 필요합니다. BlackHole 설치를 권장합니다."
        case .systemTapCreationFailed:
            return "시스템 오디오 캡처 권한이 필요합니다. 시스템 설정에서 허용해 주세요."
        case .systemTapAggregateFailed(let status):
            return "시스템 오디오 캡처 장치 생성 실패 (OSStatus \(status))."
        case .systemTapFormatFailed(let status):
            return "시스템 오디오 포맷을 읽을 수 없습니다 (OSStatus \(status))."
        case .systemTapIOProcFailed(let status):
            return "시스템 오디오 IO 등록 실패 (OSStatus \(status))."
        case .systemTapStartFailed(let status):
            return "시스템 오디오 캡처 시작 실패 (OSStatus \(status))."
        }
    }
}
