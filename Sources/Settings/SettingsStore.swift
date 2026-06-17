import Foundation
import Observation

/// 사용자 환경설정 영속화/반영 (스펙 §4.1).
///
/// M1.5 범위: 미니 HUD(모니터) 표시 정책 + HUD 창 위치 영속화.
/// 자막 스타일/언어 등 풍부한 설정(FR-7)은 M4로 미룬다(설정창에 placeholder).
///
/// 모든 값은 `UserDefaults`에 결정적으로 저장한다(Date/난수 금지). `@Observable`이라
/// SwiftUI 뷰가 변경을 즉시 반영한다.
@MainActor
@Observable
final class SettingsStore {

    private let defaults: UserDefaults

    private enum Key {
        static let monitorEnabled = "monitor.enabled"
        static let monitorAutoShowOnCapture = "monitor.autoShowOnCapture"
        static let monitorHideOnStop = "monitor.hideOnStop"
        static let monitorFrameX = "monitor.frame.x"
        static let monitorFrameY = "monitor.frame.y"
        static let monitorHasSavedPosition = "monitor.hasSavedPosition"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 기본값 등록(키가 없을 때만 적용) — 첫 실행 정책을 결정적으로 만든다.
        defaults.register(defaults: [
            Key.monitorEnabled: true,
            Key.monitorAutoShowOnCapture: true,
            Key.monitorHideOnStop: true,
        ])
        self.monitorEnabled = defaults.bool(forKey: Key.monitorEnabled)
        self.monitorAutoShowOnCapture = defaults.bool(forKey: Key.monitorAutoShowOnCapture)
        self.monitorHideOnStop = defaults.bool(forKey: Key.monitorHideOnStop)
    }

    // MARK: - 미니 HUD(모니터) 정책

    /// 사용자가 모니터 표시를 명시적으로 켰는지(마스터 토글).
    /// 이 값이 false면 캡처 중에도 HUD를 띄우지 않는다(사용자 의도 존중).
    var monitorEnabled: Bool {
        didSet { defaults.set(monitorEnabled, forKey: Key.monitorEnabled) }
    }

    /// 캡처 시작 시 HUD 자동 표시(기본 on).
    var monitorAutoShowOnCapture: Bool {
        didSet { defaults.set(monitorAutoShowOnCapture, forKey: Key.monitorAutoShowOnCapture) }
    }

    /// 캡처 정지 시 HUD 자동 숨김(기본 on).
    var monitorHideOnStop: Bool {
        didSet { defaults.set(monitorHideOnStop, forKey: Key.monitorHideOnStop) }
    }

    // MARK: - HUD 위치 영속화

    /// 저장된 HUD 좌상단(원점은 SwiftUI/AppKit 좌하단 기준 origin) 위치. 없으면 nil.
    var savedMonitorOrigin: CGPoint? {
        guard defaults.bool(forKey: Key.monitorHasSavedPosition) else { return nil }
        let x = defaults.double(forKey: Key.monitorFrameX)
        let y = defaults.double(forKey: Key.monitorFrameY)
        return CGPoint(x: x, y: y)
    }

    /// HUD 위치를 저장한다(드래그 종료 시 호출).
    func saveMonitorOrigin(_ origin: CGPoint) {
        defaults.set(Double(origin.x), forKey: Key.monitorFrameX)
        defaults.set(Double(origin.y), forKey: Key.monitorFrameY)
        defaults.set(true, forKey: Key.monitorHasSavedPosition)
    }

    /// HUD 위치를 초기화한다(설정창 "위치 리셋"). 다음 표시 시 기본 위치로 배치된다.
    func resetMonitorPosition() {
        defaults.removeObject(forKey: Key.monitorFrameX)
        defaults.removeObject(forKey: Key.monitorFrameY)
        defaults.set(false, forKey: Key.monitorHasSavedPosition)
    }
}
