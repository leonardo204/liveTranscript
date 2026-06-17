import AppKit
import SwiftUI

/// 미니 HUD(플로팅 모니터) 창의 수명주기/위치를 관리한다 (M1.5 피드백 #1).
///
/// - `FloatingPanel`을 1개 생성/보관하고 `MonitorHUD` SwiftUI 뷰를 붙인다.
/// - 표시/숨김 토글, 위치 저장/복원(`SettingsStore`), 화면 밖 방지.
/// - 위치는 `UserDefaults`(SettingsStore)에 결정적으로 저장 — Date/난수 없음.
@MainActor
final class HUDController {

    private let audio: AudioInputManager
    private let settings: SettingsStore
    private var panel: FloatingPanel?

    /// HUD 크기(고정). 스펙 권고 ~220×90.
    private static let hudSize = NSSize(width: 220, height: 90)

    /// 현재 HUD가 화면에 떠 있는지.
    private(set) var isVisible = false

    init(audio: AudioInputManager, settings: SettingsStore) {
        self.audio = audio
        self.settings = settings
    }

    /// HUD를 표시한다(없으면 생성). 마스터 토글(monitorEnabled)이 off면 무시.
    func show() {
        guard settings.monitorEnabled else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        positionPanel(panel)
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// HUD를 숨긴다(창은 재사용 위해 유지).
    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    /// 표시/숨김을 토글한다(메뉴 "모니터 표시").
    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// 캡처 상태 변화에 따라 자동 표시/숨김 정책을 적용한다.
    /// AppState가 캡처 토글 후 호출한다.
    func applyCapturePolicy(isCapturing: Bool) {
        guard settings.monitorEnabled else { hide(); return }
        if isCapturing {
            if settings.monitorAutoShowOnCapture { show() }
        } else {
            if settings.monitorHideOnStop { hide() }
        }
    }

    /// 설정에서 마스터 토글이 바뀌었을 때 반영한다.
    func applyEnabledPolicy() {
        if settings.monitorEnabled {
            // 캡처 중이고 자동 표시 정책이면 보여준다. 아니면 사용자가 메뉴로 켤 수 있게 둔다.
            if audio.isCapturing && settings.monitorAutoShowOnCapture {
                show()
            }
        } else {
            hide()
        }
    }

    /// 위치를 기본값으로 리셋하고, 떠 있으면 즉시 재배치한다.
    func resetPosition() {
        settings.resetMonitorPosition()
        if let panel { positionPanel(panel, forceDefault: true) }
    }

    // MARK: - 내부

    private func makePanel() -> FloatingPanel {
        let rect = NSRect(origin: .zero, size: Self.hudSize)
        let panel = FloatingPanel(contentRect: rect)
        panel.setContent(MonitorHUD(audio: audio))
        panel.onMoved = { [weak self] origin in
            // 드래그 종료 시 위치 저장(화면 내부로 클램프한 값).
            guard let self else { return }
            self.settings.saveMonitorOrigin(origin)
        }
        return panel
    }

    /// 저장된 위치(또는 기본 위치)로 패널을 배치하고 화면 밖이면 보정한다.
    private func positionPanel(_ panel: FloatingPanel, forceDefault: Bool = false) {
        let size = Self.hudSize
        let saved = forceDefault ? nil : settings.savedMonitorOrigin
        let origin = clampToScreen(origin: saved ?? defaultOrigin(size: size), size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// 기본 위치: 주 화면 우상단 근처(메뉴바 아래).
    private func defaultOrigin(size: NSSize) -> CGPoint {
        guard let screen = NSScreen.main else { return .zero }
        let vf = screen.visibleFrame
        let x = vf.maxX - size.width - 20
        let y = vf.maxY - size.height - 20
        return CGPoint(x: x, y: y)
    }

    /// origin을 어떤 화면이든 보이는 영역 안으로 클램프(화면 밖 방지).
    private func clampToScreen(origin: CGPoint, size: NSSize) -> CGPoint {
        // origin이 속한(또는 가장 가까운) 화면을 고른다. 없으면 주 화면.
        let rect = NSRect(origin: origin, size: size)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
            ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return origin }
        var x = origin.x
        var y = origin.y
        x = min(max(x, vf.minX), vf.maxX - size.width)
        y = min(max(y, vf.minY), vf.maxY - size.height)
        return CGPoint(x: x, y: y)
    }
}
