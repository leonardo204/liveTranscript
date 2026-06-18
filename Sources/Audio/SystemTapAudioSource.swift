import Foundation
import AVFoundation
import CoreAudio
import OSLog

/// Core Audio Process Tap 기반 시스템 오디오 직접 캡처 `AudioSource` (스펙 §5.2 (B)).
///
/// macOS **14.4+** 의 Core Audio Process Tap API로 시스템 출력 오디오를 직접 캡처한다.
/// BlackHole 등 가상 루프백 장치 설치가 **불필요**하고, ScreenCaptureKit과 달리
/// **화면 녹화 권한도 불필요**하다(오디오 캡처 TCC 권한만 첫 tap 생성 시 요구).
///
/// ## SDK 심볼 근거 (헤더에서 확인, 추측 아님)
/// - `CATapDescription(monoGlobalTapButExcludeProcesses:)` — CATapDescription.h
///   (`initMonoGlobalTapButExcludeProcesses:` + `NS_REFINED_FOR_SWIFT`)
/// - `AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap` — AudioHardwareTapping.h (macos 14.2)
/// - `AudioHardwareCreateAggregateDevice` / `AudioHardwareDestroyAggregateDevice` — AudioHardware.h
/// - aggregate dict 키: `kAudioAggregateDeviceUIDKey`("uid"), `kAudioAggregateDeviceIsPrivateKey`("private"),
///   `kAudioAggregateDeviceTapListKey`("taps"), `kAudioAggregateDeviceTapAutoStartKey`("tapautostart"),
///   sub-tap 키 `kAudioSubTapUIDKey`("uid"), `kAudioSubTapDriftCompensationKey`("drift") — AudioHardware.h
/// - tap 포맷: `kAudioTapPropertyFormat`('tfmt', AudioStreamBasicDescription) — AudioHardware.h
/// - IO: `AudioDeviceCreateIOProcIDWithBlock` / `AudioDeviceDestroyIOProcID` /
///   `AudioDeviceStart` / `AudioDeviceStop` — AudioHardware.h
///
/// ## 흐름 (AudioCap[insidegui/AudioCap] 패턴)
///   1. CATapDescription(monoGlobalTapButExcludeProcesses: []) → 전체 시스템 mono, unmuted(소리 유지)
///   2. AudioHardwareCreateProcessTap → tapID
///   3. AudioHardwareCreateAggregateDevice(private + taps=[tap]) → aggregateID
///   4. kAudioTapPropertyFormat 로 tap 스트림 포맷(보통 48kHz float) 읽기
///   5. AudioDeviceCreateIOProcIDWithBlock → IO 블록 등록
///   6. AudioDeviceStart → 캡처 시작
///   IO 블록 raw 버퍼 → AVAudioConverter(→16kHz mono Float32) → 1600샘플(100ms) 청크 → onChunk
///
/// ## 리소스 정리 (역순, 누수 방지)
///   stop/deinit: AudioDeviceStop → AudioDeviceDestroyIOProcID → AudioHardwareDestroyAggregateDevice
///                → AudioHardwareDestroyProcessTap. 부분 생성 실패 시에도 생성된 것만 역순 해제.
///
/// ## 동시성
/// IO 블록은 실시간 오디오 스레드(전용 dispatch queue)에서 호출된다. self 강참조 캡처 대신
/// 변환/누적 상태를 `@unchecked Sendable` 박스(`TapCaptureSink`)에 격리해 캡처 안전성을 확보한다.
/// `onChunk`는 `@Sendable`이라 메인 액터 hop 책임을 콜백 측에 둔다(M1a 패턴 일관).
final class SystemTapAudioSource: AudioSource, @unchecked Sendable {

    let name: String
    let kind: AudioSourceKind = .systemTap

    var onChunk: (@Sendable ([Float]) -> Void)? {
        get { sink.onChunk }
        set { sink.onChunk = newValue }
    }

    private let logger = Logger(subsystem: AppConfig.bundleIdentifier, category: "SystemTapAudioSource")

    /// 변환/청크 누적/콜백을 격리하는 실시간 스레드용 싱크.
    private let sink = TapCaptureSink()

    /// IO 블록이 실행되는 전용 시리얼 큐(실시간 우선순위 권장).
    private let ioQueue = DispatchQueue(label: "com.altimedia.liveTranslate.systemtap.io", qos: .userInitiated)

