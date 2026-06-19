import Foundation
import os

/// 통합형(클라우드) 번역 제공자 — `GeminiLiveClient`(actor)를 `PipelineEvent`로 어댑트한다(spec 004 P0).
///
/// 이 어댑터는 GeminiLiveClient를 **무손상 래핑**한다: 동작/이벤트 의미를 바꾸지 않고
/// `GeminiLiveClient.Event`를 백엔드 독립 `PipelineEvent`로 1:1 사상만 한다.
///
/// 설정 노트(GeminiLiveClient에서 이관):
/// - `clientVADEnabled`는 항상 false로 고정한다. 서버 자동 VAD를 사용한다(realtimeInputConfig 생략 +
///   activity 신호 미전송). translate-preview 모델은 manual activity 경계를 turn 종료로 인정하지 않아
///   turnComplete를 보내지 않았고, idle 타이머/강제 분절이 sparse VAD 프레임과 충돌해 activity 신호가
///   폭주했다. 따라서 activity 기반 경계 제어를 비활성화하고 서버 VAD에 일임한다.
/// - `requestInputTranscription`은 "원문 동시 표시"(showSourceText)가 켜진 경우에만 true.
///   off면 공식 translate 예제와 동일하게 inputAudioTranscription 키를 생략 → 원문 자막 없음(의도된 동작).
actor GeminiTranslationProvider: TranslationProvider {
    nonisolated let capabilities: EngineCapabilities
    private let client: GeminiLiveClient
    private var pumpTask: Task<Void, Never>?
    /// provider 수명 로그용 모델 식별자(spec 006 §4.6). 키/민감정보 미포함.
    private let model: String
    private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Pipeline")

    init(
        apiKey: String,
        model: String,
        targetLanguageCode: String,
        requestInputTranscription: Bool,
        capabilities: EngineCapabilities
    ) {
        self.model = model
        self.client = GeminiLiveClient(
            apiKey: apiKey,
            model: model,
            targetLanguageCode: targetLanguageCode,
            clientVADEnabled: false,
            requestInputTranscription: requestInputTranscription
        )
        // 능력 선언은 모델 디스크립터에서 주입한다(카탈로그가 진실원, spec 005).
        self.capabilities = capabilities
    }

    func start() async -> AsyncStream<PipelineEvent> {
        log.info("\(LogTag.provider, privacy: .public) start — engine=gemini model=\(self.model, privacy: .public)")
        let (stream, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
        let client = self.client
        pumpTask = Task {
            let upstream = await client.connect()
            for await event in upstream {
                continuation.yield(GeminiTranslationProvider.map(event))
            }
            continuation.finish()
        }
        return stream
    }

    nonisolated func send(_ chunk: AudioChunk) {
        let client = self.client
        Task { await client.sendAudio(chunk) }
    }

    func stop() async {
        log.info("\(LogTag.provider, privacy: .public) stop")
        pumpTask?.cancel()
        pumpTask = nil
        await client.stop()
    }

    func setTranslatedAudioPlayback(_ on: Bool) async {
        await client.setPlaybackEnabled(on)
    }

    /// `GeminiLiveClient.Event` → `PipelineEvent` 사상(의미 보존).
    private static func map(_ e: GeminiLiveClient.Event) -> PipelineEvent {
        switch e {
        case .state(let s):            return .state(mapState(s))
        case .translation(let d):      return .translatedText(delta: d)
        case .source(let d):           return .sourceText(delta: d)
        case .turnComplete:            return .turnComplete
        case .generationComplete:      return .generationComplete
        case .sentAudio(let n):        return .usage(.sentAudio(sampleCount: n))
        case .outputTokens(let n):     return .usage(.outputAudioTokens(n))
        case .outputAudio(let data):   return .outputAudio(data)
        case .info(let m):             return .info(m)
        case .interrupted:             return .interrupted
        case .permanentFailure(let r): return .permanentFailure(reason: r)
        }
    }

    /// `GeminiLiveClient.State`(정확히 4개 케이스, non-frozen) → `PipelineState` 사상.
    private static func mapState(_ s: GeminiLiveClient.State) -> PipelineState {
        switch s {
        case .disconnected: return .idle
        case .connecting:   return .preparing
        case .ready:        return .ready
        case .error(let m): return .error(m)
        }
    }
}
