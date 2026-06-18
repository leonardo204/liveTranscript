import AppKit
import SwiftUI

/// 설정 창의 수명주기를 관리한다 (M1.5 피드백 #2).
///
/// 이 앱은 `LSUIElement`(accessory) 메뉴바 앱이라 일반 창을 앞으로 가져오려면
/// 활성화 정책을 일시적으로 `.regular`로 올려야 한다. 창을 닫으면 다시 `.accessory`로
/// 되돌려 Dock 아이콘이 상시 노출되지 않게 한다.
///
/// SwiftUI `Settings` scene을 쓰지 않고 별도 `NSWindow`로 구현한 이유: `Settings` scene은
/// `MenuBarExtra`-only 앱에서 표준 "환경설정" 메뉴(⌘,)에 의존해 트리거가 불안정하고,
/// 우리는 메뉴 버튼/HUD/권한 안내 등 여러 진입점에서 결정적으로 띄워야 하기 때문.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let appState: AppState
    private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
    }

    /// 설정 창을 띄운다(없으면 생성). 이미 떠 있고 다른 창에 가려져 있어도 항상 맨 앞으로 올린다.
    func show() {
        let isNew = (window == nil)
        let window = window ?? makeWindow()
        self.window = window

        // accessory 앱 → 창을 앞으로 가져오려면 잠시 regular로.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 최초 생성 시에만 중앙 배치(이미 떠 있던 창은 사용자가 옮긴 위치 유지).
        if isNew { window.center() }

        // 가려져 있어도 확실히 최상위로: makeKeyAndOrderFront + orderFrontRegardless.
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "liveTranslate 설정"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(appState: appState))
        return window
    }

    // 창을 닫으면 다시 accessory로 — Dock 아이콘 상시 노출 방지.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
