import Foundation

/// 번역 파이프라인 엔진 종류 (spec 004 §6).
///
/// P0/§7 단계에서는 `.geminiLive`만 사용한다(통합형 클라우드, 키 필요).
/// 온디바이스 분기(`.onDeviceTranscribe`/`.onDeviceTranslate`)는 P2+에서 실제 Stage가
/// 붙을 때 팩토리에서 활성화한다. enum을 미리 두어 `ProviderConfig` 비교(핫스왑 판정)와
/// 설정 영속화 키를 안정적으로 준비한다.
enum TranslationEngineKind: String, Codable, Sendable, Equatable {
    /// 통합형: 오디오 → (번역 텍스트 + 번역 오디오)가 한 엔진에서. 클라우드, API 키 필요.
    case geminiLive
    /// 조합형: 온디바이스 ASR만 — 원문 자막 전용(키 불필요).
    case onDeviceTranscribe
    /// 조합형: 온디바이스 ASR + 온디바이스 번역(키 불필요).
    case onDeviceTranslate
}
