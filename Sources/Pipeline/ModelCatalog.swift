import Foundation
import os

/// 번들 `Resources/models.json` 로드 + 폴백 + 조회(spec 005 §3).
///
/// 1차는 번들 JSON이 진실원이다. 로드/디코드 실패 또는 빈 목록이면 코드 내장 `builtInGemini`로
/// 폴백해 **앱이 절대 빈 목록으로 깨지지 않게** 한다(spec 005 §1). 추후 원격 fetch/사용자
/// 오버라이드 병합을 이 타입 내부에서 확장할 수 있도록 단일 진입점으로 둔다.
@MainActor
struct ModelCatalog {
    static let shared = ModelCatalog()

    /// 사용 가능한 모델 목록. 로드 실패 시 `[builtInGemini]`.
    let models: [ModelDescriptor]

    private static let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "ModelCatalog")

    init() {
        self.models = Self.loadFromBundle() ?? [Self.builtInGemini]
    }

    /// 번들 JSON을 디코드한다. 실패/빈 목록이면 nil(호출자가 폴백).
    private static func loadFromBundle() -> [ModelDescriptor]? {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json") else {
            log.error("\(LogTag.catalog, privacy: .public) load failed → builtIn fallback — reason=models.json 번들 리소스 없음")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(ModelCatalogFile.self, from: data)
            guard !file.models.isEmpty else {
                log.error("\(LogTag.catalog, privacy: .public) load failed → builtIn fallback — reason=models 비어 있음")
                return nil
            }
            log.info("\(LogTag.catalog, privacy: .public) loaded — count=\(file.models.count, privacy: .public) source=bundle default=\(file.models.first?.id ?? "?", privacy: .public)")
            return file.models
        } catch {
            log.error("\(LogTag.catalog, privacy: .public) load failed → builtIn fallback — reason=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// id로 모델을 찾는다(없으면 nil).
    func model(id: String) -> ModelDescriptor? {
        models.first { $0.id == id }
    }

    /// id로 모델을 해석한다. id가 없거나 미존재면 첫 `available` 모델, 그것도 없으면 `builtInGemini`.
    func resolved(id: String?) -> ModelDescriptor {
        if let id, let found = model(id: id) { return found }
        if let firstAvailable = models.first(where: { $0.available }) { return firstAvailable }
        return Self.builtInGemini
    }

    /// 코드 내장 폴백 디스크립터(JSON 누락/손상 대비). `models.json`과 동일 내용.
    /// `modelIdentifier`는 `AppConfig.geminiModel`과 일치해야 현 동작이 보존된다.
    static let builtInGemini = ModelDescriptor(
        id: "gemini-3.5-live-translate",
        displayName: "Gemini Live 3.5 Translate",
        summary: "Google 클라우드 실시간 음성→번역(자막+번역음성). API 키 필요.",
        engine: .geminiLive,
        modelIdentifier: AppConfig.geminiModel,
        pipeline: .integrated,
        requiresAPIKey: true,
        available: true,
        capabilities: ModelDescriptor.Caps(
            sourceText: true,
            translatedText: true,
            translatedAudio: true,
            streaming: true
        ),
        vad: ModelDescriptor.VADSupport(server: true, clientGate: true, default: "client"),
        engineSlots: ModelDescriptor.EngineSlots(translation: false, llm: false),
        targetLanguages: nil,
        sourceLanguages: nil
    )
}
