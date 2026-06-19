import Foundation

/// 로그 메시지 prefix 상수 모음 (spec 006 §2). os.Logger의 category가 보이지 않는 뷰어에서도
/// 사람이 바로 레이어를 읽을 수 있도록 메시지 맨 앞에 `[TAG]`를 붙인다.
///
/// 한 곳에 모아 오타/표류를 막는다(각 컴포넌트는 이 상수만 참조). spec 006 §2 태그 표와 1:1.
enum LogTag {
    /// 오케스트레이션(추상) — 사용자 의도/세션 진입점.
    static let appState = "[AppState]"
    /// 상태머신 — 전이 판정/수행.
    static let reconcile = "[Reconcile]"
    /// 카탈로그 — 모델 로드/선택.
    static let catalog = "[Catalog]"
    /// 팩토리 — provider 생성 분기.
    static let factory = "[Factory]"
    /// 제공자(어댑터) — start/stop/이벤트 사상.
    static let provider = "[Provider]"
    /// 엔진 — WebSocket/연결/수신.
    static let gemini = "[Gemini]"
    /// 설정 — 로드/변경/키 상태.
    static let settings = "[Settings]"
    /// 오디오 입력 — 캡처/소스/VAD.
    static let audio = "[Audio]"
    /// 자막 — 누적/확정 경계.
    static let subtitle = "[Subtitle]"
    /// 비용 — 사용량 누적.
    static let cost = "[Cost]"
}
