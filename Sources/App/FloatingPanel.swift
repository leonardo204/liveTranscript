import AppKit
import SwiftUI

/// 항상 떠있는 작은 플로팅 패널을 만드는 공통 헬퍼 (M1.5 미니 HUD용).
///
/// 자막 오버레이(M3, 클릭 통과)와 달리 이 패널은 **드래그로 이동 가능**하고 마우스를
/// 받는다. 공통화는 최소한으로만 한다(과한 일반화 금지) — borderless/floating/blur/둥근
/// 모서리/드래그/스페이스 공유라는 "모니터 HUD가 필요로 하는 골격"만 제공한다.
///
/// ## 구성
/// - `styleMask = [.borderless, .nonactivatingPanel]` — 타이틀바 없음, 클릭해도 앱이
///   활성화되지 않아 메뉴바 앱 흐름을 방해하지 않는다.
/// - `level = .floating` — 일반 창 위에 뜬다.
/// - `isOpaque = false`, `backgroundColor = .clear` — SwiftUI 쪽 블러/둥근 배경이 보이도록.
/// - `collectionBehavior`에 `.canJoinAllSpaces`, `.fullScreenAuxiliary` — 모든 스페이스/
///   전체화면 위에서도 표시.
/// - `isMovableByWindowBackground = true` — 배경 어디든 드래그로 이동.
@MainActor
final class FloatingPanel: NSPanel {

    /// 드래그로 이동이 끝났을 때(프레임 origin 변경) 호출. 위치 영속화에 사용.
    var onMoved: ((CGPoint) -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // 메뉴바 앱이 다른 창을 활성화해도 HUD는 떠 있어야 한다.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // borderless 패널이 키/메인이 되지 않도록(앱 활성화 방해 방지).
        // (아래 isKeyWindow override와 함께 동작)
        ignoresMouseEvents = false
    }

    // borderless 패널도 드래그/버튼 클릭을 받으려면 key가 될 수 있어야 한다.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// SwiftUI 루트 뷰를 붙인다.
    func setContent<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    /// 드래그(이동)가 끝나면 origin을 통지한다.
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        onMoved?(point)
    }
}
