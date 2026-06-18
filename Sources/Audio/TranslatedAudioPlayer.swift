import AVFoundation
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

    init(sampleRate: Double = 24_000) {
        // float32 mono. 강제 unwrap은 고정 파라미터라 안전.
        self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format) // 믹서가 하드웨어 SR로 변환
    }

    /// 소프트웨어 재생 볼륨(0...1). 시스템 출력 볼륨과 별개.
    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    func start() {
        guard !running else { return }
        do {
            engine.prepare()
            try engine.start()
            player.play()
            running = true
            log.info("번역 오디오 재생 시작")
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
        log.info("번역 오디오 재생 정지")
    }

    /// 24kHz mono Int16 LE PCM Data를 재생 큐에 추가한다(재생 중일 때만).
    func enqueue(int16LE data: Data) {
        guard running, !data.isEmpty else { return }
        let frameCount = data.count / 2
        guard frameCount > 0 else { return }
        // 백프레셔: in-flight 프레임이 임계(약 3초)를 넘으면 신규 enqueue를 드롭한다.
        // (수신이 재생보다 빨라 무한 누적되면 재생 지연이 계속 커지는 드리프트를 막는다.)
        // 드롭 로그는 남기지 않는다 — 폭주 상황에서 로그가 오히려 부하를 키우기 때문.
        if inFlight.current() >= maxInFlightFrames { return }
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
        player.scheduleBuffer(buf, completionHandler: { [inFlight] in inFlight.sub(frameCount) })
    }
}
