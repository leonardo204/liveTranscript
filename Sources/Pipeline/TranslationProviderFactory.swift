import Foundation

/// 설정 + 키로부터 `TranslationProvider`를 만든다(spec 004 P0). AppState는 이 팩토리만 호출한다.
///
/// P0: 엔진 종류 geminiLive 고정. (P1+에서 온디바이스 분기/스테이지 합성을 여기서 추가 예정.)
@MainActor
struct TranslationProviderFactory {
    func make(settings: SettingsStore, apiKey: String) -> any TranslationProvider {
        GeminiTranslationProvider(
            apiKey: apiKey,
            targetLanguageCode: settings.targetLanguageCode,
            requestInputTranscription: settings.showSourceText
        )
    }
}
