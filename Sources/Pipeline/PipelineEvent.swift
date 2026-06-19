import Foundation

/// 번역 파이프라인의 백엔드 독립 데이터 모델(spec 004 P0).
///
/// AppState/UI는 이 타입들만 알고, 구체 백엔드(GeminiLiveClient 등)에는 의존하지 않는다.
/// 어떤 엔진/스테이지 조합이든 결과는 단일 `PipelineEvent` 스트림으로 수렴한다.

/// 16kHz mono Float32, 100ms(1600 samples) 청크.
typealias AudioChunk = [Float]

/// 파이프라인 수명 상태(백엔드 독립).
enum PipelineState: Sendable, Equatable {
    case idle, preparing, ready, reconnecting, error(String)
}

/// 비용/사용량 측정 단위(백엔드 독립). UI 비용 추정기로 전달된다.
enum UsageMetric: Sendable {
    case sentAudio(sampleCount: Int)
    case outputAudioTokens(Int)
    case localCompute(stage: String, ms: Int)
}

/// 모든 백엔드/파이프라인이 내는 단일 결과 이벤트.
enum PipelineEvent: Sendable {
    case state(PipelineState)
    case info(String)
    case permanentFailure(reason: String)
    case interrupted
    case sourceText(delta: String)
    case translatedText(delta: String)
    case turnComplete
    case generationComplete
    // 세그먼트(교체) 모델 — STT/MT 엔진용(spec 007 §5). delta 누적과 별개로 "현재 세그먼트
    // 전체"를 교체한다. isFinal=true면 발화/세그먼트 확정(자막 confirm 경계). Gemini는 위 delta
    // 경로를 그대로 쓰고, ComposedTranslationProvider만 이 segment 경로를 방출한다.
    case sourceSegment(text: String, isFinal: Bool)      // 원문 세그먼트 전체(교체)
    case translatedSegment(text: String, isFinal: Bool)  // 번역 세그먼트 전체(교체)
    case outputAudio(Data)
    case usage(UsageMetric)
}

/// 엔진 능력 선언(자막/오디오/비용 UI 조정 및 폴백 판단용).
struct EngineCapabilities: Sendable {
    var producesSourceText: Bool
    var producesTranslatedText: Bool
    var producesTranslatedAudio: Bool
    var requiresAPIKey: Bool
    var isStreaming: Bool
    var supportedTargetLanguages: [String]?
    var supportedSourceLanguages: [String]?
}
