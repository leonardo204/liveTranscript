import Foundation

/// (M3에서 대체됨) 자막 오버레이 창의 초기 스텁.
///
/// 실제 구현은 다음 3개 파일로 분화되었다(스펙 §5.3 / §5.4):
/// - `SubtitleOverlayWindow` — borderless/최상위/클릭통과 NSPanel.
/// - `SubtitleOverlayView` — 영화 자막식 SwiftUI 렌더링(외곽선/그림자/페이드).
/// - `SubtitleOverlayController` — 수명주기/위치/화면변경 관리.
///
/// 이 타입은 더 이상 사용하지 않으나 히스토리 참조용으로 남긴다.
enum OverlayWindowLegacy {}
