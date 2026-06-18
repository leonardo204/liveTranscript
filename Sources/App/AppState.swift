import AppKit
import Foundation
import Observation
import os
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

    /// Sparkle 자동 업데이트 관리자. 앱 수명 동안 1개만 보유한다(launch 시 업데이터 가동).
    /// 설정 창 "일반 > 업데이트" 섹션에서 현재 버전 표시/자동확인 토글/즉시 확인을 제공한다.
    let updates = UpdateChecker()

    // MARK: - Gemini 연동 (M2a)

    /// Gemini 연결/번역 상태 라벨(메뉴/HUD 표시용). 키는 절대 포함하지 않는다.
    private(set) var geminiStatus: String = "연결 안 됨"

    /// 번역 세션이 연결 가능 상태인지(키 존재 + 연결 시도 중/완료).
    private(set) var translating: Bool = false

    /// 현재 살아있는 Gemini 클라이언트(actor). 정지 시 해제.
    @ObservationIgnored private var gemini: GeminiLiveClient?
    /// 수신 이벤트 소비 Task.
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    // MARK: - 동시성-안전 상태머신 (reconciler)
    //
    // 빠른 시작/정지 연타에도 오디오/Gemini가 좀비/중복 생성되지 않도록,
    // "사용자 의도(desired)"와 "실제 파이프라인(actual)"을 분리하고
    // **항상 1개의 직렬 reconciler Task**만 실제 전환(start/stop/reload)을
    // await로 한 번에 하나씩 처리한다(불변식).
    //
    // 동시성 안전성:
    // - reconcileTask는 동시에 1개만 존재(kickReconcile 가드).
    // - 사용자의 빠른 연타는 desiredRunning만 뒤집고 isRunning(UI)에 즉시 반영하며,
    //   실제 전환은 reconciler가 직렬로 수렴시킨다(겹침 없음).
    // - reconcileLoop의 while 조건 평가와 reconcileTask=nil 대입 사이에는 await가
    //   없으므로(둘 다 동기, MainActor), 그 틈에 toggleCapture(동기)가 끼어들어
    //   전환을 누락/중복시키는 일이 없다.

    /// 사용자 의도(최신). isRunning은 이를 즉시 미러한다.
    @ObservationIgnored private var desiredRunning = false
    /// 실제 파이프라인 on 여부(audio+Gemini 실제 가동 상태).
    @ObservationIgnored private var actualRunning = false
    /// 키/언어 변경 등으로 Gemini 재연결이 필요함을 표시.
    @ObservationIgnored private var needsGeminiReload = false
    /// 단 하나만 살아있는 직렬 reconciler Task.
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    /// 영구 실패 사유(best-effort). performStop이 라벨을 "연결 안 됨"으로 덮을 때,
    /// 정지 의도이면서 이 값이 있으면 사유를 유지해 사용자에게 노출한다.
    @ObservationIgnored private var lastFailureReason: String?

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

    /// 진단 로그용 Logger(세션 수명/오디오 정책 호출 추적, A2). 민감정보(키) 미포함.
    @ObservationIgnored private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "AppState")

    /// outputAudio enqueue 로그 스로틀 카운터(A2). 첫 1회 + N회마다 1회만 로그.
    @ObservationIgnored private var outputAudioEnqueueCount = 0

    /// setPlaybackEnabled 적용을 직렬 체이닝하는 Task. 새 Task가 이전 Task 완료를
    /// await해 actor 진입 순서를 FIFO로 보장한다(on→off 연타 시 최종값 역전 방지).
    @ObservationIgnored private var playbackSyncTask: Task<Void, Never>?

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
            log.info("saveAPIKey 성공(키 미포함) → reloadTranslationSession 호출")
            refreshKeyState()
            // 저장하면 직전 테스트 결과는 무의미 — 초기화.
            connectionTestState = .idle
            // 번역 중이면 새 키로 즉시 안전 재연결(정지 중이면 무시 — 다음 시작에 자연 반영). 키 값은 노출하지 않는다.
            reloadTranslationSession()
            return .success(())
        } catch {
            log.error("saveAPIKey 실패(키 미포함): \(error.localizedDescription, privacy: .public)")
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
            log.info("clearAPIKey 성공 → reloadTranslationSession 호출")
            refreshKeyState()
            connectionTestState = .idle
            // 번역 중에 키를 지우면 재연결 시 키가 없어 performGeminiReload가 정지로 수렴한다(정지 중이면 무시).
            reloadTranslationSession()
            return .success(())
        } catch {
            log.error("clearAPIKey 실패: \(error.localizedDescription, privacy: .public)")
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
        // 시작/정지의 단일 진실은 `desiredRunning`(사용자 의도)이다.
        // 빠른 연타에도 의도만 즉시 뒤집고 isRunning(버튼 상태)에 미러한다.
        // 실제 파이프라인 전환은 reconciler가 직렬로 수렴시킨다(겹침/좀비 없음).
        desiredRunning.toggle()
        log.info("의도 토글: desired=\(self.desiredRunning, privacy: .public)")
        isRunning = desiredRunning   // 버튼 상태 즉시 반영(연타에도 UI는 항상 최신 의도)
        kickReconcile()
    }

    /// 번역 설정(키/언어 등) 변경 시 호출 — 실행 중이면 Gemini만 안전 재연결,
    /// 정지 중이면 무시(다음 시작에 자연 반영). (Run 3에서 키/언어 변경 경로가 배선 예정.)
    func reloadTranslationSession() {
        guard desiredRunning else {
            log.info("reloadTranslationSession: 무시(desiredRunning=false — 다음 시작에 자연 반영)")
            return
        }
        log.info("reloadTranslationSession: 재연결 요청(desiredRunning=true) → needsGeminiReload=true")
        needsGeminiReload = true
        kickReconcile()
    }

    // MARK: - reconciler (단일 직렬 수렴 루프)

    /// reconciler가 이미 수렴 중이면 플래그만 갱신하고 그 태스크가 처리하도록 둔다.
    /// 동시 1개 보장(동시성 불변식의 핵심 가드).
    private func kickReconcile() {
        guard reconcileTask == nil else { return }   // 이미 수렴 중 → 그 태스크가 desired/플래그를 마저 처리
        reconcileTask = Task { [weak self] in await self?.reconcileLoop() }
    }

    /// desired/플래그가 더 이상 전환을 요구하지 않을 때까지 한 번에 하나씩 await로 수렴시킨다.
    /// race-free 근거: 아래 while 조건 평가 → (false면) reconcileTask=nil 대입까지
    /// **await가 없으므로**, 그 사이 동기 toggleCapture가 끼어들 수 없다.
    /// toggle은 항상 while 평가 전(이미 수렴 중이면 가드로 무시) 또는 nil 대입 후에만 실행된다.
    private func reconcileLoop() async {
        while needsTransition() {
            // 진단: 매 반복의 desired/actual/needsGeminiReload + 선택 분기(상태머신 추적).
            if desiredRunning && !actualRunning {
                log.info("reconcile: desired=\(self.desiredRunning, privacy: .public) actual=\(self.actualRunning, privacy: .public) reload=\(self.needsGeminiReload, privacy: .public) → performStart")
                await performStart()
            } else if !desiredRunning && actualRunning {
                log.info("reconcile: desired=\(self.desiredRunning, privacy: .public) actual=\(self.actualRunning, privacy: .public) reload=\(self.needsGeminiReload, privacy: .public) → performStop")
                await performStop()
            } else if desiredRunning && actualRunning && needsGeminiReload {
                log.info("reconcile: desired=\(self.desiredRunning, privacy: .public) actual=\(self.actualRunning, privacy: .public) reload=\(self.needsGeminiReload, privacy: .public) → performGeminiReload")
                needsGeminiReload = false
                await performGeminiReload()
            } else {
                break
            }
        }
        reconcileTask = nil   // ← while(false) 직후 동기 대입(중간 await 없음 → toggle 끼어듦 차단)
    }

    /// 추가 전환이 필요한지 판정.
    private func needsTransition() -> Bool {
        if desiredRunning != actualRunning { return true }
        if desiredRunning && needsGeminiReload { return true }
        return false
    }

    /// 번역 세션을 깨끗하게 시작한다(직렬 reconciler가 호출). 항상 새 audio + 새 Gemini + 자막 정책 on.
    private func performStart() async {
        log.info("performStart 진입")
        // 사용자 피드백: 키 유무와 무관하게 "시작"을 누르면 제어 HUD는 떠야 한다.
        // 마스터 토글이 꺼져 있어도 강제로 켜고 표시한다.
        settings.monitorEnabled = true
        hud.applyEnabledPolicy()   // 토글 변경을 반영(설정 UI와 동기)
        hud.show()

        // 키가 없으면 캡처/연결을 시작하지 않고, 의도를 정지로 되돌려 버튼이 "시작"으로 유지되게 한다.
        guard let key = geminiAPIKey(), !key.isEmpty else {
            log.error("performStart 중단: 키 없음 → 의도 정지로 복귀")
            geminiStatus = "API 키 없음 — 설정에서 Gemini API 키를 입력하세요"
            desiredRunning = false
            isRunning = false
            actualRunning = false
            needsGeminiReload = false
            return
        }
        log.info("performStart: 키 있음 → 캡처+Gemini 시작")
        lastFailureReason = nil   // 새 세션 시작 → 직전 영구 실패 사유 클리어(정지 라벨 오염 방지)
        startGemini(apiKey: key)
        audio.requestPermissionAndStart()
        // 권한 콜백 후 isCapturing이 true가 된다. UI는 isRunning(버튼 상태)과
        // audio.isCapturing(실제 캡처 표시)을 각각 관찰한다.
        subtitleOverlay.applyCapturePolicy(isCapturing: true)
        // 번역 오디오 출력/덕킹 정책 적용(설정+실행상태 기준 — actualRunning 확정 전이지만
        // applyAudioOutputPolicy는 isRunning을 보고, isRunning은 desiredRunning을 미러한다).
        applyAudioOutputPolicy()
        needsGeminiReload = false
        actualRunning = true
        log.info("performStart 완료: actualRunning=true")
    }

    /// 번역 세션을 확실히 정지한다(직렬 reconciler가 호출). audio + Gemini + 자막 오버레이 모두 내려간다.
    /// **이전 Gemini client.stop()이 끝날 때까지 await**한 뒤에만 actualRunning=false로 만들어,
    /// 다음 시작이 이전 세션과 겹치지 않게 보장한다.
    private func performStop() async {
        log.info("performStop 진입")
        audio.stop()
        await stopGemini()   // ← fire-and-forget 금지: client.stop() 완료까지 대기(좀비/중복 방지)
        subtitleOverlay.applyCapturePolicy(isCapturing: false)
        // 번역 오디오 재생 정지 + 시스템 볼륨 복원.
        translatedAudioPlayer.stop()
        systemAudioDucker.restore()
        // 정지 라벨은 영구 실패 사유가 있으면 그것을 우선 노출(best-effort).
        if let reason = lastFailureReason {
            geminiStatus = reason
        }
        actualRunning = false
        needsGeminiReload = false
        log.info("performStop 완료: actualRunning=false")
    }

    /// 캡처(audio)는 유지한 채 Gemini만 안전 재연결한다(직렬 reconciler가 호출).
    /// 이전 client.stop()을 끝까지 await한 뒤 새 키로 재시작. 키가 없으면 정지로 수렴.
    private func performGeminiReload() async {
        log.info("performGeminiReload 진입")
        await stopGemini()   // 이전 세션 완전 정지까지 대기
        guard let key = geminiAPIKey(), !key.isEmpty else {
            log.error("performGeminiReload 중단: 키 없음 → 정지로 수렴")
            geminiStatus = "API 키 없음 — 설정에서 Gemini API 키를 입력하세요"
            desiredRunning = false
            isRunning = false
            // 캡처도 내려야 하므로 다음 루프에서 performStop이 돌도록 actualRunning은 유지.
            // 다만 덕킹/재생은 즉시 정리한다(다음 performStop까지 1틱 덕킹이 유지되는 것 방지).
            // performStop이 멱등으로 다시 호출해도 무해하다.
            translatedAudioPlayer.stop()
            systemAudioDucker.restore()
            return
        }
        log.info("performGeminiReload: 키 있음 → Gemini 재시작")
        startGemini(apiKey: key)
        // 자막/오디오 정책은 그대로 유지(캡처는 끊기지 않았다).
        applyAudioOutputPolicy()
        log.info("performGeminiReload 완료")
    }

    // MARK: - Gemini 수명주기 (M2a)

    /// Gemini 연결을 시작하고 오디오 파이프라인(onChunk → sendAudio)을 배선한다.
    /// "번역 시작" 시 호출. 키는 호출자가 검증해 전달한다(로그/HUD에 키 노출 금지).
    private func startGemini(apiKey: String) {
        // 이전 세션 잔재 정리(동기 부분만): onChunk/eventTask 해제 + 핸들 비움.
        // 실제 client.stop()까지의 대기는 호출처(performStart/performGeminiReload)에서
        // 이미 await로 보장하므로 여기서는 동기 정리만 한다(멱등).
        clearGeminiHandles()
        subtitles.reset()
        cost.resetSession()   // 세션 비용은 번역 시작마다 0에서 시작(누적은 유지, 태스크 C).

        let client = GeminiLiveClient(
            apiKey: apiKey,
            targetLanguageCode: settings.targetLanguageCode,
            // 항상 false로 고정: 서버 자동 VAD를 사용한다(realtimeInputConfig 생략 + activity 신호 미전송).
            // 검증 결과 translate-preview 모델은 manual activity 경계를 turn 종료로 인정하지 않아
            // turnComplete를 보내지 않았고, idle 타이머와 강제 분절이 sparse VAD 프레임과 충돌해
            // activityStart/End가 폭주(storm)했다. 따라서 activity 기반 경계 제어를 비활성화하고
            // 서버 VAD에 일임한다. 클라이언트 Silero(audio.vadEnabled)는 "어떤 오디오를 보낼지"만
            // 게이트(비용/소음 절감)하며 서버 VAD와 독립적으로 동작한다.
            clientVADEnabled: false,
            // 원문 동시 표시가 켜진 경우에만 입력 전사를 요청한다(off면 공식 translate 예제와 동일하게
            // inputAudioTranscription 키를 생략 → 원문 자막 없음, 의도된 동작).
            requestInputTranscription: settings.showSourceText
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

    /// Gemini 파이프라인의 **동기 핸들만** 해제한다(onChunk/eventTask/gemini/상태 라벨).
    /// 살아있던 client는 지역 변수로 빼 반환하므로, 호출자가 await로 정지를 마칠 수 있다.
    private func clearGeminiHandles() -> GeminiLiveClient? {
        audio.onChunk = nil
        eventTask?.cancel()
        eventTask = nil
        // 현재 client를 지역 변수로 분리한 뒤 즉시 self.gemini를 비운다.
        // client.stop()은 actor 내부에서 stopped=true + generation++ + teardownSocket()을
        // 수행하므로, 이 stop이 끝나면 해당 client는 어떤 경로로도 재연결하지 않는다.
        // (각 client는 독립적이라 새 세션 생성과 이전 세션 정지가 서로를 오염시키지 않는다.)
        let client = gemini
        gemini = nil
        translating = false
        geminiStatus = "연결 안 됨"
        return client
    }

    /// Gemini 연결을 종료하고 파이프라인을 해제한다("번역 정지").
    /// fire-and-forget이 아니라 **client.stop()이 끝날 때까지 await**한다(빠른 토글 시
    /// 이전 정지가 끝나기 전에 새 세션이 시작돼 겹치는 것을 막는다). 멱등.
    private func stopGemini() async {
        if let client = clearGeminiHandles() {
            await client.stop()
        }
    }

    /// Gemini 이벤트를 상태/자막으로 반영한다(MainActor).
    private func handle(_ event: GeminiLiveClient.Event) {
        switch event {
        case .state(let state):
            switch state {
            case .disconnected: geminiStatus = "연결 안 됨"; log.info("event.state=disconnected")
            case .connecting: geminiStatus = "연결 중…"; log.info("event.state=connecting")
            case .ready: geminiStatus = "번역 중"; log.info("event.state=ready")
            case .error(let message):
                geminiStatus = message  // 키 미포함(클라이언트가 보장)
                log.error("event.state=error: \(message, privacy: .public)")
            }
        case .translation(let delta):
            subtitles.ingestTranslationDelta(delta)
        case .source(let delta):
            subtitles.ingestSourceDelta(delta)
        case .turnComplete:
            subtitles.ingestTurnComplete()
        case .generationComplete:
            // generation(재번역 단위) 경계: 자막은 다음 delta에서 직전 generation을 리셋하도록 표시한다.
            // 오디오는 직전 generation의 아직 재생 안 된 큐를 비워(flush), 다음 generation이 같은
            // 구간을 다시 말할 때 중첩 반복되는 것을 완화한다(flush는 큐만 비우고 재생은 지속).
            log.info("event.generationComplete → 자막 generation 경계 + 오디오 flush")
            subtitles.ingestGenerationComplete()
            translatedAudioPlayer.flush()
        case .sentAudio(let sampleCount):
            cost.addSentAudio(sampleCount: sampleCount)   // 입력 비용 누적(태스크 C).
        case .outputTokens(let tokens):
            log.debug("event.outputTokens=\(tokens, privacy: .public) (비용 누적)")
            cost.addOutputTokens(tokens)                  // 출력 비용 누적(태스크 C).
        case .outputAudio(let data):
            // A2: enqueue 도달 여부 추적(첫 1회 + N회마다). 바이트수만 로그(데이터 내용 미포함).
            outputAudioEnqueueCount += 1
            if outputAudioEnqueueCount == 1 || outputAudioEnqueueCount % 50 == 0 {
                log.debug("outputAudio enqueue (\(data.count) bytes)")
            }
            translatedAudioPlayer.enqueue(int16LE: data)  // 번역 출력 오디오 재생(M3+).
        case .info(let message):
            log.info("event.info: \(message, privacy: .public)")
            geminiStatus = message
        case .interrupted:
            // 서버가 진행 중 응답을 인터럽트 → 진행 중 자막/번역 오디오를 즉시 정리한다.
            // 끊긴 응답의 잔재(자막 누적/스케줄된 오디오)가 다음 발화에 섞이지 않도록 한다.
            log.info("event.interrupted → 진행 중 자막/오디오 정리")
            subtitles.reset()
            translatedAudioPlayer.flush()
        case .permanentFailure(let reason):
            // 영구 실패 → 의도를 정지로 돌리고 reconciler에 정리를 맡긴다(직렬 안전).
            // reconciler가 performStop으로 player/ducker/audio/gemini를 한 번에 정리한다.
            log.error("permanentFailure → 세션 정지: \(reason, privacy: .public)")
            desiredRunning = false
            isRunning = false
            needsGeminiReload = false
            lastFailureReason = reason   // performStop이 정지 라벨을 덮을 때 이 사유를 우선 노출
            geminiStatus = reason
            kickReconcile()
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
        // A2: 호출 진입 + 분기 추적(오디오 정책 thrash 원인 확정용).
        log.info("applyAudioOutputPolicy: playback=\(self.settings.translatedAudioPlaybackEnabled) isRunning=\(self.isRunning)")
        let live = gemini   // 살아있는 client(actor) 참조

        if settings.translatedAudioPlaybackEnabled, isRunning {
            log.info("applyAudioOutputPolicy: 분기=start (재생 시작 + 덕킹 적용)")
            translatedAudioPlayer.volume = Float(settings.translatedAudioVolume)
            // 설정된 출력 장치로 라우팅(시작 직전 반영 — nil이면 시스템 기본).
            translatedAudioPlayer.setOutputDevice(uid: settings.translatedAudioOutputDeviceUID)
            translatedAudioPlayer.start()
            if let live { syncPlaybackEnabled(true, to: live) }
            // 덕킹: on이면 원문(과 번역) 출력을 함께 낮춘다, off면 복원.
            if settings.originalAudioDuckingEnabled {
                systemAudioDucker.duck(to: Float(settings.originalAudioDuckVolume))
            } else {
                systemAudioDucker.restore()
            }
        } else {
            log.info("applyAudioOutputPolicy: 분기=stop (재생 중지 + 볼륨 복원)")
            // 재생 off거나 정지 상태: 재생 중지 + 볼륨 복원 + client 디코드 중단.
            translatedAudioPlayer.stop()
            systemAudioDucker.restore()
            if let live { syncPlaybackEnabled(false, to: live) }
        }
    }

    /// setPlaybackEnabled 호출을 직렬 체이닝한다. 새 Task가 직전 Task의 완료를
    /// await한 뒤 actor에 진입하므로 호출 순서(FIFO)가 보장된다 → 마지막 호출이 최종값.
    /// (fire-and-forget Task 난사 시 actor 진입 순서 미보장으로 최종값이 뒤집히던 문제 수정.)
    private func syncPlaybackEnabled(_ on: Bool, to live: GeminiLiveClient) {
        let prev = playbackSyncTask
        playbackSyncTask = Task { await prev?.value; await live.setPlaybackEnabled(on) }
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
