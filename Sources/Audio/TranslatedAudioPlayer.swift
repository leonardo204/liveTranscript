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

    /// 최근 재생 큐에 넣은 청크들의 슬라이딩 윈도우(FIFO). 모델이 초기 ~1분간 같은 문장을
    /// 재번역하면서 동일 PCM을 **비연속으로**(다른 청크가 사이에 끼었다 다시) 반복 전송해
    /// 같은 오디오가 반복 재생되므로, 직전 1개만 보던 기존 비교를 최근 윈도우 전체 비교로
    /// 강화한다. (hash, Data) 쌍을 들고 hash 일치 시 Data 동등성까지 확인해 해시 충돌을
    /// 방어한다. 윈도우 내 **바이트 완전 일치**만 skip(보수적) — 자연 발화는 매번 PCM이
    /// 달라 영향이 적다. 한계: 모델 중복 생성 자체는 서버 동작이라 클라이언트에서 차단 불가하며
    /// 반복 "재생"만 완화한다.
    private var recentChunks: [(hash: Int, data: Data)] = []
    /// hash 빠른 조회용 멀티셋 카운트(같은 hash가 윈도우에 여러 개일 수 있어 카운트로 관리).
    private var recentHashCounts: [Int: Int] = [:]
    /// 윈도우 최대 청크 수(약 40개 ≈ 수 초 분량 — 과도하지 않게).
    private let recentChunkWindow = 40
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

    /// 마스터 덕킹분 보상용 소프트웨어 게인(1.0=무증폭). 번역이 기본 출력 장치를 공유할 때
    /// 원문 덕킹으로 함께 작아진 번역 음량을 PCM 단계에서 곱으로 되살린다. enqueue가
    /// MainActor에서 호출되므로 동기화 부담 없음. player.volume(믹서)과 곱으로 합쳐져 최종 음량.
    var outputGain: Float = 1.0

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
            resetDedupWindow()   // 새 세션 — 중복 청크 윈도우 초기화
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
        resetDedupWindow()   // 정지 — 중복 청크 윈도우 초기화
        log.info("번역 오디오 재생 정지")
    }

    /// 스케줄된(아직 재생되지 않은) 버퍼를 즉시 비운다(서버 interrupted 대응).
    /// 진행 중 번역 오디오를 끊되 재생은 계속 가능한 상태로 둔다:
    /// `player.stop()`으로 큐를 비우고, 재생 중이었으면 `player.play()`로 즉시 재개한다.
    /// in-flight 카운터/직전 청크 비교 상태도 리셋해 다음 청크가 깨끗하게 들어오게 한다.
    func flush() {
        guard running else { return }
        player.stop()        // 스케줄된 버퍼 폐기(큐 클리어)
        inFlight.reset()
        resetDedupWindow()
        player.play()        // 큐만 비우고 재생은 지속(다음 enqueue를 즉시 받음)
        log.info("번역 오디오 flush(interrupted — 잔여 버퍼 폐기)")
    }

    /// 24kHz mono Int16 LE PCM Data를 재생 큐에 추가한다(재생 중일 때만).
    func enqueue(int16LE data: Data) {
        guard running, !data.isEmpty else { return }
        // 수정4: 최근 청크 윈도우 안에 바이트가 완전히 동일한 청크가 있으면 skip(보수적 —
        // 모델이 같은 PCM을 비연속으로 반복 전송해 같은 오디오가 반복 재생되는 것을 완화).
        // hash로 빠르게 걸러낸 뒤 Data 동등성까지 확인해 해시 충돌을 방어한다. 바이트 완전
        // 일치만 막으며 다른 합성이면 통과한다(모델 중복 생성 자체는 서버 동작이라 차단 불가).
        let chunkHash = data.hashValue
        if recentHashCounts[chunkHash] != nil,
           recentChunks.contains(where: { $0.hash == chunkHash && $0.data == data }) {
            dupSkipLogCount += 1
            if dupSkipLogCount == 1 || dupSkipLogCount % 50 == 0 {
                log.debug("중복 오디오 청크 skip(윈도우): \(data.count, privacy: .public) bytes 누적skip=\(self.dupSkipLogCount, privacy: .public)")
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
            let g = outputGain
            if g <= 1.0001 {
                // 무증폭(보상 없음/별도 장치): 기존 경로 — 왜곡 없는 선형 + 하드클립.
                for i in 0..<frameCount {
                    ch[i] = max(-1, min(1, Float(Int16(littleEndian: p[i])) / 32768.0))
                }
            } else {
                // 게인 보상: 증폭 후 tanh 소프트 리미터로 피크를 ±1 내로 부드럽게 압축
                // (하드웨어 클리핑/거친 왜곡 방지).
                for i in 0..<frameCount {
                    let s = Float(Int16(littleEndian: p[i])) / 32768.0 * g
                    ch[i] = tanhf(s)
                }
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
        // 수정4: 정상 처리된 청크를 윈도우에 기록(이후 동일 청크 skip 판정용).
        recordChunk(hash: chunkHash, data: data)
        player.scheduleBuffer(buf, completionHandler: { [inFlight] in inFlight.sub(frameCount) })
    }

    /// 정상 처리된 청크를 슬라이딩 윈도우에 추가하고, 한도를 넘으면 가장 오래된 것을 제거한다.
    private func recordChunk(hash: Int, data: Data) {
        recentChunks.append((hash: hash, data: data))
        recentHashCounts[hash, default: 0] += 1
        while recentChunks.count > recentChunkWindow {
            let removed = recentChunks.removeFirst()
            if let count = recentHashCounts[removed.hash] {
                if count <= 1 { recentHashCounts.removeValue(forKey: removed.hash) }
                else { recentHashCounts[removed.hash] = count - 1 }
            }
        }
    }

    /// 중복 청크 윈도우를 비운다(start/stop/flush에서 호출).
    private func resetDedupWindow() {
        recentChunks.removeAll(keepingCapacity: true)
        recentHashCounts.removeAll(keepingCapacity: true)
    }
}
