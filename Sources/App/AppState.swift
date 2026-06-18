import AppKit
import Foundation
import Observation
import Security

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

    /// 현재 키 출처(Keychain/env/없음). 설정 UI에 "현재: …"로 표시한다(값은 미포함).
    private(set) var keySource: ResolvedAPIKeyProvider.KeySource = .none

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

    /// 번역 출력 오디오 재생기(M3+). Gemini 출력 오디오(24kHz)를 스피커로 스트리밍.
    let translatedAudioPlayer = TranslatedAudioPlayer()

    /// 시스템 출력 덕킹(M3+). 번역 재생 중 원문(시스템) 소리를 낮춘다.
    /// 주의: 번역 오디오도 같은 출력 장치로 나가므로 함께 작아진다(설계상 부분 덕킹).
    let systemAudioDucker = SystemAudioDucker()

    // MARK: - Gemini 연동 (M2a)

    /// Gemini 연결/번역 상태 라벨(메뉴/HUD 표시용). 키는 절대 포함하지 않는다.
    private(set) var geminiStatus: String = "연결 안 됨"

    /// 번역 세션이 연결 가능 상태인지(키 존재 + 연결 시도 중/완료).
    private(set) var translating: Bool = false

    /// 현재 살아있는 Gemini 클라이언트(actor). 정지 시 해제.
    @ObservationIgnored private var gemini: GeminiLiveClient?
    /// 수신 이벤트 소비 Task.
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    /// 앱 정상 종료(Cmd-Q) 옵저버. 종료 시 덕킹된 시스템 볼륨을 복원하고 재생을 정지한다.
    /// 한계: SIGKILL/강제 크래시 시에는 이 콜백이 호출되지 않아 덕킹이 복원되지 않을 수 있다.
    @ObservationIgnored private var willTerminateObserver: NSObjectProtocol?

    /// 설정 창 컨트롤러 (M1.5). lazy: 실제 열 때 생성.
    /// `@Observable`과 `lazy`가 충돌하므로 관찰 대상에서 제외한다(UI가 추적할 필요 없음).
    @ObservationIgnored private(set) lazy var settingsWindow = SettingsWindowController(appState: self)

    /// 키 로딩 추상화. 기본은 사용자 입력 키(Keychain) 전용 provider.
    private let apiKeyProvider: APIKeyProvider

    /// 키 저장/삭제/출처 판별을 위한 통합 provider. `apiKeyProvider`가
    /// `ResolvedAPIKeyProvider`이면 동일 인스턴스이고, 외부에서 다른 provider를
    /// 주입한 경우엔 Keychain 작업을 위해 별도로 보관한다.
    @ObservationIgnored private let resolvedProvider: ResolvedAPIKeyProvider?

    /// 연결 테스트기(actor). 키 검증에 사용.
    @ObservationIgnored private let connectionTester = GeminiConnectionTester()

    /// 연결 테스트 진행/결과 상태(설정 UI용). 키는 절대 포함하지 않는다.
    enum ConnectionTestState: Sendable, Equatable {
        case idle
        case testing
        case success
        case failure(reason: String)
    }

    /// 현재 연결 테스트 상태(설정 UI가 관찰).
    private(set) var connectionTestState: ConnectionTestState = .idle

    init(apiKeyProvider: APIKeyProvider = ResolvedAPIKeyProvider()) {
        self.apiKeyProvider = apiKeyProvider
        self.resolvedProvider = apiKeyProvider as? ResolvedAPIKeyProvider
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
        self.keySource = resolvedProvider?.currentKeySource()
            ?? (self.apiKeyLoaded ? .keychain : .none)
        // 초기 상태 라벨: 키가 없으면 설정 안내를 노출(키 있으면 기존 "연결 안 됨" 유지).
        if !self.apiKeyLoaded {
            self.geminiStatus = "API 키 없음 — 설정에서 Gemini API 키를 입력하세요"
        }
        // 제어 HUD가 시작/정지·설정 버튼을 호출할 수 있도록 배선(self 완성 후).
        self.hud.bind(appState: self)
        // 정상 종료(Cmd-Q)에서도 덕킹이 남지 않도록 시스템 볼륨 복원 + 재생 정지를 보장한다.
        // (SIGKILL/강제 크래시는 이 콜백이 호출되지 않아 복구 불가 — 위 옵저버 주석 참조.)
        self.willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 알림은 메인 큐에서 오므로 MainActor 작업으로 안전하게 호핑.
            Task { @MainActor in
                guard let self else { return }
                self.systemAudioDucker.restore()
                self.translatedAudioPlayer.stop()
            }
        }
    }
    // 옵저버 해제용 deinit은 두지 않는다: AppState는 앱 수명 동안 살아있는 단일 인스턴스이며,
    // willTerminate 알림은 종료 시 1회만 발화한다(Swift 6에서 nonisolated deinit이 비-Sendable
    // 옵저버에 접근할 수 없는 제약도 회피). 핸들은 향후 제거가 필요할 때를 위해 보관만 한다.

    // MARK: - API 키 관리 (설정 UI에서 호출)

    /// 사용자가 입력한 키를 Keychain에 저장하고 상태(로드 여부/출처)를 갱신한다.
    /// 저장 후에는 다음 "번역 시작"부터 새 키가 우선 사용된다.
    /// - Returns: 성공 여부. 실패 시 사유는 throw로 전달(키 비포함).
    @discardableResult
    func saveAPIKey(_ key: String) -> Result<Void, Error> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(KeychainAPIKeyProvider.KeychainError.encodingFailed)
        }
        guard let provider = resolvedProvider else {
            return .failure(KeychainAPIKeyProvider.KeychainError.unexpectedStatus(errSecParam))
        }
        do {
            try provider.save(trimmed)
            refreshKeyState()
            // 저장하면 직전 테스트 결과는 무의미 — 초기화.
            connectionTestState = .idle
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Keychain에 저장된 키를 삭제한다(이후 키 없음 — 사용자가 다시 입력해야 함). 상태를 갱신한다.
    @discardableResult
    func clearAPIKey() -> Result<Void, Error> {
        guard let provider = resolvedProvider else {
            return .failure(KeychainAPIKeyProvider.KeychainError.unexpectedStatus(errSecParam))
        }
        do {
            try provider.clear()
            refreshKeyState()
            connectionTestState = .idle
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// 후보 키(설정 입력 버퍼)를 우선 테스트한다. candidateKey가 비어 있으면 저장된 키로 폴백.
    /// 진행 중에는 `connectionTestState == .testing`. 결과를 상태로 반영한다.
    /// 키가 없으면 즉시 실패 상태로 둔다. 키는 어디에도 노출하지 않는다.
    func testConnection(candidateKey: String? = nil) {
        let trimmed = candidateKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String? = (trimmed?.isEmpty == false) ? trimmed : geminiAPIKey()
        guard let key, !key.isEmpty else {
            connectionTestState = .failure(reason: "테스트할 키가 없습니다")
            return
        }
        connectionTestState = .testing
        let tester = connectionTester
        Task { [weak self] in
            let result = await tester.test(apiKey: key)
            guard let self else { return }
            switch result {
            case .success:
                self.connectionTestState = .success
            case .failure(let reason):
                self.connectionTestState = .failure(reason: reason)
            }
        }
    }

    /// 입력이 바뀌면 직전 연결 테스트 결과가 무의미하므로 idle로 되돌린다(설정 UI에서 호출).
    func resetConnectionTestState() {
        connectionTestState = .idle
    }

    /// 로드 여부/출처를 다시 계산해 @Observable 프로퍼티를 갱신한다.
    private func refreshKeyState() {
        apiKeyLoaded = apiKeyProvider.geminiAPIKey() != nil
        keySource = resolvedProvider?.currentKeySource()
            ?? (apiKeyLoaded ? .keychain : .none)
        // 저장/삭제 직후 stale 상태 라벨 제거: 실행 중이 아니면 키 보유 여부로 라벨을 재설정.
        if !isRunning {
            geminiStatus = apiKeyLoaded
                ? "연결 안 됨"
                : "API 키 없음 — 설정에서 Gemini API 키를 입력하세요"
        }
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
        // 사용자 피드백: 키 유무와 무관하게 "시작"을 누르면 제어 HUD는 떠야 한다.
        // 마스터 토글이 꺼져 있어도 강제로 켜고 표시한다.
        settings.monitorEnabled = true
        hud.applyEnabledPolicy()   // 토글 변경을 반영(설정 UI와 동기)
        hud.show()

        // 키가 없으면 캡처/연결은 시작하지 않고 HUD에 에러만 노출(isRunning은 false 유지).
        guard let key = geminiAPIKey(), !key.isEmpty else {
            geminiStatus = "API 키 없음 — 설정에서 Gemini API 키를 입력하세요"
            return
        }
        // 의도를 먼저 확정(이후 콜백/hot-swap 경로가 이 값을 신뢰한다).
        isRunning = true
        startGemini(apiKey: key)
        audio.requestPermissionAndStart()
        // 권한 콜백 후 isCapturing이 true가 된다. UI는 isRunning(버튼 상태)과
        // audio.isCapturing(실제 캡처 표시)을 각각 관찰한다.
        subtitleOverlay.applyCapturePolicy(isCapturing: true)
        // 번역 오디오 출력/덕킹 정책 적용(설정+실행상태 기준).
        applyAudioOutputPolicy()
    }

    /// 번역 세션을 확실히 정지한다. audio + Gemini + 자막 오버레이 모두 내려간다.
    /// 어떤 경로(정상 정지/오류 정리)로 들어와도 동일하게 동작한다(멱등).
    private func stopSession() {
        isRunning = false
        audio.stop()
        stopGemini()
        subtitleOverlay.applyCapturePolicy(isCapturing: false)
        // 번역 오디오 재생 정지 + 시스템 볼륨 복원.
        translatedAudioPlayer.stop()
        systemAudioDucker.restore()
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
        // 번역 출력 오디오 재생 플래그를 전달(off면 client가 오디오 디코드도 생략 — 비용 0).
        Task { await client.setPlaybackEnabled(settings.translatedAudioPlaybackEnabled) }

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
        case .outputAudio(let data):
            translatedAudioPlayer.enqueue(int16LE: data)  // 번역 출력 오디오 재생(M3+).
        case .info(let message):
            geminiStatus = message
        case .permanentFailure(let reason):
            // 영구 실패 → 세션을 확실히 정리(오디오 재생 정지 + 시스템 볼륨 복원 + isRunning=false).
            stopSession()
            geminiStatus = reason   // stopSession이 "연결 안 됨"으로 덮으므로 사유를 다시 노출
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

    // MARK: - 번역 오디오 출력/덕킹 (M3+)

    /// 현재 설정 + 실행 상태를 플레이어/덕커/클라이언트에 반영한다.
    /// UI가 설정(재생 토글/볼륨/덕킹)을 바꿀 때도 호출해 실시간 반영한다.
    ///
    /// 주의(설계상 부분 덕킹): 번역 오디오도 시스템 기본 출력 장치로 나가므로,
    /// 덕킹을 켜면 원문과 함께 번역 소리도 같이 작아진다(별도 출력 라우팅은 미지원).
    func applyAudioOutputPolicy() {
        let live = gemini   // 살아있는 client(actor) 참조

        if settings.translatedAudioPlaybackEnabled, isRunning {
            translatedAudioPlayer.volume = Float(settings.translatedAudioVolume)
            translatedAudioPlayer.start()
            if let live { Task { await live.setPlaybackEnabled(true) } }
            // 덕킹: on이면 원문(과 번역) 출력을 함께 낮춘다, off면 복원.
            if settings.originalAudioDuckingEnabled {
                systemAudioDucker.duck(to: Float(settings.originalAudioDuckVolume))
            } else {
                systemAudioDucker.restore()
            }
        } else {
            // 재생 off거나 정지 상태: 재생 중지 + 볼륨 복원 + client 디코드 중단.
            translatedAudioPlayer.stop()
            systemAudioDucker.restore()
            if let live { Task { await live.setPlaybackEnabled(false) } }
        }
    }

    // MARK: - 미리보기/리셋 (설정 UI)

    /// 자막 오버레이를 강제로 표시하고 샘플 자막을 주입해 실제 화면 렌더를 미리본다.
    func showTestSubtitle() {
        // 캡처/번역 중에는 실제 자막을 덮어쓰지 않도록 미리보기를 막는다(실자막 보존).
        guard !isRunning else { return }
        subtitleOverlay.show()
        subtitles.reset()
        subtitles.ingestTranslationDelta("안녕하세요 — 자막 미리보기입니다")
        if settings.showSourceText {
            subtitles.ingestSourceDelta("Hello — this is a subtitle preview")
        }
        subtitles.ingestTurnComplete()  // 2초 유지 후 자동 페이드
    }

    /// 모든 사용자 설정을 기본값으로 되돌리고 시각/오디오 정책을 재적용한다.
    /// `includingAPIKey`가 true면 Keychain의 키도 삭제한다(SettingsStore.resetAll은 키를 건드리지 않음).
    /// 한계: 입력 소스 선택 초기화는 영속값만 되돌리며, 실제 입력 hot-swap은 다음 번역 시작 시 반영된다.
    func resetSettings(includingAPIKey: Bool) {
        settings.resetAll()
        hud.applyEnabledPolicy()
        subtitleOverlay.applyPositionChange()
        applyAudioOutputPolicy()
        if includingAPIKey {
            clearAPIKey()
        }
        refreshKeyState()
    }

    /// 필요 시점에 키를 조회한다 (메모리 상주 최소화를 위해 캐싱하지 않음).
    func geminiAPIKey() -> String? {
        apiKeyProvider.geminiAPIKey()
    }
}
