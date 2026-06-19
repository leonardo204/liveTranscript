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
    /// 이 모델을 쓰기 위한 최소 macOS 버전(예 "26.0"). 누락/nil이면 OS 제약 없음(spec 007 §6).
    /// 현재 OS가 미달이면 카탈로그/UI/팩토리가 "비활성(macOS N+ 필요)"으로 게이팅한다.
    let minOS: String?
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

    /// 현재 실행 중인 macOS가 `minOS`를 만족하는지(spec 007 §6). minOS=nil이면 항상 true.
    /// "26.0"/"26"/"15.4" 같은 major[.minor[.patch]] 문자열을 파싱해
    /// `ProcessInfo.isOperatingSystemAtLeast`로 비교한다(파싱 실패 시 보수적으로 true=제약 없음).
    var isAvailableOnThisOS: Bool {
        guard let minOS else { return true }
        let parts = minOS.split(separator: ".").map { Int($0) ?? 0 }
        guard let major = parts.first else { return true }
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        let version = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(version)
    }

    /// 카탈로그 available + 현재 OS 게이트를 합친 실제 사용 가능 여부(UI/팩토리 게이팅 진실값).
    var effectiveAvailable: Bool { available && isAvailableOnThisOS }

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
