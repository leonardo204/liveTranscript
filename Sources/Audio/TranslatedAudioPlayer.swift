import AVFoundation
import CoreAudio
import os

/// Gemini 번역 출력 오디오(24kHz mono Int16 LE PCM)를 실시간 재생한다.
/// AVAudioEngine + AVAudioPlayerNode 스트리밍. @MainActor에서만 조작.
@MainActor
final class TranslatedAudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var running = false
    private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "AudioPlayer")

    /// in-flight 프레임 수를 스레드 안전하게 추적(완료 콜백은 렌더 스레드에서 호출됨).
    private final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        func add(_ n: Int) { lock.lock(); frames += n; lock.unlock() }
        func sub(_ n: Int) { lock.lock(); frames = max(0, frames - n); lock.unlock() }
        func current() -> Int { lock.lock(); defer { lock.unlock() }; return frames }
        func reset() { lock.lock(); frames = 0; lock.unlock() }
    }
    private let inFlight = FrameCounter()
    private let maxInFlightFrames = 24_000 * 3   // 약 3초(24kHz)

    /// enqueue 로그 스로틀 카운터(고빈도). 첫 1회 + 50회마다 1회만 로그.
    private var enqueueLogCount = 0
    /// 백프레셔 드롭 로그 스로틀 카운터(고빈도). 첫 1회 + 50회마다 1회만 로그.
    private var dropLogCount = 0

    /// 직전에 재생 큐에 넣은 청크(바이트). 모델이 동일 PCM을 연속 전송하면 같은 오디오가
    /// 반복 재생되므로, 직전과 **바이트가 완전히 동일한** 청크만 보수적으로 skip한다.
    /// 한계: 모델 중복이 byte-identical일 때만 효과가 있다. 같은 문장이라도 합성 결과가
    /// 미세하게 다르면(byte가 달라지면) 통과되어 반복이 들릴 수 있다 — 클라이언트에서
    /// 모델 중복 생성 자체를 완전히 차단하는 것은 불가능하다.
    private var lastEnqueuedData: Data?
    /// 중복 오디오 skip 로그 스로틀 카운터(고빈도). 첫 1회 + 50회마다 1회만 로그.
    private var dupSkipLogCount = 0

    /// 번역 오디오를 내보낼 출력 장치 UID. nil이면 시스템 기본 출력 사용.
    private(set) var outputDeviceUID: String?

    init(sampleRate: Double = 24_000) {
        // float32 mono. 강제 unwrap은 고정 파라미터라 안전.
        self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format) // 믹서가 하드웨어 SR로 변환
    }

    /// 소프트웨어 재생 볼륨(0...1). 시스템 출력 볼륨과 별개.
    var volume: Float {
        get { player.volume }
        set {
            let clamped = max(0, min(1, newValue))
            if player.volume != clamped {
                log.info("volume 변경: \(self.player.volume, privacy: .public) → \(clamped, privacy: .public)")
            }
            player.volume = clamped
        }
    }

    /// 번역 오디오를 라우팅할 출력 장치를 지정한다(uid가 nil이면 시스템 기본 출력).
    /// - 동일 uid면 재구성을 생략한다(멱등).
    /// - 재생 중이면 엔진을 안전하게 재구성해 즉시 반영하고, 정지 중이면 deviceID만
    ///   설정해 다음 start()에 반영한다.
    func setOutputDevice(uid: String?) {
        guard uid != outputDeviceUID else { return }   // 멱등 — 동일 장치면 무시
        log.info("setOutputDevice 요청: uid=\(uid ?? "(시스템 기본)", privacy: .public) running=\(self.running, privacy: .public)")
        // 캐시 갱신은 적용 성공 이후로 미룬다. 실패 시 이전 값으로 롤백해
        // 동일 uid 재선택이 멱등 가드에 영구 차단되지 않도록 한다(헤드폰 재연결 등 복구 가능).
        let previousUID = outputDeviceUID
        outputDeviceUID = uid

        if running {
            log.info("setOutputDevice: 재생 중 → 엔진 재구성(stop→start)")
            // 재생 중: 엔진을 멈추고 출력 장치를 바꾼 뒤 재시작한다.
            player.stop()
            engine.stop()
            running = false
            _ = applyOutputDevice()
            do {
                engine.prepare()
                try engine.start()
                player.play()
                running = true
                log.info("출력 장치 변경 후 재생 재개")
            } catch {
                // 재구성 실패 → 무음 무복구 방지: 기본 출력으로 폴백 재시도.
                log.error("출력 장치 변경 후 엔진 재시작 실패 — 기본 출력 폴백 시도: \(error.localizedDescription, privacy: .public)")
                outputDeviceUID = nil            // deviceID 설정을 기본 출력으로 되돌림
                _ = applyOutputDevice()          // nil이면 기본 출력 적용
                do {
                    engine.prepare()
                    try engine.start()
                    player.play()
                    running = true
                    log.info("기본 출력으로 재생 재개")
                } catch {
                    running = false
                    log.error("번역 오디오 출력 재구성 실패 — 무음: \(error.localizedDescription, privacy: .public)")
                }
                // 선택 uid 적용에 실패했으므로 캐시는 폴백(nil) 상태로 둔다 →
                // 사용자가 동일/다른 장치를 다시 고를 수 있다(차단 해제).
                return
            }
            // 적용 성공 시에만 새 uid를 캐시로 확정(이미 outputDeviceUID == uid).
        } else {
            // 정지 중: 다음 start()에서 반영되도록 deviceID만 설정한다.
            if !applyOutputDevice() {
                // 장치 설정 실패 → 캐시를 이전 값으로 롤백(다음 선택 차단 방지).
                outputDeviceUID = previousUID
            }
        }
    }

    /// 현재 outputDeviceUID를 엔진 출력노드의 AUAudioUnit.deviceID에 반영한다.
    /// uid가 nil이거나 해석 실패면 기본 출력을 유지한다(성공으로 간주).
    /// - Returns: setDeviceID throw 시 false, 성공/기본출력은 true.
    @discardableResult
    private func applyOutputDevice() -> Bool {
        guard let uid = outputDeviceUID else {
            log.info("applyOutputDevice: uid 없음 → 시스템 기본 출력 사용")
            return true   // 기본 출력 사용(성공으로 간주)
        }
        guard let deviceID = AudioDeviceEnumerator.deviceID(forUID: uid) else {
            log.info("applyOutputDevice: uid 해석 실패(\(uid, privacy: .public)) → 기본 출력 폴백")
            return true   // 해석 실패 시 기본 출력(성공으로 간주)
        }
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
            log.info("applyOutputDevice: 적용 성공 uid=\(uid, privacy: .public) deviceID=\(deviceID, privacy: .public)")
            return true
        } catch {
            log.error("출력 장치 설정 실패 — 기본 사용: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func start() {
        guard !running else { return }
        // 시작 직전 설정된 출력 장치를 반영한다(없으면 기본 출력).
        applyOutputDevice()
        do {
            engine.prepare()
            try engine.start()
            player.play()
            running = true
            lastEnqueuedData = nil   // 새 세션 — 직전 청크 비교 상태 초기화
            log.info("번역 오디오 재생 시작: SR=\(self.format.sampleRate, privacy: .public)Hz ch=\(self.format.channelCount, privacy: .public) 출력=\(self.outputDeviceUID ?? "(시스템 기본)", privacy: .public)")
        } catch {
            running = false
            log.error("오디오 엔진 시작 실패: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        running = false
        inFlight.reset()   // 잔여 버퍼 폐기와 동기 — 다음 재생 시작 시 카운터를 0에서 시작
        lastEnqueuedData = nil   // 정지 — 직전 청크 비교 상태 초기화
        log.info("번역 오디오 재생 정지")
    }

    /// 24kHz mono Int16 LE PCM Data를 재생 큐에 추가한다(재생 중일 때만).
    func enqueue(int16LE data: Data) {
        guard running, !data.isEmpty else { return }
        // 수정3: 직전에 큐에 넣은 청크와 바이트가 완전히 동일하면 skip(보수적 — 모델이
        // 동일 PCM을 연속 전송해 같은 오디오가 반복 재생되는 것을 완화). 바이트 완전 일치만
        // 막으며, 다른 합성이면 통과한다(완전 차단 불가).
        if let last = lastEnqueuedData, last == data {
            dupSkipLogCount += 1
            if dupSkipLogCount == 1 || dupSkipLogCount % 50 == 0 {
                log.debug("중복 오디오 청크 skip: \(data.count, privacy: .public) bytes 누적skip=\(self.dupSkipLogCount, privacy: .public)")
            }
            return
        }
        let frameCount = data.count / 2
        guard frameCount > 0 else { return }
        // 백프레셔: in-flight 프레임이 임계(약 3초)를 넘으면 신규 enqueue를 드롭한다.
        // (수신이 재생보다 빨라 무한 누적되면 재생 지연이 계속 커지는 드리프트를 막는다.)
        // 진단(고빈도 — 스로틀: 첫 1회 + 50회마다): 드롭 카운트만 로그(데이터 미포함).
        if inFlight.current() >= maxInFlightFrames {
            dropLogCount += 1
            if dropLogCount == 1 || dropLogCount % 50 == 0 {
                log.debug("enqueue 백프레셔 드롭: inFlight=\(self.inFlight.current(), privacy: .public)프레임 누적드롭=\(self.dropLogCount, privacy: .public)")
            }
            return
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buf.frameLength = AVAudioFrameCount(frameCount)
        let ch = buf.floatChannelData![0]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                ch[i] = max(-1, min(1, Float(Int16(littleEndian: p[i])) / 32768.0))
            }
        }
        // completionHandler는 렌더 스레드(비-MainActor)에서 호출된다. self/MainActor 격리 위반과
        // 순환 참조를 피하기 위해 값 캡처한 inFlight 참조(스레드 안전)만 사용한다.
        inFlight.add(frameCount)
        // 진단(고빈도 — 스로틀: 첫 1회 + 50회마다): bytes + inFlight 프레임 수.
        enqueueLogCount += 1
        if enqueueLogCount == 1 || enqueueLogCount % 50 == 0 {
            log.debug("enqueue: \(data.count, privacy: .public) bytes inFlight=\(self.inFlight.current(), privacy: .public)프레임")
        }
        // 수정3: 정상 처리된 청크를 직전 청크로 기록(다음 동일 청크 skip 판정용).
        lastEnqueuedData = data
        player.scheduleBuffer(buf, completionHandler: { [inFlight] in inFlight.sub(frameCount) })
    }
}
