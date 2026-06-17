import Foundation
import Observation

/// 앱 전역 상태 (M1.5).
///
/// 오디오 캡처 매니저 + 사용자 환경설정(SettingsStore) + 미니 HUD(HUDController) +
/// 설정 창(SettingsWindowController)을 소유하고 메뉴/HUD/설정창을 배선한다.
@MainActor
@Observable
final class AppState {
    /// 번역 세션 실행 중 여부. M1a부터 실제 오디오 캡처 상태와 연동된다.
    var isRunning: Bool = false

    /// API 키 로드 성공 여부. 메뉴바에 상태로 표시된다.
    private(set) var apiKeyLoaded: Bool = false

    /// 오디오 입력 캡처 매니저 (M1a). 입력 소스/레벨/start-stop을 소유.
    let audio: AudioInputManager

    /// 사용자 환경설정 영속화 (M1.5). HUD 표시 정책/위치 등.
    let settings: SettingsStore

    /// 미니 HUD(플로팅 모니터) 컨트롤러 (M1.5).
    let hud: HUDController

    /// 설정 창 컨트롤러 (M1.5). lazy: 실제 열 때 생성.
    /// `@Observable`과 `lazy`가 충돌하므로 관찰 대상에서 제외한다(UI가 추적할 필요 없음).
    @ObservationIgnored private(set) lazy var settingsWindow = SettingsWindowController(appState: self)

    /// 키 로딩 추상화. 개발 빌드는 .env, 배포 빌드는 Keychain 구현으로 교체 가능.
    private let apiKeyProvider: APIKeyProvider

    init(apiKeyProvider: APIKeyProvider = DotEnvAPIKeyProvider()) {
        self.apiKeyProvider = apiKeyProvider
        let audio = AudioInputManager()
        let settings = SettingsStore()
        self.audio = audio
        self.settings = settings
        self.hud = HUDController(audio: audio, settings: settings)
        // 실행 시 키 로드 시도 (값 자체는 저장하지 않고 로드 여부만 노출).
        self.apiKeyLoaded = apiKeyProvider.geminiAPIKey() != nil
    }

    /// 캡처 토글 (메뉴바 "번역 시작/정지"). M1a에서는 오디오 캡처만 켜고 끈다.
    /// 캡처 상태에 따라 HUD 자동 표시/숨김 정책을 적용한다. M2에서 Gemini 연결이 추가된다.
    func toggleCapture() {
        if audio.isCapturing {
            audio.stop()
            isRunning = false
            hud.applyCapturePolicy(isCapturing: false)
        } else {
            audio.requestPermissionAndStart()
            // 권한 콜백 후 isCapturing이 true가 되며, UI는 audio.isCapturing을 직접 관찰한다.
            // 권한이 즉시 허용된 경우(이미 승인됨)는 동기적으로 캡처가 시작될 수 있고,
            // 비동기 콜백 경로는 isCapturing 관찰로 HUD가 갱신된다. 정책은 즉시 한 번 적용.
            isRunning = true
            hud.applyCapturePolicy(isCapturing: true)
        }
    }

    /// 미니 HUD 표시/숨김 토글 (메뉴 "모니터 표시").
    /// 마스터 토글(monitorEnabled)이 꺼져 있으면 켠 뒤 표시한다.
    func toggleMonitor() {
        if !settings.monitorEnabled {
            settings.monitorEnabled = true
            hud.show()
        } else {
            hud.toggle()
        }
    }

    /// 설정 창을 연다 (메뉴 "설정…").
    func openSettings() {
        settingsWindow.show()
    }

    /// 필요 시점에 키를 조회한다 (메모리 상주 최소화를 위해 캐싱하지 않음).
    func geminiAPIKey() -> String? {
        apiKeyProvider.geminiAPIKey()
    }
}
