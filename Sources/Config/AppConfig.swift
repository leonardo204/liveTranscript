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

    /// 100ms 청크당 샘플 수 = 16000 * 0.1 = 1600 (16kHz mono Float32).
    /// 파이프라인 내부 처리 단위(§4.1, §5.2). Gemini 송신 시 Int16 LE로 변환은 M2 담당.
    static let audioChunkSampleCount: Int =
        Int(audioSampleRate * Double(audioChunkMilliseconds) / 1000.0)

    /// 개발용 .env 경로를 강제 지정하는 환경변수 이름.
    static let envPathOverrideKey = "LIVETRANSLATE_ENV_PATH"

    // MARK: - 자막 길이 (태스크 B)

    /// 누적 중인 번역 줄이 이 글자수를 넘으면 확정하고 다음으로 넘긴다(영화 자막 ~2줄).
    /// 한국어 자막 1줄 ≈ 화면 폭 기준 ~25자 → 2줄 ≈ 50자 전후. 튜닝 가능.
    static let defaultMaxCharsBeforeBreak: Int = 50

    /// 자막 한 줄에 대략 들어가는 글자수(한국어 기준, B2). break 임계를 뷰의 줄수
    /// (`subtitleMaxLines`)와 연동하는 환산 계수다. 줄수 × 이 값 = 누적 허용 글자수.
    /// 예: 줄수 2 → 56자, 줄수 3 → 84자 → 실제로 2~3줄이 누적·표시된다.
    static let charsPerSubtitleLine: Int = 28

    // MARK: - 비용 단가 (스펙 §9.1, 태스크 C)

    /// 오디오 입력 단가: $3.50 / 1M 토큰.
    static let costInputUSDPerMillionTokens: Double = 3.50

    /// 오디오 출력 단가: $21.00 / 1M 토큰 (비용의 ~85%).
    static let costOutputUSDPerMillionTokens: Double = 21.00

    /// 오디오 토큰 환산율: 25 tokens/초(입력 누적 시간 → 토큰 추정).
    static let costAudioTokensPerSecond: Double = 25.0
}
