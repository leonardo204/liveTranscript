import Foundation

/// 모델 카탈로그 파일 루트(spec 005 §3). `Resources/models.json` 디코드 대상.
struct ModelCatalogFile: Decodable, Sendable {
    let schemaVersion: Int
    let models: [ModelDescriptor]
}

/// 단일 모델(엔진) 디스크립터(spec 005 §3). 하드코딩 대신 JSON에서 선언되며,
/// UI 게이팅(capability)·팩토리 분기(engine)·영속(`SettingsStore.selectedModelID`)의 진실원이다.
struct ModelDescriptor: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    let engine: TranslationEngineKind
    let modelIdentifier: String
    let pipeline: PipelineShape
    let requiresAPIKey: Bool
    let available: Bool
    let capabilities: Caps
    let vad: VADSupport
    let engineSlots: EngineSlots
    let targetLanguages: [String]?
    let sourceLanguages: [String]?

    /// 모델이 생산하는 텍스트/오디오/스트리밍 능력(자막/오디오/비용 UI 게이팅).
    struct Caps: Decodable, Sendable, Equatable {
        let sourceText: Bool
        let translatedText: Bool
        let translatedAudio: Bool
        let streaming: Bool
    }

    /// VAD 옵션 지원 게이트(서버 자동 / 클라이언트 Silero 게이트) + 초기 선택.
    struct VADSupport: Decodable, Sendable, Equatable {
        let server: Bool
        let clientGate: Bool
        let `default`: String
    }

    /// composed 파이프라인에서 별도 번역/LLM 엔진 설정 섹션 노출 여부(현재 false → 숨김).
    struct EngineSlots: Decodable, Sendable, Equatable {
        let translation: Bool
        let llm: Bool
    }

    /// 파이프라인 형태. integrated=1-Stage(통합형), composed=STT→번역/LLM→TTS.
    enum PipelineShape: String, Decodable, Sendable {
        case integrated
        case composed
    }

    /// spec 004 `EngineCapabilities`로 사상(provider 능력 노출용).
    var engineCapabilities: EngineCapabilities {
        EngineCapabilities(
            producesSourceText: capabilities.sourceText,
            producesTranslatedText: capabilities.translatedText,
            producesTranslatedAudio: capabilities.translatedAudio,
            requiresAPIKey: requiresAPIKey,
            isStreaming: capabilities.streaming,
            supportedTargetLanguages: targetLanguages,
            supportedSourceLanguages: sourceLanguages
        )
    }
}