    // Core Audio 객체 핸들 (생성 역순 해제 추적용). 0/nil = 미생성.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var isRunning = false

    /// teardown 완료 여부(중복 teardown 조기 반환용). start()에서 새 세션 시작 시 false로 리셋.
    private var tornDown = false

    init() {
        self.name = "시스템 오디오 (직접 캡처)"
    }

    deinit {
        teardown()
    }

    // MARK: - AudioSource

    func start() throws {
        guard #available(macOS 14.4, *) else {
            throw AudioSourceError.systemTapUnavailable
        }
        guard !isRunning else { return }
        tornDown = false   // 새 세션 시작 — 다음 teardown은 정상 수행되어야 한다.

        do {
            try setupTap()
            try setupAggregateDevice()
            let asbd = try readTapFormat()
            try setupConverter(from: asbd)
            try setupIOProc()
            try startIO()
            isRunning = true
            lastErrorWasPermission = false
        } catch {
            // 부분 생성된 자원을 역순으로 정리하고 에러를 그대로 전달.
            teardown()
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        teardown()
        isRunning = false
    }

    // MARK: - Setup steps (모두 14.4+ 가드 하에서만 호출됨)

    /// 1~2단계: 전체 시스템 mono tap 생성(unmuted = 소리 그대로 들림).
    @available(macOS 14.4, *)
    private func setupTap() throws {
        // 피드백 루프 방지(핵심): 우리 앱 자신의 프로세스를 탭에서 **제외**한다.
        // 번역 오디오 재생을 켜면 우리 앱이 출력하는 번역 음성이 전체 시스템 탭에 다시
        // 잡혀 입력으로 되돌아가고(loopback), 모델이 자기 출력을 재번역해 같은 구절이
        // 무한 반복된다. 자기 프로세스를 제외하면 원본 콘텐츠 소리만 캡처되고 번역 출력은
        // 잡히지 않아 피드백이 끊긴다. (제외 ID 조회 실패 시 빈 목록으로 폴백 — 기존 동작.)
        let excluded = Self.currentProcessAudioObjectID().map { [$0] } ?? []
        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        tapDesc.name = "liveTranslate System Tap"
        tapDesc.isPrivate = true            // 이 클라이언트만 보이는 tap
        tapDesc.muteBehavior = .unmuted     // 캡처만, 시스템 소리는 정상 재생

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard status == noErr, newTapID != AudioObjectID(kAudioObjectUnknown) else {
            // 권한 거부/대기 시 tap 생성이 실패할 수 있다 → 권한 안내로 graceful 처리.
            lastErrorWasPermission = true
            logger.error("AudioHardwareCreateProcessTap failed: \(status)")
            throw AudioSourceError.systemTapCreationFailed(status)
        }
        tapID = newTapID
        tapUUIDString = tapDesc.uuid.uuidString
    }

    /// 우리 앱 자신의 Core Audio 프로세스 객체 ID를 조회한다(탭 제외 목록용).
    /// PID → AudioObjectID 변환(kAudioHardwarePropertyTranslatePIDToProcessObject). 실패 시 nil.
    private static func currentProcessAudioObjectID() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    /// tap의 UUID 문자열(aggregate sub-tap 구성에 사용).
    private var tapUUIDString: String = ""

    /// 권한 거부/대기로 인한 실패 여부(UI 안내 분기용).
    private(set) var lastErrorWasPermission = false

