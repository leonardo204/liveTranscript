import CoreGraphics
import Foundation
import Observation

/// 자막 HUD의 화면 내 세로 위치(스펙 §5.3 — 하단 중앙 기본).
/// 결정적 raw 값으로 영속화한다(Date/난수 없음).
enum SubtitleVerticalPosition: String, CaseIterable, Identifiable {
    case top
    case center
    case bottom

    var id: String { rawValue }

    /// 설정 UI에 표시할 한글 라벨.
    var label: String {
        switch self {
        case .top: return "위"
        case .center: return "중앙"
        case .bottom: return "아래"
        }
    }
}

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
        static let targetLanguageCode = "translate.targetLanguageCode"
        static let showSourceText = "translate.showSourceText"
        // 입력 소스 선택 영속화 (태스크 A)
        static let inputSelectionKind = "input.selection.kind"   // "auto" | "systemTap" | "device"
        static let inputSelectionDeviceUID = "input.selection.deviceUID"
        // 자막 길이 기반 break 임계 (태스크 B)
        static let subtitleMaxCharsBeforeBreak = "subtitle.maxCharsBeforeBreak"
        // 비용 HUD 표시 + 누적 비용 (태스크 C)
        static let costHUDEnabled = "cost.hudEnabled"
        static let costCumulativeInputUSD = "cost.cumulativeInputUSD"
        static let costCumulativeOutputUSD = "cost.cumulativeOutputUSD"
        // 자막 HUD 위치 (M3)
        static let subtitleScreenID = "subtitle.screenID"
        static let subtitleVerticalPosition = "subtitle.verticalPosition"
        static let subtitleAutoShowOnCapture = "subtitle.autoShowOnCapture"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 기본값 등록(키가 없을 때만 적용) — 첫 실행 정책을 결정적으로 만든다.
        defaults.register(defaults: [
            Key.monitorEnabled: true,
            Key.monitorAutoShowOnCapture: true,
            Key.monitorHideOnStop: true,
            Key.subtitleVerticalPosition: SubtitleVerticalPosition.bottom.rawValue,
            Key.subtitleAutoShowOnCapture: true,
            // 자막 2줄 분량 휴리스틱 기본값(번역 텍스트 기준 누적 글자수). 한국어 자막 ~2줄.
            Key.subtitleMaxCharsBeforeBreak: AppConfig.defaultMaxCharsBeforeBreak,
            // 비용 HUD 기본 on(스펙 §9.4 — 세션 비용 가시화).
            Key.costHUDEnabled: true,
        ])
        self.monitorEnabled = defaults.bool(forKey: Key.monitorEnabled)
        self.monitorAutoShowOnCapture = defaults.bool(forKey: Key.monitorAutoShowOnCapture)
        self.monitorHideOnStop = defaults.bool(forKey: Key.monitorHideOnStop)
        self.targetLanguageCode =
            defaults.string(forKey: Key.targetLanguageCode) ?? AppConfig.defaultTargetLanguageCode
        self.showSourceText = defaults.bool(forKey: Key.showSourceText)
        self.subtitleScreenID = defaults.object(forKey: Key.subtitleScreenID) as? Int
        self.subtitleVerticalPosition =
            SubtitleVerticalPosition(
                rawValue: defaults.string(forKey: Key.subtitleVerticalPosition) ?? ""
            ) ?? .bottom
        self.subtitleAutoShowOnCapture = defaults.bool(forKey: Key.subtitleAutoShowOnCapture)
        self.subtitleMaxCharsBeforeBreak = defaults.integer(forKey: Key.subtitleMaxCharsBeforeBreak)
        self.costHUDEnabled = defaults.bool(forKey: Key.costHUDEnabled)
    }

    // MARK: - 입력 소스 영속화 (태스크 A)

    /// 사용자가 입력 소스를 한 번이라도 명시적으로 선택했는지.
    /// false면 "미설정"으로 보고 첫 실행 기본값(systemTap 우선) 규칙을 적용한다.
    var hasPersistedInputSelection: Bool {
        defaults.object(forKey: Key.inputSelectionKind) != nil
    }

    /// 영속된 입력 소스 선택을 복원한다. 미설정이면 nil(호출자가 기본값 규칙 적용).
    func loadInputSelection() -> InputSelection? {
        guard let kind = defaults.string(forKey: Key.inputSelectionKind) else { return nil }
        switch kind {
        case "auto": return .auto
        case "systemTap": return .systemTap
        case "device":
            if let uid = defaults.string(forKey: Key.inputSelectionDeviceUID) {
                return .device(uid)
            }
            return nil
        default:
            return nil
        }
    }

    /// 입력 소스 선택을 영속화한다(사용자 수동 선택 시 호출).
    func saveInputSelection(_ selection: InputSelection) {
        switch selection {
        case .auto:
            defaults.set("auto", forKey: Key.inputSelectionKind)
            defaults.removeObject(forKey: Key.inputSelectionDeviceUID)
        case .systemTap:
            defaults.set("systemTap", forKey: Key.inputSelectionKind)
            defaults.removeObject(forKey: Key.inputSelectionDeviceUID)
        case .device(let uid):
            defaults.set("device", forKey: Key.inputSelectionKind)
            defaults.set(uid, forKey: Key.inputSelectionDeviceUID)
        }
    }

    // MARK: - 자막 길이 break (태스크 B)

    /// 누적 중인 번역 줄이 이 글자수를 넘으면 현재까지를 확정하고 다음으로 넘긴다(영화 자막 ~2줄).
    /// 0/음수면 break 비활성으로 해석(호출자가 AppConfig 기본으로 폴백).
    var subtitleMaxCharsBeforeBreak: Int {
        didSet { defaults.set(subtitleMaxCharsBeforeBreak, forKey: Key.subtitleMaxCharsBeforeBreak) }
    }

    // MARK: - 비용 (태스크 C, 스펙 §9.4)

    /// 제어 HUD에 세션 비용 행을 표시할지(기본 on). off면 HUD에서 비용 행 숨김.
    var costHUDEnabled: Bool {
        didSet { defaults.set(costHUDEnabled, forKey: Key.costHUDEnabled) }
    }

    /// 누적 입력 비용(USD, 영속). CostEstimator가 세션 종료/업데이트 시 갱신한다.
    var cumulativeInputUSD: Double {
        get { defaults.double(forKey: Key.costCumulativeInputUSD) }
        set { defaults.set(newValue, forKey: Key.costCumulativeInputUSD) }
    }

    /// 누적 출력 비용(USD, 영속).
    var cumulativeOutputUSD: Double {
        get { defaults.double(forKey: Key.costCumulativeOutputUSD) }
        set { defaults.set(newValue, forKey: Key.costCumulativeOutputUSD) }
    }

    /// 누적 비용을 0으로 초기화한다(설정 "누적 리셋" 버튼).
    func resetCumulativeCost() {
        defaults.set(0.0, forKey: Key.costCumulativeInputUSD)
        defaults.set(0.0, forKey: Key.costCumulativeOutputUSD)
    }

    // MARK: - 자막 HUD 위치 (M3)

    /// 자막을 표시할 화면의 식별자(`NSScreen` `displayID`). nil이면 주 화면 폴백.
    /// 선택한 모니터가 분리되면 컨트롤러가 합리적 폴백(주 화면)을 적용한다.
    var subtitleScreenID: Int? {
        didSet {
            if let id = subtitleScreenID {
                defaults.set(id, forKey: Key.subtitleScreenID)
            } else {
                defaults.removeObject(forKey: Key.subtitleScreenID)
            }
        }
    }

    /// 자막의 세로 위치(위/중앙/아래, 기본 아래).
    var subtitleVerticalPosition: SubtitleVerticalPosition {
        didSet {
            defaults.set(subtitleVerticalPosition.rawValue, forKey: Key.subtitleVerticalPosition)
        }
    }

    /// 캡처 시작 시 자막 HUD 자동 표시(기본 on), 정지 시 숨김.
    var subtitleAutoShowOnCapture: Bool {
        didSet { defaults.set(subtitleAutoShowOnCapture, forKey: Key.subtitleAutoShowOnCapture) }
    }

    // MARK: - 번역 (M2a)

    /// 번역 대상 언어 코드(BCP-47, 기본 ko). GeminiLiveClient setup에 사용.
    /// 풍부한 언어 선택 UI는 M4 — 지금은 영속 값만 둔다.
    var targetLanguageCode: String {
        didSet { defaults.set(targetLanguageCode, forKey: Key.targetLanguageCode) }
    }

    /// 원문 동시 표시(FR-8, 기본 OFF — 번역만). HUD/메뉴 공통 참조.
    var showSourceText: Bool {
        didSet { defaults.set(showSourceText, forKey: Key.showSourceText) }
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
