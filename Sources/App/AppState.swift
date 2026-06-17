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

    /// 자막 누적 엔진 (M2a). Gemini 수신 텍스트를 모아 HUD에 노출.
    let subtitles: SubtitleEngine

    // MARK: - Gemini 연동 (M2a)

    /// Gemini 연결/번역 상태 라벨(메뉴/HUD 표시용). 키는 절대 포함하지 않는다.
    private(set) var geminiStatus: String = "연결 안 됨"

    /// 번역 세션이 연결 가능 상태인지(키 존재 + 연결 시도 중/완료).
    private(set) var translating: Bool = false

    /// 현재 살아있는 Gemini 클라이언트(actor). 정지 시 해제.
    @ObservationIgnored private var gemini: GeminiLiveClient?
    /// 수신 이벤트 소비 Task.
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    /// 설정 창 컨트롤러 (M1.5). lazy: 실제 열 때 생성.
    /// `@Observable`과 `lazy`가 충돌하므로 관찰 대상에서 제외한다(UI가 추적할 필요 없음).
    @ObservationIgnored private(set) lazy var settingsWindow = SettingsWindowController(appState: self)

    /// 키 로딩 추상화. 개발 빌드는 .env, 배포 빌드는 Keychain 구현으로 교체 가능.
    private let apiKeyProvider: APIKeyProvider

    init(apiKeyProvider: APIKeyProvider = DotEnvAPIKeyProvider()) {
        self.apiKeyProvider = apiKeyProvider
        let audio = AudioInputManager()
        let settings = SettingsStore()
        let subtitles = SubtitleEngine()
        self.audio = audio
        self.settings = settings
        self.subtitles = subtitles
        self.hud = HUDController(audio: audio, settings: settings, subtitles: subtitles)
        // 실행 시 키 로드 시도 (값 자체는 저장하지 않고 로드 여부만 노출).
        self.apiKeyLoaded = apiKeyProvider.geminiAPIKey() != nil
    }

    /// 캡처 토글 (메뉴바 "번역 시작/정지"). M1a에서는 오디오 캡처만 켜고 끈다.
    /// 캡처 상태에 따라 HUD 자동 표시/숨김 정책을 적용한다. M2에서 Gemini 연결이 추가된다.
    func toggleCapture() {
        if audio.isCapturing {
            audio.stop()
            isRunning = false
            stopGemini()
            hud.applyCapturePolicy(isCapturing: false)
        } else {
            // M2a: 키가 없으면 캡처도 시작하지 않고 graceful 안내.
            guard let key = geminiAPIKey(), !key.isEmpty else {
                geminiStatus = "API 키 없음 — .env의 GEMINI_API_KEY를 설정하세요"
                hud.applyCapturePolicy(isCapturing: false)
                return
            }
            audio.requestPermissionAndStart()
            // 권한 콜백 후 isCapturing이 true가 되며, UI는 audio.isCapturing을 직접 관찰한다.
            isRunning = true
            startGemini(apiKey: key)
            hud.applyCapturePolicy(isCapturing: true)
        }
    }

    // MARK: - Gemini 수명주기 (M2a)

    /// Gemini 연결을 시작하고 오디오 파이프라인(onChunk → sendAudio)을 배선한다.
    /// "번역 시작" 시 호출. 키는 호출자가 검증해 전달한다(로그/HUD에 키 노출 금지).
    private func startGemini(apiKey: String) {
        // 이전 세션 잔재 정리.
        stopGemini()
        subtitles.reset()

        let client = GeminiLiveClient(
            apiKey: apiKey,
            targetLanguageCode: settings.targetLanguageCode
        )
        self.gemini = client
        translating = true
        geminiStatus = "연결 중…"

        // 오디오 스레드의 발화 청크를 actor로 hop해 송신한다.
        // onChunk는 @Sendable — client는 actor라 안전하게 캡처 가능.
        audio.onChunk = { chunk in
            Task { await client.sendAudio(chunk) }
        }

        // 이벤트 스트림 소비(연결/상태/번역 텍스트) — MainActor에서 HUD/상태 갱신.
        eventTask = Task { [weak self] in
            let stream = await client.connect()
            for await event in stream {
                guard let self else { break }
                self.handle(event)
            }
        }
    }

    /// Gemini 연결을 종료하고 파이프라인을 해제한다("번역 정지").
    private func stopGemini() {
        audio.onChunk = nil
        eventTask?.cancel()
        eventTask = nil
        if let client = gemini {
            Task { await client.stop() }
        }
        gemini = nil
        translating = false
        geminiStatus = "연결 안 됨"
    }

    /// Gemini 이벤트를 상태/자막으로 반영한다(MainActor).
    private func handle(_ event: GeminiLiveClient.Event) {
        switch event {
        case .state(let state):
            switch state {
            case .disconnected: geminiStatus = "연결 안 됨"
            case .connecting: geminiStatus = "연결 중…"
            case .ready: geminiStatus = "번역 중"
            case .error(let message): geminiStatus = message  // 키 미포함(클라이언트가 보장)
            }
        case .translation(let text, let isFinal):
            subtitles.ingestTranslation(text, isFinal: isFinal)
        case .source(let text, let isFinal):
            subtitles.ingestSource(text, isFinal: isFinal)
        case .info(let message):
            geminiStatus = message
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
