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

    /// 제어 HUD(상시 플로팅) 컨트롤러 (M1.5 → M3 재구성).
    let hud: HUDController

    /// 자막 누적/표시 엔진 (M2a → M3 영화 자막식 표시). Gemini 수신 텍스트를 자막 HUD에 노출.
    let subtitles: SubtitleEngine

    /// 자막 HUD(최상위 클릭통과 오버레이) 컨트롤러 (M3).
    let subtitleOverlay: SubtitleOverlayController

    /// 비용 추정기 (M2b, 태스크 C). 세션/누적 비용을 추적해 HUD/설정에 노출.
    let cost: CostEstimator

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
        // SettingsStore를 먼저 만들어 AudioInputManager에 주입한다(입력 소스 영속화/기본값 규칙, 태스크 A).
        let settings = SettingsStore()
        let audio = AudioInputManager(settings: settings)
        let subtitles = SubtitleEngine(settings: settings)
        self.audio = audio
        self.settings = settings
        self.subtitles = subtitles
        self.cost = CostEstimator(settings: settings)
        self.hud = HUDController(audio: audio, settings: settings)
        self.subtitleOverlay = SubtitleOverlayController(engine: subtitles, settings: settings)
        // 실행 시 키 로드 시도 (값 자체는 저장하지 않고 로드 여부만 노출).
        self.apiKeyLoaded = apiKeyProvider.geminiAPIKey() != nil
        // 제어 HUD가 시작/정지·설정 버튼을 호출할 수 있도록 배선(self 완성 후).
        self.hud.bind(appState: self)
    }

    /// 캡처 토글 (메뉴바 "번역 시작/정지"). M1a에서는 오디오 캡처만 켜고 끈다.
    /// 번역 시작/정지. **자막 HUD만** 캡처 상태에 연동하고, 제어 HUD는 건드리지 않는다.
    /// (제어 HUD는 메뉴 "제어 HUD 표시" 토글로만 표시/숨김 — 정지해도 남아 있어야 함.)
    func toggleCapture() {
        // 시작/정지의 단일 진실은 `isRunning`(사용자 의도)이다.
        // `audio.isCapturing`은 입력 소스 hot-swap 재시작 실패(-10877 등)로
        // 사용자 의도와 어긋날 수 있으므로 분기 기준으로 쓰지 않는다.
        // (이전 버그: hot-swap 실패로 isCapturing=false → "정지"가 else(시작) 분기로 오작동)
        if isRunning {
            stopSession()
        } else {
            startSession()
        }
    }

    /// 번역 세션을 깨끗하게 시작한다. 항상 새 audio + 새 Gemini + 자막 정책 on.
    private func startSession() {
        // M2a: 키가 없으면 캡처도 시작하지 않고 graceful 안내.
        guard let key = geminiAPIKey(), !key.isEmpty else {
            geminiStatus = "API 키 없음 — .env의 GEMINI_API_KEY를 설정하세요"
            return
        }
        // 의도를 먼저 확정(이후 콜백/hot-swap 경로가 이 값을 신뢰한다).
        isRunning = true
        startGemini(apiKey: key)
        audio.requestPermissionAndStart()
        // 권한 콜백 후 isCapturing이 true가 된다. UI는 isRunning(버튼 상태)과
        // audio.isCapturing(실제 캡처 표시)을 각각 관찰한다.
        subtitleOverlay.applyCapturePolicy(isCapturing: true)
    }

    /// 번역 세션을 확실히 정지한다. audio + Gemini + 자막 오버레이 모두 내려간다.
    /// 어떤 경로(정상 정지/오류 정리)로 들어와도 동일하게 동작한다(멱등).
    private func stopSession() {
        isRunning = false
        audio.stop()
        stopGemini()
        subtitleOverlay.applyCapturePolicy(isCapturing: false)
    }

    // MARK: - Gemini 수명주기 (M2a)

    /// Gemini 연결을 시작하고 오디오 파이프라인(onChunk → sendAudio)을 배선한다.
    /// "번역 시작" 시 호출. 키는 호출자가 검증해 전달한다(로그/HUD에 키 노출 금지).
    private func startGemini(apiKey: String) {
        // 이전 세션 잔재 정리(이전 client.stop()으로 stopped=true 보장 → 재연결 차단).
        stopGemini()
        subtitles.reset()
        cost.resetSession()   // 세션 비용은 번역 시작마다 0에서 시작(누적은 유지, 태스크 C).

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
        // 현재 client를 지역 변수로 분리한 뒤 즉시 self.gemini를 비운다.
        // client.stop()은 actor 내부에서 stopped=true + generation++ + teardownSocket()을
        // 동기적으로 수행하므로, 이 stop이 끝나면 해당 client는 어떤 경로로도 재연결하지 않는다.
        // (각 client는 독립적이라 새 세션 생성과 이전 세션 정지가 서로를 오염시키지 않는다.)
        let client = gemini
        gemini = nil
        translating = false
        geminiStatus = "연결 안 됨"
        if let client {
            Task { await client.stop() }
        }
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
        case .translation(let delta):
            subtitles.ingestTranslationDelta(delta)
        case .source(let delta):
            subtitles.ingestSourceDelta(delta)
        case .turnComplete:
            subtitles.ingestTurnComplete()
        case .sentAudio(let sampleCount):
            cost.addSentAudio(sampleCount: sampleCount)   // 입력 비용 누적(태스크 C).
        case .outputTokens(let tokens):
            cost.addOutputTokens(tokens)                  // 출력 비용 누적(태스크 C).
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
