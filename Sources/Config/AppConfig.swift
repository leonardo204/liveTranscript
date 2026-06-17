import Foundation

/// 앱 전역 설정 상수 (M0 스텁).
enum AppConfig {
    /// 번들 식별자.
    static let bundleIdentifier = "com.altimedia.liveTranslate"

    /// Gemini Live Translate 모델명 (스펙 §5.1). M2에서 GeminiLiveClient가 사용.
    static let geminiModel = "models/gemini-3.5-live-translate-preview"

    /// 기본 번역 대상 언어 (BCP-47). 스펙 §5.1.
    static let defaultTargetLanguageCode = "ko"

    /// Gemini 송신 오디오 포맷 (스펙 §5.1): 16kHz mono 16-bit PCM, 100ms 청크.
    static let audioSampleRate: Double = 16_000
    static let audioChunkMilliseconds: Int = 100

    /// 개발용 .env 경로를 강제 지정하는 환경변수 이름.
    static let envPathOverrideKey = "LIVETRANSLATE_ENV_PATH"
}
