import Foundation
import os

/// 설정 + 키로부터 `TranslationProvider`를 만든다(spec 004 P0 / spec 005 §4). AppState는 이 팩토리만 호출한다.
///
/// 선택된 모델 디스크립터(`ModelCatalog`)의 `engine`으로 분기한다:
/// - `.geminiLive` → `GeminiTranslationProvider`(통합형 클라우드).
/// - `.onDeviceTranscribe`/`.onDeviceTranslate` → **현재 nil**(spec 003 미적용 — 호출자가 "준비 중" 처리).
@MainActor
struct TranslationProviderFactory {
    private static let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Pipeline")

    func make(settings: SettingsStore, apiKey: String) -> (any TranslationProvider)? {
        let desc = ModelCatalog.shared.resolved(id: settings.selectedModelID)
        switch desc.engine {
        case .geminiLive:
            // 팩토리 분기 + 능력/키 유무 로그(키 값은 비노출 — present|absent만, spec 006 §4.5).
            Self.log.info("\(LogTag.factory, privacy: .public) make — engine=\(desc.engine.rawValue, privacy: .public) model=\(desc.modelIdentifier, privacy: .public) caps(src=\(desc.capabilities.sourceText, privacy: .public) txt=\(desc.capabilities.translatedText, privacy: .public) audio=\(desc.capabilities.translatedAudio, privacy: .public)) key=\(apiKey.isEmpty ? "absent" : "present", privacy: .public)")
            return GeminiTranslationProvider(
                apiKey: apiKey,
                model: desc.modelIdentifier,
                targetLanguageCode: settings.targetLanguageCode,
                requestInputTranscription: desc.capabilities.sourceText && settings.showSourceText,
                capabilities: desc.engineCapabilities
            )
        case .onDeviceTranscribe, .onDeviceTranslate:
            Self.log.info("\(LogTag.factory, privacy: .public) unsupported engine — engine=\(desc.engine.rawValue, privacy: .public) (준비 중)")
            return nil   // spec 003 미적용 — 호출자가 "준비 중"으로 정지 수렴.
        }
    }
}