    /// 3단계: private aggregate device 생성(서브탭으로 위 tap 포함, 자동 시작).
    @available(macOS 14.4, *)
    private func setupAggregateDevice() throws {
        // aggregate UID는 충돌 없이 고유해야 한다. bundleID + 고정 접미사(결정적 문자열, 난수/Date 미사용).
        let aggregateUID = "\(AppConfig.bundleIdentifier).systemtap.aggregate"

        let subTap: [String: Any] = [
            kAudioSubTapUIDKey: tapUUIDString,
            kAudioSubTapDriftCompensationKey: true,
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [subTap],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != AudioObjectID(kAudioObjectUnknown) else {
            logger.error("AudioHardwareCreateAggregateDevice failed: \(status)")
            throw AudioSourceError.systemTapAggregateFailed(status)
        }
        aggregateID = newAggregateID
    }

    /// 4단계: tap 스트림 포맷(ASBD) 읽기 (보통 48kHz float, mono).
    @available(macOS 14.4, *)
    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            logger.error("read kAudioTapPropertyFormat failed: \(status)")
            throw AudioSourceError.systemTapFormatFailed(status)
        }
        return asbd
    }

    /// 5단계: tap ASBD → 16kHz mono Float32 변환기 준비.
    private func setupConverter(from asbd: AudioStreamBasicDescription) throws {
        var inputASBD = asbd
        guard let inputFormat = AVAudioFormat(streamDescription: &inputASBD) else {
            throw AudioSourceError.invalidInputFormat
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AppConfig.audioSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioSourceError.invalidInputFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioSourceError.converterUnavailable
        }
        sink.configure(inputFormat: inputFormat, targetFormat: targetFormat, converter: converter)
    }

    /// 6단계: aggregate device에 IO 블록 등록.
    @available(macOS 14.4, *)
    private func setupIOProc() throws {
        let sink = self.sink
        let block: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            // 실시간 오디오 스레드(ioQueue). self 강참조 없이 sink 박스로만 처리.
            sink.process(inputData: inInputData)
        }
        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue, block)
        guard status == noErr, let procID = newProcID else {
            logger.error("AudioDeviceCreateIOProcIDWithBlock failed: \(status)")
            throw AudioSourceError.systemTapIOProcFailed(status)
        }
        ioProcID = procID
    }

    /// 7단계: 캡처 시작.
    @available(macOS 14.4, *)
    private func startIO() throws {
        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            logger.error("AudioDeviceStart failed: \(status)")
            throw AudioSourceError.systemTapStartFailed(status)
        }
    }

    // MARK: - Teardown (역순 해제, 누수 방지)

    /// 생성된 자원만 역순(Start→IOProc→Aggregate→Tap)으로 해제한다.
    /// 정상 stop / start 도중 실패 / deinit 모두 이 경로를 공유한다.
    ///
    /// 견고화(버그 수정): 입력 소스 hot-swap 시 stop()→teardown() 후 deinit에서 또
    /// teardown()이 불릴 수 있다. 이미 해제/0으로 만든 핸들을 다시 파괴하면
    /// `-10877`(kAudioHardwareBadObjectError) / "no object with given ID" /
    /// "ObjectHasProperty: no object" 로그가 쏟아진다. 아래 가드로:
    /// - 각 단계는 핸들이 유효할 때만 호출하고, 호출 직후 즉시 0/nil로 만들어
    ///   재진입(중복 teardown)이 무해하도록 한다(멱등).
    /// - `tornDown` 플래그로 완전 정리 후 재호출을 조기 반환한다.
    /// - `-10877`은 "이미 사라진 객체" 신호로 보고 debug 수준으로만 남겨 무해화한다.
    private func teardown() {
        // 이미 완전히 정리됐고 새로 생성된 핸들이 없으면 조기 반환(중복 teardown 무해).
        if tornDown
            && aggregateID == AudioObjectID(kAudioObjectUnknown)
            && tapID == AudioObjectID(kAudioObjectUnknown)
            && ioProcID == nil {
            return
        }

        // 1) IO 정지 + 2) IOProc 제거 (aggregate와 procID가 모두 유효할 때만).
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let procID = ioProcID {
            logIfRealError("AudioDeviceStop", AudioDeviceStop(aggregateID, procID))
            logIfRealError("AudioDeviceDestroyIOProcID", AudioDeviceDestroyIOProcID(aggregateID, procID))
        }
        ioProcID = nil

        // 3) aggregate device 파괴. 호출 직후 즉시 무효화 → 재진입 시 재파괴 안 함.
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            let id = aggregateID
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            logIfRealError("AudioHardwareDestroyAggregateDevice", AudioHardwareDestroyAggregateDevice(id))
        }
        // 4) tap 파괴 (14.2+ 심볼이나 우리는 14.4+에서만 생성하므로 안전).
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            let id = tapID
            tapID = AudioObjectID(kAudioObjectUnknown)
            if #available(macOS 14.4, *) {
                logIfRealError("AudioHardwareDestroyProcessTap", AudioHardwareDestroyProcessTap(id))
            }
        }

        sink.reset()
        tornDown = true
    }

    /// CoreAudio 상태를 평가해 "이미 사라진 객체"(-10877) 류는 debug로, 그 외 진짜
    /// 실패만 error로 남긴다 — hot-swap/중복 teardown의 무해한 로그 폭주를 막는다.
    private func logIfRealError(_ op: String, _ status: OSStatus) {
        guard status != noErr else { return }
        // kAudioHardwareBadObjectError(-10877): 대상 객체가 이미 없음 → 정리 목적상 무해.
        if status == kAudioHardwareBadObjectError {
            logger.debug("\(op): 대상 객체 없음(-10877, 무해)")
        } else {
            logger.error("\(op) failed: \(status)")
        }
    }
}

