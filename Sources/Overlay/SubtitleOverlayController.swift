import AppKit
import SwiftUI

/// 자막 HUD 오버레이 창의 수명주기/위치를 관리한다 (스펙 §5.3, M3).
///
/// - `SubtitleOverlayWindow`(클릭 통과·최상위) 1개를 생성/보관하고 `SubtitleOverlayView`를 붙인다.
/// - 표시/숨김, 설정의 자막 위치(모니터/세로)에 따른 배치, 화면 변경(연결/해제) 대응.
/// - 위치는 `SettingsStore`(UserDefaults)에 결정적으로 영속 — Date/난수 없음.
///
/// 자막 창은 화면 전체를 덮는 투명 오버레이로 두고, 텍스트 정렬은 SwiftUI(`SubtitleOverlayView`)가
/// 세로 위치에 따라 처리한다. 따라서 창 프레임 = 선택 화면의 `frame` 전체.
@MainActor
final class SubtitleOverlayController {

    private let engine: SubtitleEngine
    private let settings: SettingsStore
    private var window: SubtitleOverlayWindow?

    /// 화면 구성 변경(모니터 연결/해제) 알림 토큰.
    private var screenObserver: NSObjectProtocol?

    /// 현재 자막 HUD가 화면에 떠 있는지.
    private(set) var isVisible = false

    init(engine: SubtitleEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
        observeScreenChanges()
    }

    // 이 컨트롤러는 AppState가 앱 수명 내내 보유하므로 별도 deinit 정리는 두지 않는다
    // (MainActor 격리 프로퍼티를 nonisolated deinit에서 만질 수 없는 Swift 6 제약 회피).

    // MARK: - 표시/숨김

    /// 자막 HUD를 표시한다(없으면 생성). 선택 화면/세로 위치에 맞춰 배치.
    func show() {
        let window = window ?? makeWindow()
        self.window = window
        reposition(window)
        window.orderFrontRegardless()
        isVisible = true
    }

    /// 자막 HUD를 숨긴다(창은 재사용 위해 유지).
    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    /// 캡처 상태 변화에 따른 자동 표시/숨김 정책.
    func applyCapturePolicy(isCapturing: Bool) {
        if isCapturing {
            if settings.subtitleAutoShowOnCapture { show() }
        } else {
            hide()
        }
    }

    /// 설정에서 자막 위치(모니터/세로)가 바뀌었을 때 즉시 반영한다.
    func applyPositionChange() {
        guard let window else { return }
        reposition(window)
    }

    // MARK: - 내부

    private func makeWindow() -> SubtitleOverlayWindow {
        let rect = targetScreen()?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 200)
        let window = SubtitleOverlayWindow(contentRect: rect)
        // 콘텐츠는 1회만 생성한다. 세로 위치/오프셋/스타일은 뷰가 @Observable settings에서
        // 직접 읽어 실시간 반영하므로(호스팅 뷰 재생성 불필요), 슬라이더 드래그도 즉시 이동한다.
        window.setContent(SubtitleOverlayView(engine: engine, settings: settings))
        return window
    }

    /// 선택된 화면(모니터)으로 창 프레임만 갱신한다. 세로 위치/오프셋은 뷰가 settings를
    /// 직접 관찰해 반영하므로 콘텐츠를 재생성하지 않는다(매 슬라이더 틱 recreate 제거 → 부드러운 이동).
    private func reposition(_ window: SubtitleOverlayWindow) {
        guard let screen = targetScreen() else { return }
        window.setFrame(screen.frame, display: true)
    }

    /// 설정된 모니터를 찾는다. 없거나 분리됐으면 주 화면으로 폴백(합리적 폴백).
    private func targetScreen() -> NSScreen? {
        if let id = settings.subtitleScreenID,
           let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 모니터 연결/해제 시 자막 HUD를 현재 설정에 맞게 다시 배치한다.
    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 알림은 메인 큐에서 오므로 MainActor 작업으로 안전하게 호핑.
            Task { @MainActor in
                guard let self, let window = self.window, self.isVisible else { return }
                self.reposition(window)
            }
        }
    }
}

extension NSScreen {
    /// `CGDirectDisplayID`를 Int로 노출(설정 영속화 키로 사용). 없으면 nil.
    var displayID: Int? {
        guard let number = deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return number.intValue
    }

    /// 설정 UI에 표시할 사람이 읽는 화면 이름(주 화면 표기 포함).
    var menuLabel: String {
        let main = (self == NSScreen.main) ? " (주 화면)" : ""
        return localizedName + main
    }
}
