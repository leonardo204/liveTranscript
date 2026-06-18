import AppKit
import SwiftUI

/// 자막 HUD 오버레이 창 (스펙 §5.3, M3).
///
/// 영화 자막처럼 **다른 앱(전체화면 영상 포함) 위 최상위**에 직접 표시되는 전용 창.
/// 제어 HUD(`FloatingPanel`)와 달리 **상호작용이 없다** — 클릭은 아래 앱으로 통과시킨다.
///
/// ## 핵심 구성 (스펙 §5.3 그대로)
/// - `styleMask = .borderless` — 타이틀바/테두리 없음.
/// - `level = .screenSaver` — `.floating`보다 더 위. 전체화면 영상/다른 플로팅 창 위에 표시.
/// - `isOpaque = false`, `backgroundColor = .clear` — 자막 텍스트 외 배경 투명.
/// - `ignoresMouseEvents = true` — **클릭 통과**(자막이 아래 앱 조작을 막지 않음).
/// - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
///   — 모든 스페이스/전체화면 위에서도 표시, Exposé/미션컨트롤에 끌려가지 않음.
/// - `hasShadow = false` — 텍스트 자체 그림자만 사용(창 그림자 불필요).
@MainActor
final class SubtitleOverlayWindow: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // 최상위: screenSaver 레벨은 floating보다 위라 전체화면 영상 위에도 보인다.
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 클릭 통과 — 자막은 표시 전용, 마우스 이벤트를 받지 않는다.
        ignoresMouseEvents = true
        // 메뉴바 앱 흐름 방해 방지: 키/메인이 되지 않는다.
        isFloatingPanel = true
        hidesOnDeactivate = false
        // 모든 스페이스 + 전체화면 보조 + 미션컨트롤 고정.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    // 자막 창은 절대 활성화되지 않는다(상호작용 없음).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// SwiftUI 루트 뷰를 붙인다(투명 배경 유지).
    func setContent<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}