/// IO 블록(실시간 스레드)에서 raw tap 버퍼를 16kHz mono Float32 100ms 청크로 변환/누적하는 싱크.
///
/// IO 블록은 실시간 스레드(전용 시리얼 큐)에서 순차 호출되므로 박스 내부 상태는
/// 같은 스레드에서만 변형된다. `onChunk` 핸들러 교체만 메인 액터/외부에서 일어날 수 있어 락 보호.
/// (M1a `ConverterFeed`/`ChunkForwardBox` 패턴과 일관.)
private final class TapCaptureSink: @unchecked Sendable {

    private let lock = NSLock()
    private var _onChunk: (@Sendable ([Float]) -> Void)?
    var onChunk: (@Sendable ([Float]) -> Void)? {
        get { lock.withLock { _onChunk } }
        set { lock.withLock { _onChunk = newValue } }
    }

    // 변환 상태는 IO 스레드 단독 접근.
    private var inputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pendingSamples: [Float] = []

    func configure(inputFormat: AVAudioFormat, targetFormat: AVAudioFormat, converter: AVAudioConverter) {
        self.inputFormat = inputFormat
        self.targetFormat = targetFormat
        self.converter = converter
        self.pendingSamples.removeAll(keepingCapacity: true)
        self.pendingSamples.reserveCapacity(AppConfig.audioChunkSampleCount * 2)
    }

    func reset() {
        inputFormat = nil
        targetFormat = nil
        converter = nil
        pendingSamples.removeAll(keepingCapacity: true)
    }

    /// IO 블록의 inInputData(AudioBufferList) → 변환 → 청크화 → onChunk.
    func process(inputData: UnsafePointer<AudioBufferList>) {
        guard let converter, let inputFormat, let targetFormat else { return }

        // inInputData를 AVAudioPCMBuffer로 래핑한다. tap 포맷은 interleaved/float 가정에 의존하지 않고
        // ASBD로 만든 inputFormat을 그대로 사용한다(채널 수/interleave를 inputFormat이 기술).
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let firstBuffer = abl.first, firstBuffer.mData != nil, firstBuffer.mDataByteSize > 0 else {
            return
        }

        let bytesPerFrame = inputFormat.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return }
        let frameCount = firstBuffer.mDataByteSize / bytesPerFrame
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
        else { return }
        inBuffer.frameLength = frameCount

        // 입력 AudioBufferList의 raw 바이트를 inBuffer로 복사한다.
        // 채널 레이아웃은 inputFormat이 기술 → mBuffers를 그대로 미러링하면 된다.
        let dstABL = UnsafeMutableAudioBufferListPointer(inBuffer.mutableAudioBufferList)
        let copyCount = min(dstABL.count, abl.count)
        for i in 0..<copyCount {
            guard let src = abl[i].mData, let dst = dstABL[i].mData else { continue }
            let n = Int(min(abl[i].mDataByteSize, dstABL[i].mDataByteSize))
            memcpy(dst, src, n)
            dstABL[i].mDataByteSize = abl[i].mDataByteSize
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 16
        guard capacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        let feed = TapConverterFeed(buffer: inBuffer)
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

    private func emitChunksIfReady() {
        let chunkSize = AppConfig.audioChunkSampleCount
        let handler = onChunk
        while pendingSamples.count >= chunkSize {
            let chunk = Array(pendingSamples.prefix(chunkSize))
            pendingSamples.removeFirst(chunkSize)
            handler?(chunk)
        }
    }
}

/// AVAudioConverter 입력 블록용 1회성 버퍼 공급 박스 (M1a `ConverterFeed`와 동일 패턴).
private final class TapConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
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
