import CoreGraphics
import Foundation
import Observation
import SwiftUI

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
        // 선택된 모델 카탈로그 id (spec 005 §4)
        static let selectedModelID = "model.selectedID"
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
        static let subtitleVerticalOffset = "subtitle.verticalOffset"
        static let subtitleAutoShowOnCapture = "subtitle.autoShowOnCapture"
        // 자막 스타일 (M4, FR-7) — 색은 sRGB "#RRGGBBAA" 문자열로 영속.
        static let subtitleFontName = "subtitle.style.fontName"
        static let subtitleFontSize = "subtitle.style.fontSize"
        static let subtitleFontWeight = "subtitle.style.weight"
        static let subtitleTextColor = "subtitle.style.textColor"
        static let subtitleStrokeEnabled = "subtitle.style.strokeEnabled"
        static let subtitleStrokeColor = "subtitle.style.strokeColor"
        static let subtitleGlowEnabled = "subtitle.style.glowEnabled"
        static let subtitleGlowColor = "subtitle.style.glowColor"
        static let subtitleGlowRadius = "subtitle.style.glowRadius"
        static let subtitleBackgroundEnabled = "subtitle.style.bgEnabled"
        static let subtitleBackgroundOpacity = "subtitle.style.bgOpacity"
        static let subtitleTextAlign = "subtitle.style.align"
        static let subtitleMaxLines = "subtitle.style.maxLines"
        // 번역 오디오 출력/덕킹 (M3+)
        static let translatedAudioPlaybackEnabled = "audio.playback.enabled"
        static let translatedAudioVolume = "audio.playback.volume"
        static let translatedAudioOutputDeviceUID = "audio.playback.outputDeviceUID"
        static let originalAudioDuckingEnabled = "audio.duck.enabled"
        static let originalAudioDuckVolume = "audio.duck.volume"
    }

    /// 번역 오디오 출력/덕킹 기본값(리셋 시에도 동일 사용). 결정적 상수만.
    private enum AudioDefault {
        static let playbackEnabled = false
        static let volume = 1.0
        static let duckingEnabled = true
        static let duckVolume = 0.3
    }

    /// 자막 스타일 기본값(리셋 시에도 동일 사용). 결정적 상수만.
    private enum StyleDefault {
        static let fontName = ""
        static let fontSize = 34.0
        static let weight = SubtitleFontWeight.bold
        static let textColorHex = "#FFFFFFFF"
        static let strokeEnabled = true
        static let strokeColorHex = "#000000E6"
        static let glowEnabled = false
        static let glowColorHex = "#00E5FFCC"
        static let glowRadius = 8.0
        static let backgroundEnabled = true
        static let backgroundOpacity = 0.35
        static let align = SubtitleTextAlign.center
        static let maxLines = 2
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 기본값 등록(키가 없을 때만 적용) — 첫 실행 정책을 결정적으로 만든다.
        defaults.register(defaults: [
            Key.monitorEnabled: true,
            Key.monitorAutoShowOnCapture: true,
            Key.monitorHideOnStop: true,
            Key.subtitleVerticalPosition: SubtitleVerticalPosition.bottom.rawValue,
            // 영역(상/중/하) 내 세부 세로 위치 기본값 0.5(영역 중간). register로 0 충돌 방지.
            Key.subtitleVerticalOffset: 0.5,
            Key.subtitleAutoShowOnCapture: true,
            // 자막 2줄 분량 휴리스틱 기본값(번역 텍스트 기준 누적 글자수). 한국어 자막 ~2줄.
            Key.subtitleMaxCharsBeforeBreak: AppConfig.defaultMaxCharsBeforeBreak,
            // 비용 HUD 기본 on(스펙 §9.4 — 세션 비용 가시화).
            Key.costHUDEnabled: true,
            // 선택 모델 기본값(첫 모델 id) — 카탈로그 진실원과 일치(spec 005 §4).
            Key.selectedModelID: SettingsStore.defaultModelID,
            // 자막 스타일 기본값(M4, FR-7).
            Key.subtitleFontName: StyleDefault.fontName,
            Key.subtitleFontSize: StyleDefault.fontSize,
            Key.subtitleFontWeight: StyleDefault.weight.rawValue,
            Key.subtitleTextColor: StyleDefault.textColorHex,
            Key.subtitleStrokeEnabled: StyleDefault.strokeEnabled,
            Key.subtitleStrokeColor: StyleDefault.strokeColorHex,
            Key.subtitleGlowEnabled: StyleDefault.glowEnabled,
            Key.subtitleGlowColor: StyleDefault.glowColorHex,
            Key.subtitleGlowRadius: StyleDefault.glowRadius,
            Key.subtitleBackgroundEnabled: StyleDefault.backgroundEnabled,
            Key.subtitleBackgroundOpacity: StyleDefault.backgroundOpacity,
            Key.subtitleTextAlign: StyleDefault.align.rawValue,
            Key.subtitleMaxLines: StyleDefault.maxLines,
            // 번역 오디오 출력/덕킹(M3+). Double 기본값은 register로 처리해 0 충돌 방지.
            Key.translatedAudioPlaybackEnabled: AudioDefault.playbackEnabled,
            Key.translatedAudioVolume: AudioDefault.volume,
            Key.originalAudioDuckingEnabled: AudioDefault.duckingEnabled,
            Key.originalAudioDuckVolume: AudioDefault.duckVolume,
        ])
        self.monitorEnabled = defaults.bool(forKey: Key.monitorEnabled)
        self.monitorAutoShowOnCapture = defaults.bool(forKey: Key.monitorAutoShowOnCapture)
        self.monitorHideOnStop = defaults.bool(forKey: Key.monitorHideOnStop)
        self.targetLanguageCode =
            defaults.string(forKey: Key.targetLanguageCode) ?? AppConfig.defaultTargetLanguageCode
        self.showSourceText = defaults.bool(forKey: Key.showSourceText)
        self.selectedModelID =
            defaults.string(forKey: Key.selectedModelID) ?? SettingsStore.defaultModelID
        self.subtitleScreenID = defaults.object(forKey: Key.subtitleScreenID) as? Int
        self.subtitleVerticalPosition =
            SubtitleVerticalPosition(
                rawValue: defaults.string(forKey: Key.subtitleVerticalPosition) ?? ""
            ) ?? .bottom
        self.subtitleVerticalOffset = defaults.double(forKey: Key.subtitleVerticalOffset)
        self.subtitleAutoShowOnCapture = defaults.bool(forKey: Key.subtitleAutoShowOnCapture)
        self.subtitleMaxCharsBeforeBreak = defaults.integer(forKey: Key.subtitleMaxCharsBeforeBreak)
        self.costHUDEnabled = defaults.bool(forKey: Key.costHUDEnabled)
        // 자막 스타일 복원(M4). enum은 raw 저장/복원 패턴, 색은 hex 문자열로 영속.
        self.subtitleFontName = defaults.string(forKey: Key.subtitleFontName) ?? StyleDefault.fontName
        self.subtitleFontSize = defaults.double(forKey: Key.subtitleFontSize)
        self.subtitleFontWeight =
            SubtitleFontWeight(rawValue: defaults.string(forKey: Key.subtitleFontWeight) ?? "")
            ?? StyleDefault.weight
        self.subtitleTextColorHex =
            defaults.string(forKey: Key.subtitleTextColor) ?? StyleDefault.textColorHex
        self.subtitleStrokeEnabled = defaults.bool(forKey: Key.subtitleStrokeEnabled)
        self.subtitleStrokeColorHex =
            defaults.string(forKey: Key.subtitleStrokeColor) ?? StyleDefault.strokeColorHex
        self.subtitleGlowEnabled = defaults.bool(forKey: Key.subtitleGlowEnabled)
        self.subtitleGlowColorHex =
            defaults.string(forKey: Key.subtitleGlowColor) ?? StyleDefault.glowColorHex
        self.subtitleGlowRadius = defaults.double(forKey: Key.subtitleGlowRadius)
        self.subtitleBackgroundEnabled = defaults.bool(forKey: Key.subtitleBackgroundEnabled)
        self.subtitleBackgroundOpacity = defaults.double(forKey: Key.subtitleBackgroundOpacity)
        self.subtitleTextAlign =
            SubtitleTextAlign(rawValue: defaults.string(forKey: Key.subtitleTextAlign) ?? "")
            ?? StyleDefault.align
        self.subtitleMaxLines = defaults.integer(forKey: Key.subtitleMaxLines)
        // 번역 오디오 출력/덕킹 복원(M3+). Double은 register 기본값 덕분에 0 충돌 없음.
        self.translatedAudioPlaybackEnabled = defaults.bool(forKey: Key.translatedAudioPlaybackEnabled)
        self.translatedAudioVolume = defaults.double(forKey: Key.translatedAudioVolume)
        self.originalAudioDuckingEnabled = defaults.bool(forKey: Key.originalAudioDuckingEnabled)
        self.originalAudioDuckVolume = defaults.double(forKey: Key.originalAudioDuckVolume)
        // 출력 장치 UID 복원(미설정이면 nil = 시스템 기본 출력).
        self.translatedAudioOutputDeviceUID = defaults.string(forKey: Key.translatedAudioOutputDeviceUID)
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

    /// 선택한 영역(상/중/하) 안에서의 세부 세로 위치(0=영역 위, 1=영역 아래, 기본 0.5).
    /// 0~1로 클램프해 저장한다. 오버레이 뷰가 영역 밴드와 결합해 박스 위치를 계산한다.
    var subtitleVerticalOffset: Double {
        didSet {
            let clamped = min(1.0, max(0.0, subtitleVerticalOffset))
            if clamped != subtitleVerticalOffset {
                subtitleVerticalOffset = clamped
                return  // 재대입이 didSet을 다시 호출하므로 여기서 종료.
            }
            defaults.set(subtitleVerticalOffset, forKey: Key.subtitleVerticalOffset)
        }
    }

    /// 캡처 시작 시 자막 HUD 자동 표시(기본 on), 정지 시 숨김.
    var subtitleAutoShowOnCapture: Bool {
        didSet { defaults.set(subtitleAutoShowOnCapture, forKey: Key.subtitleAutoShowOnCapture) }
    }

    // MARK: - 자막 스타일 (M4, FR-7 / 스펙 §5.5)

    /// 자막 폰트 패밀리명("" = 시스템 rounded).
    var subtitleFontName: String {
        didSet { defaults.set(subtitleFontName, forKey: Key.subtitleFontName) }
    }

    /// 자막 폰트 크기(pt, UI 범위 16...72).
    var subtitleFontSize: Double {
        didSet { defaults.set(subtitleFontSize, forKey: Key.subtitleFontSize) }
    }

    /// 자막 글자 두께(raw 저장).
    var subtitleFontWeight: SubtitleFontWeight {
        didSet { defaults.set(subtitleFontWeight.rawValue, forKey: Key.subtitleFontWeight) }
    }

    /// 자막 글자색(sRGB "#RRGGBBAA"로 영속). UI는 `subtitleTextColor` 사용.
    var subtitleTextColorHex: String {
        didSet { defaults.set(subtitleTextColorHex, forKey: Key.subtitleTextColor) }
    }

    /// 외곽선(그림자) 사용 여부.
    var subtitleStrokeEnabled: Bool {
        didSet { defaults.set(subtitleStrokeEnabled, forKey: Key.subtitleStrokeEnabled) }
    }

    /// 외곽선 색(sRGB hex 영속). UI는 `subtitleStrokeColor` 사용.
    var subtitleStrokeColorHex: String {
        didSet { defaults.set(subtitleStrokeColorHex, forKey: Key.subtitleStrokeColor) }
    }

    /// 글로우 사용 여부(기본 off).
    var subtitleGlowEnabled: Bool {
        didSet { defaults.set(subtitleGlowEnabled, forKey: Key.subtitleGlowEnabled) }
    }

    /// 글로우 색(sRGB hex 영속). UI는 `subtitleGlowColor` 사용.
    var subtitleGlowColorHex: String {
        didSet { defaults.set(subtitleGlowColorHex, forKey: Key.subtitleGlowColor) }
    }

    /// 글로우 반경(UI 범위 0...30).
    var subtitleGlowRadius: Double {
        didSet { defaults.set(subtitleGlowRadius, forKey: Key.subtitleGlowRadius) }
    }

    /// 배경 박스 사용 여부.
    var subtitleBackgroundEnabled: Bool {
        didSet { defaults.set(subtitleBackgroundEnabled, forKey: Key.subtitleBackgroundEnabled) }
    }

    /// 배경 박스 불투명도(0...1).
    var subtitleBackgroundOpacity: Double {
        didSet { defaults.set(subtitleBackgroundOpacity, forKey: Key.subtitleBackgroundOpacity) }
    }

    /// 자막 가로 정렬(raw 저장).
    var subtitleTextAlign: SubtitleTextAlign {
        didSet { defaults.set(subtitleTextAlign.rawValue, forKey: Key.subtitleTextAlign) }
    }

    /// 자막 최대 줄수(UI 범위 1...4).
    var subtitleMaxLines: Int {
        didSet { defaults.set(subtitleMaxLines, forKey: Key.subtitleMaxLines) }
    }

    // 색 UI 편의용 Color 계산 프로퍼티(hex 문자열과 양방향 변환).

    /// 자막 글자색(ColorPicker 바인딩용). 내부적으로 hex 문자열에 영속.
    var subtitleTextColor: Color {
        get { Color(hexRGBA: subtitleTextColorHex, fallback: .white) }
        set { subtitleTextColorHex = newValue.toHexRGBA() }
    }

    /// 외곽선 색(ColorPicker 바인딩용).
    var subtitleStrokeColor: Color {
        get { Color(hexRGBA: subtitleStrokeColorHex, fallback: .black) }
        set { subtitleStrokeColorHex = newValue.toHexRGBA() }
    }

    /// 글로우 색(ColorPicker 바인딩용).
    var subtitleGlowColor: Color {
        get { Color(hexRGBA: subtitleGlowColorHex, fallback: Color(.sRGB, red: 0, green: 0.9, blue: 1, opacity: 0.8)) }
        set { subtitleGlowColorHex = newValue.toHexRGBA() }
    }

    /// 모든 자막 스타일 속성을 기본값으로 되돌린다(설정 "스타일 기본값으로 리셋").
    func resetSubtitleStyle() {
        subtitleFontName = StyleDefault.fontName
        subtitleFontSize = StyleDefault.fontSize
        subtitleFontWeight = StyleDefault.weight
        subtitleTextColorHex = StyleDefault.textColorHex
        subtitleStrokeEnabled = StyleDefault.strokeEnabled
        subtitleStrokeColorHex = StyleDefault.strokeColorHex
        subtitleGlowEnabled = StyleDefault.glowEnabled
        subtitleGlowColorHex = StyleDefault.glowColorHex
        subtitleGlowRadius = StyleDefault.glowRadius
        subtitleBackgroundEnabled = StyleDefault.backgroundEnabled
        subtitleBackgroundOpacity = StyleDefault.backgroundOpacity
        subtitleTextAlign = StyleDefault.align
        subtitleMaxLines = StyleDefault.maxLines
    }

    // MARK: - 번역 오디오 출력/덕킹 (M3+)

    /// 번역 결과 오디오(Gemini 출력)를 스피커로 재생할지(기본 off — 자막 전용).
    /// on이면 AppState가 TranslatedAudioPlayer를 켜고 GeminiLiveClient에 재생 플래그를 전달한다.
    var translatedAudioPlaybackEnabled: Bool {
        didSet { defaults.set(translatedAudioPlaybackEnabled, forKey: Key.translatedAudioPlaybackEnabled) }
    }

    /// 번역 오디오 소프트웨어 재생 볼륨(0...1, 기본 1.0). 시스템 출력 볼륨과 별개.
    var translatedAudioVolume: Double {
        didSet { defaults.set(translatedAudioVolume, forKey: Key.translatedAudioVolume) }
    }

    /// 번역 재생 중 원문(시스템) 소리를 덕킹할지(기본 on).
    /// 주의: 번역 오디오도 같은 출력 장치로 나가므로 함께 작아진다(설계상 부분 덕킹).
    var originalAudioDuckingEnabled: Bool {
        didSet { defaults.set(originalAudioDuckingEnabled, forKey: Key.originalAudioDuckingEnabled) }
    }

    /// 덕킹 시 낮출 목표 출력 볼륨(0...1, 기본 0.3).
    var originalAudioDuckVolume: Double {
        didSet { defaults.set(originalAudioDuckVolume, forKey: Key.originalAudioDuckVolume) }
    }

    /// 번역 오디오를 내보낼 출력 장치 UID. nil이면 시스템 기본 출력 사용(기본값).
    /// 피드백 방지를 위해 캡처용 가상 장치가 아닌 스피커/헤드폰을 권장한다.
    /// subtitleScreenID(Int?)와 동일한 nil=removeObject 패턴으로 결정적 영속화한다.
    var translatedAudioOutputDeviceUID: String? {
        didSet {
            if let uid = translatedAudioOutputDeviceUID {
                defaults.set(uid, forKey: Key.translatedAudioOutputDeviceUID)
            } else {
                defaults.removeObject(forKey: Key.translatedAudioOutputDeviceUID)
            }
        }
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

    // MARK: - 모델 선택 (spec 005)

    /// 첫 모델 id 기본값. 카탈로그 진실원(`Resources/models.json`의 첫 모델)과 일치해야 한다.
    static let defaultModelID = "gemini-3.5-live-translate"

    /// 선택된 모델 카탈로그 id. `ModelCatalog.resolved(id:)`로 디스크립터를 해석한다.
    /// 변경 시 AppState가 핫스왑(번역 중) 또는 다음 시작에 반영한다.
    var selectedModelID: String {
        didSet { defaults.set(selectedModelID, forKey: Key.selectedModelID) }
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

    // MARK: - 전체 리셋

    /// 모든 사용자 설정을 초기 기본값으로 되돌린다(설정 "전체 초기화").
    /// **주의: API 키(Keychain)는 건드리지 않는다 — 호출자가 별도로 처리한다.**
    ///
    /// 절차: (1) Key/StyleDefault/AudioDefault의 모든 영속 키를 removeObject로 제거하고,
    /// (2) keyless/계산 프로퍼티(누적 비용·HUD 위치·입력 선택·자막 화면ID)도 초기화한 뒤,
    /// (3) in-memory @Observable 프로퍼티들을 각자의 기본 상수로 재대입해 didSet이
    /// register 기본값을 다시 쓰도록 한다. 한 곳에서 일관되게 처리한다.
    func resetAll() {
        // (1) 영속 키 제거 — 이후 in-memory 재대입의 didSet이 기본값을 다시 기록한다.
        let allKeys = [
            Key.monitorEnabled, Key.monitorAutoShowOnCapture, Key.monitorHideOnStop,
            Key.monitorFrameX, Key.monitorFrameY, Key.monitorHasSavedPosition,
            Key.targetLanguageCode, Key.showSourceText, Key.selectedModelID,
            Key.inputSelectionKind, Key.inputSelectionDeviceUID,
            Key.subtitleMaxCharsBeforeBreak,
            Key.costHUDEnabled, Key.costCumulativeInputUSD, Key.costCumulativeOutputUSD,
            Key.subtitleScreenID, Key.subtitleVerticalPosition, Key.subtitleVerticalOffset,
            Key.subtitleAutoShowOnCapture,
            Key.subtitleFontName, Key.subtitleFontSize, Key.subtitleFontWeight,
            Key.subtitleTextColor, Key.subtitleStrokeEnabled, Key.subtitleStrokeColor,
            Key.subtitleGlowEnabled, Key.subtitleGlowColor, Key.subtitleGlowRadius,
            Key.subtitleBackgroundEnabled, Key.subtitleBackgroundOpacity,
            Key.subtitleTextAlign, Key.subtitleMaxLines,
            Key.translatedAudioPlaybackEnabled, Key.translatedAudioVolume,
            Key.translatedAudioOutputDeviceUID,
            Key.originalAudioDuckingEnabled, Key.originalAudioDuckVolume,
        ]
        for key in allKeys { defaults.removeObject(forKey: key) }

        // (2) keyless/별도 항목 초기화.
        resetCumulativeCost()      // 누적 비용 0
        resetMonitorPosition()     // HUD 저장 위치 제거
        subtitleScreenID = nil     // 자막 화면 선택 해제(주 화면 폴백)

        // (3) in-memory @Observable 재대입 → didSet이 기본값을 영속화한다.
        monitorEnabled = true
        monitorAutoShowOnCapture = true
        monitorHideOnStop = true
        targetLanguageCode = AppConfig.defaultTargetLanguageCode
        showSourceText = false
        selectedModelID = SettingsStore.defaultModelID
        subtitleMaxCharsBeforeBreak = AppConfig.defaultMaxCharsBeforeBreak
        costHUDEnabled = true
        subtitleVerticalPosition = .bottom
        subtitleVerticalOffset = 0.5
        subtitleAutoShowOnCapture = true
        // 자막 스타일은 기존 전용 리셋 경로를 재사용(색 hex 3개 포함).
        resetSubtitleStyle()
        // 번역 오디오 출력/덕킹.
        translatedAudioPlaybackEnabled = AudioDefault.playbackEnabled
        translatedAudioVolume = AudioDefault.volume
        translatedAudioOutputDeviceUID = nil   // 시스템 기본 출력으로 복귀
        originalAudioDuckingEnabled = AudioDefault.duckingEnabled
        originalAudioDuckVolume = AudioDefault.duckVolume
    }
}
