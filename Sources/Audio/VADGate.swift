import Foundation
import FluidAudio
import OSLog

/// Silero VAD(FluidAudio) 기반 발화 게이트 (스펙 §5.6, §9.4).
///
/// AudioInputManager가 만든 16kHz mono Float32 100ms(1600 샘플) 청크를 받아,
/// **발화(speech) 구간만** 외부(`onSpeechChunk`)로 forward하고 음악·소음·무음은 차단한다.
/// 이로써 Gemini API 입력·출력 비용을 동시에 절감한다.
///
/// ## 설계 핵심
/// - **actor 격리**: 실시간 오디오 스레드는 async를 직접 호출 못 한다. 청크를 actor의
///   직렬 처리 큐(`pending`)에 넣고(`enqueue`, nonisolated 진입), actor가 순서대로 추론한다.
/// - **재청크(rebuffer)**: 우리 청크는 1600 샘플인데 Silero CoreML 모델은 정확히
///   `VadManager.chunkSize`(=4096 샘플, 256ms @16kHz) 프레임을 요구한다. 입력을 누적 버퍼
///   (`frameBuffer`)에 쌓아 4096 샘플이 모일 때마다 한 프레임씩 추론한다. 잔여 샘플은 다음
///   프레임으로 이월 → **샘플 손실/중복 없음**.
/// - **백프레셔**: VAD 추론이 입력 속도를 못 따라가면 `pending`이 적체된다. 상한
///   (`maxPendingChunks`)을 넘으면 가장 오래된 청크를 드롭하고 로그를 남긴다(무한 적체 금지).
/// - **pre-roll(speechPadding)**: speechStart 직전 음절이 잘리지 않도록 FluidAudio의
///   `VadSegmentationConfig.speechPadding`을 활용한다(이벤트 sampleIndex가 패딩만큼 앞당겨짐).
///   추가로 게이트 자체도 직전 프레임 1개를 pre-roll 버퍼로 보관해 발화 시작 시 함께 흘린다.
///
/// ## 모델 다운로드 (M1b: 런타임 다운로드 허용)
/// FluidAudio 모델은 첫 실행 시 HuggingFace에서 자동 다운로드된다(`~/Library/Application
/// Support/FluidAudio/Models`). 다운로드 중/실패 상태는 `VADModelStatus`로 노출하고, 실패해도
/// 앱은 죽지 않고 게이트가 **bypass(전부 forward)** 로 graceful degrade 한다.
/// 오프라인 사전 번들 동봉은 M5로 미룸.
actor VADGate {

    private let logger = Logger(subsystem: AppConfig.bundleIdentifier, category: "VADGate")

    /// 발화로 판정된 청크를 외부로 흘리는 콜백. AudioInputManager가 설정한다.
    /// 게이트 내부(actor) 컨텍스트에서 호출되므로 `@Sendable`.
    private let onSpeechChunk: @Sendable ([Float]) -> Void

    /// 발화 상태 변화(speechStart/End)를 외부에 알리는 콜백(메뉴 상태 표시용).
    private let onSpeechStateChange: @Sendable (Bool) -> Void

    /// 모델 준비/실패 상태 변화를 외부에 알리는 콜백.
    private let onStatusChange: @Sendable (VADModelStatus) -> Void

    // MARK: - 추론 엔진

    /// FluidAudio VAD 매니저. 모델 로드 성공 시에만 non-nil.
    private var manager: VadManager?

    /// Silero 스트리밍 상태(hysteresis + LSTM hidden/cell). 프레임마다 갱신.
    private var streamState: VadStreamState?

    /// 모델 준비 상태.
    private var status: VADModelStatus = .notLoaded

    // MARK: - 재청크 버퍼

    /// 모델이 요구하는 프레임 크기(샘플). FluidAudio 0.15.x = 4096(256ms @16kHz).
    private static let frameSize = VadManager.chunkSize

    /// 누적 버퍼: 입력 청크를 이어 붙여 frameSize 단위로 잘라 추론한다.
    private var frameBuffer: [Float] = []

    /// 직전(직전 프레임) 1개를 보관하는 pre-roll 버퍼. speechStart 시 함께 forward해
    /// 게이트 단위의 첫 음절 잘림을 추가로 방지한다.
    private var prevFrame: [Float]?

    /// 현재 발화중 여부(게이트 forward on/off).
    private var speaking = false

    // MARK: - 백프레셔 큐

    /// actor로 넘어온, 아직 처리되지 않은 입력 청크 큐.
    private var pending: [[Float]] = []

    /// 처리 루프 실행 중 여부(중복 드레인 방지).
    private var draining = false

    /// 큐 상한(청크 개수). 1600샘플=100ms 기준 30개 ≈ 3초 분량. 초과 시 오래된 것 드롭.
    private static let maxPendingChunks = 30

    /// 드롭된 청크 누적 카운트(과도 적체 진단용).
    private var droppedCount = 0

    /// 프레임 통과(forward) 로그 스로틀 카운터(고빈도). 첫 1회 + N회마다 1회만 로그.
    private var forwardFrameCount = 0

    // MARK: - 세그멘테이션 설정 (pre-roll 포함)

    /// speechPadding으로 pre-roll을 확보해 첫 음절 잘림을 막는다(스펙: 200ms 권장).
    /// 단, 라이브러리 precondition `speechPadding <= minSpeechDuration`을 지키기 위해
    /// minSpeechDuration도 함께 키운다.
    private let segConfig = VadSegmentationConfig(
        minSpeechDuration: 0.20,
        minSilenceDuration: 0.75,
        speechPadding: 0.20
    )

    init(
        onSpeechChunk: @escaping @Sendable ([Float]) -> Void,
        onSpeechStateChange: @escaping @Sendable (Bool) -> Void,
        onStatusChange: @escaping @Sendable (VADModelStatus) -> Void
    ) {
        self.onSpeechChunk = onSpeechChunk
        self.onSpeechStateChange = onSpeechStateChange
        self.onStatusChange = onStatusChange
    }

    // MARK: - 수명주기

    /// 모델을 1회 로드한다(앱 시작/첫 캡처 시). 캡처 중 재호출은 무시한다.
    /// 다운로드/로드 실패해도 throw하지 않고 상태만 `.unavailable`로 둔다(graceful degrade).
    func prepare() async {
        guard status == .notLoaded || status == .unavailable else { return }
        setStatus(.downloading)
        do {
            // VadManager async init = 모델 로드(필요 시 HF 자동 다운로드). 1회만.
            let m = try await VadManager(config: VadConfig(defaultThreshold: 0.85))
            self.manager = m
            // makeStreamState()는 VadManager actor 격리 메서드이며 내부적으로 .initial()을
            // 반환한다. 우리 actor에서 직접 .initial()을 쓰면 동일 결과 + 격리 hop 불필요.
            self.streamState = .initial()
            setStatus(.ready)
            logger.info("VAD model ready (frameSize=\(Self.frameSize))")
        } catch {
            self.manager = nil
            self.streamState = nil
            setStatus(.unavailable)
            logger.error("VAD model load failed, degrading to bypass: \(error.localizedDescription)")
        }
    }

    /// 스트림 상태를 초기화한다(캡처 재시작 시). 모델은 유지, 버퍼/상태만 리셋.
    func resetStream() {
        logger.info("resetStream: 스트림 상태 초기화 (speaking=\(self.speaking, privacy: .public) pending=\(self.pending.count, privacy: .public))")
        if manager != nil {
            streamState = .initial()
        }
        frameBuffer.removeAll(keepingCapacity: true)
        prevFrame = nil
        pending.removeAll(keepingCapacity: true)
        droppedCount = 0
        forwardFrameCount = 0
        if speaking {
            speaking = false
            onSpeechStateChange(false)
        }
    }

    // MARK: - 입력 (오디오 스레드 → actor)

    /// 오디오 스레드에서 호출하는 nonisolated 진입점. 청크를 actor 큐에 비동기로 넘긴다.
    /// 실제 enqueue/드레인은 actor 컨텍스트에서 직렬 실행된다.
    nonisolated func submit(_ chunk: [Float]) {
        Task { await self.enqueue(chunk) }
    }

    /// 큐에 청크를 넣고 드레인 루프를 (필요 시) 시작한다. 백프레셔 적용.
    private func enqueue(_ chunk: [Float]) async {
        // 모델이 없으면(아직 준비 전/실패) bypass: 전부 forward.
        guard status == .ready else {
            onSpeechChunk(chunk)
            return
        }

        pending.append(chunk)
        // 백프레셔: 상한 초과 시 가장 오래된 청크 드롭.
        while pending.count > Self.maxPendingChunks {
            pending.removeFirst()
            droppedCount += 1
            if droppedCount == 1 || droppedCount % 10 == 0 {
                logger.warning("VAD backpressure: dropped oldest chunk (total dropped=\(self.droppedCount))")
            }
        }

        guard !draining else { return }
        draining = true
        await drain()
        draining = false
    }

    /// 큐를 순서대로 비우며 프레임 단위 추론을 수행한다.
    private func drain() async {
        while !pending.isEmpty {
            let chunk = pending.removeFirst()
            await ingest(chunk)
        }
    }

    // MARK: - 재청크 + 추론

    /// 입력 청크를 누적 버퍼에 쌓고 frameSize 단위로 잘라 추론한다(샘플 손실/중복 없음).
    private func ingest(_ chunk: [Float]) async {
        frameBuffer.append(contentsOf: chunk)

        while frameBuffer.count >= Self.frameSize {
            let frame = Array(frameBuffer.prefix(Self.frameSize))
            frameBuffer.removeFirst(Self.frameSize)
            await processFrame(frame)
        }
    }

    /// 정확히 frameSize 샘플 1프레임을 Silero로 추론하고, 발화 상태에 따라 forward한다.
    private func processFrame(_ frame: [Float]) async {
        guard let m = manager, var state = streamState else {
            // 안전망: 모델이 사라졌다면 bypass.
            onSpeechChunk(frame)
            return
        }

        do {
            let result = try await m.processStreamingChunk(
                frame,
                state: state,
                config: segConfig,
                returnSeconds: false
            )
            state = result.state
            streamState = state

            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    if !speaking {
                        speaking = true
                        onSpeechStateChange(true)
                        // pre-roll: 직전 프레임을 먼저 흘려 첫 음절 잘림 방지.
                        if let pre = prevFrame {
                            logger.info("발화 시작(speech onset) — pre-roll 프레임 flush(\(pre.count, privacy: .public) samples)")
                            onSpeechChunk(pre)
                        } else {
                            logger.info("발화 시작(speech onset) — pre-roll 없음")
                        }
                    }
                case .speechEnd:
                    if speaking {
                        speaking = false
                        logger.info("발화 종료(speech offset)")
                        onSpeechStateChange(false)
                    }
                }
            }

            // 발화중이면 현재 프레임 forward(speechStart 프레임 포함).
            if speaking {
                // 진단(고빈도 — 스로틀: 첫 1회 + 50회마다): 발화 프레임 통과.
                forwardFrameCount += 1
                if forwardFrameCount == 1 || forwardFrameCount % 50 == 0 {
                    logger.debug("발화 프레임 통과: 누적 \(self.forwardFrameCount, privacy: .public)프레임")
                }
                onSpeechChunk(frame)
            }
        } catch {
            // 추론 실패 시 안전하게 forward(언더-블로킹 < 오버-블로킹: 자막 누락 방지).
            logger.error("VAD inference failed, forwarding frame: \(error.localizedDescription)")
            onSpeechChunk(frame)
        }

        // 다음 프레임의 pre-roll용으로 현재 프레임 보관.
        prevFrame = frame
    }

    // MARK: - 상태

    private func setStatus(_ s: VADModelStatus) {
        guard status != s else { return }
        status = s
        onStatusChange(s)
    }
}

/// VAD 모델 준비 상태(메뉴 표시용).
enum VADModelStatus: Sendable, Equatable {
    /// 아직 로드 시도 전.
    case notLoaded
    /// 모델 다운로드/로드 중("VAD 모델 준비 중…").
    case downloading
    /// 사용 준비 완료.
    case ready
    /// 다운로드/로드 실패 → bypass 동작("VAD 사용 불가").
    case unavailable

    /// 메뉴 표시용 한국어 라벨.
    var menuLabel: String {
        switch self {
        case .notLoaded: return "VAD 미초기화"
        case .downloading: return "VAD 모델 준비 중…"
        case .ready: return "VAD 준비됨"
        case .unavailable: return "VAD 사용 불가(소거 차단 비활성)"
        }
    }
}
