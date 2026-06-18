import Foundation
import os

/// Gemini 3.5 Live Translate WebSocket 클라이언트 (스펙 §5.1, M2a).
///
/// 책임:
/// - `URLSessionWebSocketTask`로 Live API에 연결하고 첫 메시지로 `setup`을 보낸다.
/// - 서버의 `setupComplete`를 기다린 뒤 `ready` 상태가 되어 오디오 송신을 허용한다.
/// - VAD 통과 발화 청크([Float], 16k mono)를 Int16 LE PCM → base64 → `realtimeInput`으로 송신.
/// - 수신 메시지(`serverContent`)에서 `outputTranscription`(번역 자막)/`inputTranscription`(원문)을
///   추출해 `AsyncStream<GeminiEvent>`로 외부에 방출한다.
/// - 연결 끊김 시 단순 백오프 재연결.
/// - M2c 구현: goAway/sessionResumption 기반 무중단 재연결 + 15분 선제 핸드오버.
///
/// 동시성: `actor`로 격리한다. 송신/수신 상태는 actor 내부에서만 변경된다.
/// 오디오 스레드(`AudioInputManager.onChunk`)는 `nonisolated`한 `sendAudio(_:)`로 진입해
/// 내부에서 actor로 hop한다. 외부 UI는 이벤트 스트림을 MainActor에서 소비한다.
///
/// 보안: WebSocket URL 쿼리에 API 키가 들어가므로 **URL/에러를 로그에 그대로 찍지 않는다.**
/// 로깅은 항상 `maskingKey`로 마스킹된 표현만 사용한다(아래 `maskedURLString` 참조).
actor GeminiLiveClient {

    /// 연결 수명 상태(외부 노출). UI는 이벤트 스트림의 `.state`로 추적한다.
    enum State: Sendable, Equatable {
        case disconnected
        case connecting
        /// setup 완료 — 오디오 송신 가능.
        case ready
        case error(String)
    }

    /// 외부로 방출되는 이벤트.
    ///
    /// 자막 누적 모델(M3): Live API는 outputTranscription/inputTranscription을
    /// **증분(delta) 조각**으로 스트리밍한다. 클라이언트는 이를 **그대로 delta로 방출**하고
    /// (절대 누적/치환하지 않는다), 턴(발화) 종료는 `serverContent.turnComplete`로
    /// 별도 `.turnComplete` 이벤트를 통해 명시적으로 알린다. 따라서 소비자(SubtitleEngine)는
    /// "delta append(이어붙임)"와 "턴 확정"을 명확히 구분할 수 있다.
    enum Event: Sendable {
        /// 연결 상태 변화.
        case state(State)
        /// 번역 자막 **delta 조각**. 소비자가 현재 버퍼에 append해야 완전한 문장이 된다.
        case translation(delta: String)
        /// 원문 전사 **delta 조각**. 원문 동시 표시 토글용(FR-8).
        case source(delta: String)
        /// 턴(발화) 종료 신호(`serverContent.turnComplete: true`).
        /// 소비자는 현재 누적 버퍼를 확정 줄로 고정하고 표시 시간 후 페이드아웃한다.
        case turnComplete
        /// 송신한 오디오 청크의 샘플 수(비용 입력 추정용, 태스크 C). 16kHz mono 기준.
        case sentAudio(sampleCount: Int)
        /// usageMetadata가 보고한 출력 오디오 토큰 수(비용 출력 추정용, 태스크 C).
        case outputTokens(Int)
        /// 번역 출력 오디오 청크(24kHz mono Int16 LE PCM). 재생 플래그가 켜진 경우에만 방출된다.
        case outputAudio(Data)
        /// 정보성 알림(연결됨/재연결 등) — HUD/로그용. 키는 절대 포함하지 않는다.
        case info(String)
        /// 영구 실패(재연결 포기) — 세션 수명 종료 신호. 소비자는 이를 받으면 오디오 재생 정지/
        /// 시스템 볼륨 복원 등 세션 정리를 수행해야 한다. `.state(.error)`는 일시 끊김에도
        /// 쓰이므로 영구 실패는 이 별도 이벤트로 명확히 구분한다. 키는 절대 포함하지 않는다.
        case permanentFailure(reason: String)
    }

    // MARK: - 설정

    private let apiKey: String
    private let model: String
    private let targetLanguageCode: String

    /// 재연결 백오프(초). 끊길 때마다 증가, setupComplete 수신 시 리셋.
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0

    /// setupComplete를 한 번이라도 받기 전까지의 연속 연결 실패 횟수.
    /// 이 값이 maxConnectAttempts를 넘으면 영구 실패로 간주하고 재연결을 멈춘다.
    private var connectAttempts = 0
    private let maxConnectAttempts = 5

    /// translationConfig 위치. 직접 WebSocket 테스트로 확인됨:
    /// top-level은 서버가 1007("Unknown name translationConfig at 'setup'")로 거부하고,
    /// generationConfig 내부에 두어야 setupComplete를 받는다. 따라서 nested가 기본.
    private var useNestedTranslationConfig = true

    // MARK: - 런타임 상태

    private(set) var state: State = .disconnected {
        didSet {
            guard state != oldValue else { return }
            emit(.state(state))
        }
    }

    /// 사용자가 stop()을 호출했는지 — true면 재연결하지 않는다.
    private var stopped = true

    /// 번역 출력 오디오 재생 여부. false면 modelTurn 오디오를 디코드/방출하지 않고 폐기(비용 0).
    private var playbackEnabled = false

    /// 번역 출력 오디오 재생 플래그를 갱신한다(AppState가 설정 변경/시작 시 호출).
    func setPlaybackEnabled(_ on: Bool) { playbackEnabled = on }

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?

    /// 현재 task가 setup을 이미 보냈는지(didOpen 콜백에서 1회만 전송 보장).
    private var setupSent = false

    /// 현재 연결 세대(generation). 재연결마다 증가시켜, 이전 task의 지연된
    /// delegate 콜백이 새 연결 상태를 오염시키지 않도록 식별한다.
    private var generation = 0

    /// WebSocket delegate(핸드셰이크/종료/에러 콜백 수신). 세션과 수명을 같이한다.
    private var delegate: WebSocketDelegate?

    /// 이벤트 스트림 continuation. connect 시 생성된다.
    private var continuation: AsyncStream<Event>.Continuation?

    private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "GeminiLive")

    /// sessionResumptionUpdate 수신 카운터 — 로그 폭주 방지(빈도 제한, M3 부수 정리).
    /// 매 수신마다 찍지 않고 N회마다 한 번만 debug 로그를 남긴다.
    private var resumptionUpdateCount = 0

    /// 최신 세션 재개 핸들(M2c). sessionResumptionUpdate(resumable=true)에서 갱신하고,
    /// 재연결 시 setup의 sessionResumption.handle로 넘겨 컨텍스트를 이어받는다. 키 아님(노출 무방하나 로그 자제).
    private var resumptionHandle: String?

    /// 선제 재연결 타이머(M2c). 세션 한도(오디오 약 15분) 도달 전에 핸들 기반으로 미리 재연결한다.
    /// setupComplete마다 재무장한다.
    private var proactiveReconnectTask: Task<Void, Never>?
    /// 선제 재연결까지의 간격(초). 15분 한도보다 짧게 14분으로 잡아 여유를 둔다.
    private let proactiveReconnectInterval: TimeInterval = 14 * 60

    // MARK: - 초기화

    /// - Parameters:
    ///   - apiKey: Gemini API 키(.env/Keychain). **로그에 출력 금지.**
    ///   - model: 모델명(기본 §5.1).
    ///   - targetLanguageCode: 번역 대상 언어 BCP-47(기본 ko).
    init(apiKey: String,
         model: String = AppConfig.geminiModel,
         targetLanguageCode: String = AppConfig.defaultTargetLanguageCode) {
        self.apiKey = apiKey
        self.model = model
        self.targetLanguageCode = targetLanguageCode
    }

    // MARK: - 연결 수명

    /// 연결을 시작하고 이벤트 스트림을 반환한다. setup 송신 → setupComplete 대기 → ready.
    /// 이미 연결 중/연결됨이면 기존 스트림을 다시 만들지 않고 새 스트림을 반환한다.
    func connect() -> AsyncStream<Event> {
        stopped = false
        let stream = AsyncStream<Event> { continuation in
            self.continuation = continuation
        }
        openSocket()
        return stream
    }

    /// 연결을 종료한다(사용자 정지). 재연결하지 않는다.
    func stop() {
        stopped = true
        generation += 1   // 이전 task의 지연 콜백 무효화
        proactiveReconnectTask?.cancel()   // 선제 재연결 타이머 정지(M2c)
        proactiveReconnectTask = nil
        teardownSocket()
        state = .disconnected
        continuation?.finish()
        continuation = nil
    }

    // MARK: - 오디오 송신

    /// 발화 청크([Float], -1...1, 16k mono)를 Gemini로 송신한다.
    /// ready 상태에서만 송신하며, 그 외에는 조용히 폐기한다(연결 전/재연결 중 청크 유실 허용 — M2a).
    func sendAudio(_ chunk: [Float]) {
        guard state == .ready, let task else { return }
        // 비용 입력 추정(태스크 C): 실제 송신하는 청크의 샘플 수를 방출한다(정확한 누적 시간 근거).
        emit(.sentAudio(sampleCount: chunk.count))
        let pcm = Self.floatToInt16LEData(chunk)
        let base64 = pcm.base64EncodedString()
        let message = RealtimeInputMessage(
            realtimeInput: .init(audio: .init(data: base64, mimeType: "audio/pcm;rate=16000"))
        )
        guard let data = try? JSONEncoder().encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        task.send(.string(json)) { [weak self] error in
            if let error {
                Task { await self?.handleSendError(error) }
            }
        }
    }

    // MARK: - 소켓 개폐

    private func openSocket() {
        guard !stopped else { return }
        state = .connecting
        setupSent = false

        // 이전 세션 정리(재연결 시) 후 새 세대 시작.
        teardownSocket()
        generation += 1
        let gen = generation

        guard let url = makeURL() else {
            state = .error("잘못된 엔드포인트 URL")
            return
        }

        // delegate를 통해 핸드셰이크 완료(didOpen) / 종료(didClose) / 에러(didComplete)를 받는다.
        // delegate는 actor를 weak로 잡고, 콜백 안에서 generation을 함께 넘겨 actor로 hop한다.
        let delegate = WebSocketDelegate(client: self, generation: gen)
        self.delegate = delegate

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        // delegateQueue를 nil로 두면 직렬 OperationQueue가 자동 생성된다.
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task

        // 수신 루프 시작(handshake 전에 호출해도 receive는 메시지가 올 때까지 대기).
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            await self?.receiveMessages(generation: gen)
        }

        // resume() — 여기서는 setup을 보내지 않는다.
        // setup은 핸드셰이크(HTTP 101)가 끝난 뒤 delegate의 didOpen 콜백에서만 전송한다.
        task.resume()
        log.info("WebSocket 연결 시도(handshake 대기): \(self.maskedURLString, privacy: .public)")
    }

    private func teardownSocket() {
        // 선제 재연결 타이머를 취소(M2c) — 재연결/정지 모든 경로가 이곳을 통과하므로
        // 진행 중 이전 타이머가 스테일하게 발화하지 않는다(다음 setupComplete에서 재무장).
        proactiveReconnectTask?.cancel()
        proactiveReconnectTask = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
        setupSent = false
    }

    /// 핸드셰이크 완료(didOpen) 콜백 — actor로 hop되어 호출된다.
    /// 여기서 비로소 setup(첫 메시지)을 전송한다. 늦게 도착한 이전 세대 콜백은 무시.
    fileprivate func handleDidOpen(generation gen: Int) {
        guard gen == generation, !stopped else { return }
        log.info("WebSocket handshake 완료(didOpen) → setup 전송")
        sendSetup()
    }

    /// setup 메시지를 전송한다(핸드셰이크 완료 후 첫 메시지). 스펙 §5.1.
    private func sendSetup() {
        guard let task, !setupSent else { return }
        setupSent = true
        let setup = makeSetupMessage()
        guard let data = try? JSONEncoder().encode(setup),
              let json = String(data: data, encoding: .utf8) else {
            state = .error("setup 인코딩 실패")
            return
        }
        task.send(.string(json)) { [weak self] error in
            if let error {
                Task { await self?.handleSendError(error) }
            }
        }
    }

    // MARK: - 수신

    private func receiveMessages(generation gen: Int) async {
        guard let task else { return }
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                guard gen == generation else { return }   // 세대 불일치 → 이전 task의 잔여 수신 무시
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) { handleServerData(data) }
                case .data(let data):
                    handleServerData(data)
                @unknown default:
                    break
                }
            }
        } catch {
            // 취소가 아니면 연결 끊김.
            // 단, 핸드셰이크 실패(4xx 등)는 delegate(didComplete)에서 일괄 처리하므로
            // 여기서는 setup이 이미 전송된 정상 운영 중 끊김만 일반 재연결로 넘긴다.
            if !Task.isCancelled, gen == generation {
                await handleDisconnect(transient: setupSent)
            }
        }
    }

    private func handleServerData(_ data: Data) {
        let decoder = JSONDecoder()
        guard let msg = try? decoder.decode(ServerMessage.self, from: data) else {
            // 알 수 없는 메시지는 무시(스펙 프리뷰 — 미지 필드 허용).
            log.debug("미해석 서버 메시지 \(data.count) bytes")
            return
        }

        if msg.setupComplete != nil {
            // 연결 안정화 — 백오프/연속 실패 카운터를 리셋한다.
            reconnectDelay = 1.0
            connectAttempts = 0
            state = .ready
            emit(.info("Gemini 연결됨 (setup 완료)"))
            // 세션 한도(약 15분) 도달 전 선제 핸드오버를 예약(M2c). setupComplete마다 재무장.
            armProactiveReconnect()
            return
        }

        if let content = msg.serverContent {
            // 번역/원문 텍스트는 **delta 조각** 그대로 방출한다(누적/치환하지 않음).
            // 빈 조각은 무시 — 소비자 방어 부담을 줄인다.
            if let out = content.outputTranscription?.text, !out.isEmpty {
                emit(.translation(delta: out))
            }
            if let inp = content.inputTranscription?.text, !inp.isEmpty {
                emit(.source(delta: inp))
            }
            // modelTurn의 inlineData(출력 오디오 24kHz mono Int16 LE PCM).
            // 재생 플래그가 켜진 경우에만 디코드해 .outputAudio로 방출한다.
            // playbackEnabled=false면 자막 전용 앱이므로 디코드도 생략해 폐기(비용 0).
            if playbackEnabled, let parts = content.modelTurn?.parts {
                for part in parts {
                    guard let inline = part.inlineData,
                          let mime = inline.mimeType, mime.contains("audio/pcm"),
                          let b64 = inline.data, !b64.isEmpty,
                          let decoded = Data(base64Encoded: b64), !decoded.isEmpty else { continue }
                    emit(.outputAudio(decoded))
                }
            }
            // 턴 종료는 별도 .turnComplete 이벤트로 명시 전달 — 빈 문자열 emit 같은 혼란을 없앤다.
            if content.turnComplete == true {
                emit(.turnComplete)
            }
        }

        // usageMetadata: 출력 오디오 토큰을 추출해 비용 추정기로 방출(태스크 C).
        // responseTokensDetails(AUDIO) 우선, 없으면 responseTokenCount 폴백.
        if let usage = msg.usageMetadata, let outputTokens = usage.outputAudioTokens, outputTokens > 0 {
            emit(.outputTokens(outputTokens))
        }

        // goAway: 서버가 곧 연결을 종료한다는 예고 → 저장된 핸들로 선제 재연결(무중단 핸드오버).
        if let goAway = msg.goAway {
            log.info("goAway 수신 — 선제 핸드오버 (timeLeft=\(goAway.timeLeft ?? "?", privacy: .public))")
            emit(.info("세션 전환 중 (무중단 재연결)"))
            Task { await reconnectWithHandle() }
        }
        // sessionResumptionUpdate: 재개 가능 시점의 핸들을 보관(재연결 시 컨텍스트 유지에 사용).
        if let update = msg.sessionResumptionUpdate {
            if update.resumable == true, let handle = update.newHandle, !handle.isEmpty {
                resumptionHandle = handle
            }
            resumptionUpdateCount += 1
            if resumptionUpdateCount % 50 == 1 {
                log.debug("sessionResumptionUpdate 수신 (누적 \(self.resumptionUpdateCount)회, 핸들 보관됨)")
            }
        }
    }

    // MARK: - 에러/재연결

    private func handleSendError(_ error: Error) {
        guard !stopped else { return }
        // 키가 섞일 수 있는 원문 대신 도메인/코드만 로깅.
        let ns = error as NSError
        log.error("송신 오류 (\(ns.domain, privacy: .public) \(ns.code)) → 재연결 시도")
        // setup이 보내진 정상 운영 중 송신 실패만 일시적 끊김으로 본다.
        Task { await handleDisconnect(transient: setupSent) }
    }

    /// delegate(didCloseWith) 콜백 — 서버가 close frame으로 종료한 경우.
    /// 정책 위반(policyViolation) 등은 영구 실패로 보고 재연결하지 않는다.
    fileprivate func handleDidClose(generation gen: Int,
                                    closeCode: URLSessionWebSocketTask.CloseCode,
                                    reasonLength: Int) {
        guard gen == generation, !stopped else { return }
        log.error("WebSocket close 수신: code=\(closeCode.rawValue) reasonBytes=\(reasonLength)")

        switch closeCode {
        case .policyViolation, .unsupportedData, .invalidFramePayloadData:
            // 인증/권한/잘못된 요청류 — 재시도해도 동일 실패. 멈춘다.
            failPermanently("연결이 정책상 거부되었습니다 — API 키/모델 권한을 확인하세요 (close \(closeCode.rawValue))")
        default:
            Task { await handleDisconnect(transient: setupSent) }
        }
    }

    /// delegate(didCompleteWithError) 콜백 — task 완료(에러 포함).
    /// HTTP 응답이 있으면 상태코드로 핸드셰이크 실패 원인을 판별한다(키는 절대 노출 안 함).
    fileprivate func handleDidComplete(generation gen: Int,
                                       httpStatus: Int?,
                                       errorDomain: String?,
                                       errorCode: Int?) {
        guard gen == generation, !stopped else { return }

        if let status = httpStatus {
            log.error("WebSocket 종료: HTTP status=\(status)")
            // 핸드셰이크가 HTTP 4xx로 거부됨 → 키/모델/요청 문제. 재연결 무의미.
            if (400...499).contains(status) {
                let hint: String
                switch status {
                case 401, 403: hint = "API 키 또는 모델 접근 권한 문제"
                case 404:      hint = "모델/엔드포인트를 찾을 수 없음"
                case 429:      hint = "요청 한도 초과(rate limit)"
                default:       hint = "잘못된 요청"
                }
                failPermanently("연결 거부 (HTTP \(status)) — \(hint)")
                return
            }
        } else if let domain = errorDomain {
            // 응답조차 못 받음(네트워크/소켓). 원문 대신 도메인/코드만.
            log.error("WebSocket 종료: \(domain, privacy: .public) code=\(errorCode ?? 0)")
        }

        // setup 완료 전에 닫혔으면 핸드셰이크 실패로 간주(연속 실패 카운트 증가 경로).
        Task { await handleDisconnect(transient: setupSent) }
    }

    /// 영구 실패 처리: 재연결을 멈추고 사용자에게 명확히 안내한다.
    private func failPermanently(_ message: String) {
        stopped = true
        generation += 1
        teardownSocket()
        log.error("영구 실패 — 재연결 중단: \(message, privacy: .public)")
        state = .error(message)
        emit(.info(message))
        // 상태 표시는 유지하되, 세션 수명 종료를 별도 신호로 보내 소비자가 오디오 재생 정지/
        // 시스템 볼륨 복원 등 정리를 수행하도록 한다(일시 끊김 .state(.error)와 구분).
        emit(.permanentFailure(reason: message))
    }

    /// 연결 끊김 처리.
    /// - Parameter transient: true면 일시적 끊김(정상 운영 중 순단) → 백오프 재연결.
    ///   false면 핸드셰이크 단계 실패 → 연속 실패 카운트를 올리고 상한 초과 시 중단.
    private func handleDisconnect(transient: Bool) async {
        guard !stopped else { return }
        teardownSocket()

        if !transient {
            connectAttempts += 1
            // 핸들로 재개 시도가 핸드셰이크 단계에서 실패하면 핸들이 만료/무효일 수 있으므로
            // 폐기하고 다음 시도는 새 세션으로 진행한다(영구 실패 방지).
            if resumptionHandle != nil {
                log.info("재개 핸들로 연결 실패 → 핸들 폐기 후 새 세션 재시도")
                resumptionHandle = nil
            }
            if connectAttempts > maxConnectAttempts {
                failPermanently("연결 실패 — API 키와 네트워크를 확인하세요 (\(maxConnectAttempts)회 연속 실패)")
                return
            }
        }

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        // 로그 폭주 방지: 간결한 1줄.
        log.error("재연결 예약: \(delay, format: .fixed(precision: 1))s 후 (attempt \(self.connectAttempts))")
        state = .error("연결 끊김 — 재연결 중")
        emit(.info("연결 끊김 — 재연결 중"))

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !stopped else { return }
        openSocket()
    }

    // MARK: - 선제 재연결(M2c)

    /// 세션 한도(약 15분) 도달 전 선제적으로 핸들 기반 재연결을 예약한다(M2c).
    /// setupComplete마다 재무장한다(이전 타이머는 취소).
    private func armProactiveReconnect() {
        proactiveReconnectTask?.cancel()
        let interval = proactiveReconnectInterval
        proactiveReconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.proactiveReconnect()
        }
    }

    /// 선제 재연결 실행: ready 상태에서만 핸들 기반으로 끊김 없이 새 세션으로 넘어간다.
    private func proactiveReconnect() async {
        guard !stopped, state == .ready else { return }
        log.info("선제 재연결(세션 한도 전 핸드오버)")
        emit(.info("세션 갱신 중 (무중단 재연결)"))
        await reconnectWithHandle()
    }

    /// 저장된 재개 핸들로 재연결한다(컨텍스트 유지). 핸들은 resumptionHandle에 보관돼 있어
    /// openSocket→sendSetup에서 자동 사용된다. 핸들이 없으면 일반(새 세션) 재연결과 동일.
    private func reconnectWithHandle() async {
        guard !stopped else { return }
        openSocket()
    }

    // MARK: - 메시지 빌더

    private func makeSetupMessage() -> SetupMessage {
        let generationConfig = GenerationConfig(
            responseModalities: ["AUDIO"],
            // 폴백 모드일 때만 generationConfig 내부에 translationConfig를 둔다(스펙 주의).
            translationConfig: useNestedTranslationConfig ? translationConfig() : nil
        )
        return SetupMessage(setup: .init(
            model: model,
            generationConfig: generationConfig,
            inputAudioTranscription: .init(),
            outputAudioTranscription: .init(),
            // 기본은 top-level translationConfig.
            translationConfig: useNestedTranslationConfig ? nil : translationConfig(),
            // 세션 재개(M2c): 보관된 핸들이 있으면 그 시점부터, 없으면 `{}`로 새 세션 재개 활성화.
            sessionResumption: SessionResumptionConfig(handle: resumptionHandle)
        ))
    }

    private func translationConfig() -> TranslationConfig {
        TranslationConfig(targetLanguageCode: targetLanguageCode, echoTargetLanguage: false)
    }

    // MARK: - URL / 마스킹

    private func makeURL() -> URL? {
        var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components?.url
    }

    /// 로그/에러 출력용으로 키를 마스킹한 URL 문자열. **실제 키를 절대 포함하지 않는다.**
    private nonisolated var maskedURLString: String {
        "wss://generativelanguage.googleapis.com/ws/...BidiGenerateContent?key=****"
    }

    // MARK: - 이벤트 방출

    private func emit(_ event: Event) {
        continuation?.yield(event)
    }

    // MARK: - PCM 변환

    /// Float[-1,1] 샘플을 Int16 little-endian PCM Data로 변환한다(스펙 §5.1).
    /// 클램프 후 ×32767. nonisolated — 오디오 스레드/actor 어디서나 호출 가능(순수 함수).
    nonisolated static func floatToInt16LEData(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * 32767.0)
            // little-endian: 하위 바이트 먼저.
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }
}

// MARK: - WebSocket Delegate (핸드셰이크/종료/에러 콜백)

/// `URLSessionWebSocketDelegate` 구현.
///
/// 동시성: `URLSession`은 delegate 콜백을 임의 스레드(delegateQueue)에서 호출하므로
/// 이 클래스는 actor와 분리된 `final class`로 둔다. actor는 `weak`로만 참조하고,
/// 모든 콜백은 `Task { await client.xxx }`로 actor에 hop해 상태를 변경한다.
/// 자체 가변 상태가 없고(불변 프로퍼티만) actor 경계를 넘기는 값은 전부 Sendable이다.
/// `weak var`는 Sendable 합성을 막으므로 `@unchecked Sendable`로 표기한다 — 안전 근거:
/// (1) client는 콜백마다 Task 캡처로 1회만 읽혀 actor로 hop된다, (2) 가변 공유 상태는
/// actor 내부에만 있고 이 클래스는 그 상태를 직접 만지지 않는다.
private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {

    /// actor를 weak로 참조해 순환 참조를 피한다.
    private weak var client: GeminiLiveClient?
    /// 이 delegate가 담당하는 연결 세대. actor가 generation 일치 여부로 잔여 콜백을 거른다.
    private let generation: Int

    init(client: GeminiLiveClient, generation: Int) {
        self.client = client
        self.generation = generation
    }

    /// 핸드셰이크(HTTP 101) 완료 — 이 시점부터 send가 안전하다.
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let gen = generation
        Task { [weak client] in await client?.handleDidOpen(generation: gen) }
    }

    /// 서버가 close frame으로 종료.
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let gen = generation
        let reasonLength = reason?.count ?? 0   // reason 본문은 키가 섞일 수 있어 길이만 넘긴다
        Task { [weak client] in
            await client?.handleDidClose(generation: gen,
                                         closeCode: closeCode,
                                         reasonLength: reasonLength)
        }
    }

    /// task 완료(에러 포함). 핸드셰이크 실패 시 HTTP 응답 상태코드를 여기서 얻는다.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let gen = generation
        // 키가 섞일 수 있는 URL/에러 원문 대신 상태코드/도메인+코드만 추출해 넘긴다.
        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode
        let ns = error as NSError?
        let errorDomain = ns?.domain
        let errorCode = ns?.code
        Task { [weak client] in
            await client?.handleDidComplete(generation: gen,
                                            httpStatus: httpStatus,
                                            errorDomain: errorDomain,
                                            errorCode: errorCode)
        }
    }
}

// MARK: - 송신 메시지 (Codable, 스펙 §5.1)

/// 첫 메시지: setup. 스펙 §5.1과 필드명 일치.
private struct SetupMessage: Encodable {
    struct Setup: Encodable {
        let model: String
        let generationConfig: GenerationConfig
        let inputAudioTranscription: EmptyConfig
        let outputAudioTranscription: EmptyConfig
        /// top-level translationConfig(기본). 폴백 시 nil.
        let translationConfig: TranslationConfig?
        /// 세션 재개 설정(M2c). handle nil이면 `{}`로 인코딩되어 "재개 활성화(새 세션)"를 의미.
        let sessionResumption: SessionResumptionConfig
    }
    let setup: Setup
}

/// 세션 재개 설정(M2c). handle이 nil이면 JSONEncoder가 키를 생략해 `{}`가 되어
/// 새 세션에서 재개 기능을 활성화한다. handle이 있으면 그 시점부터 세션을 이어받는다.
private struct SessionResumptionConfig: Encodable {
    let handle: String?
}

private struct GenerationConfig: Encodable {
    let responseModalities: [String]
    /// 폴백 위치(generationConfig 내부). 기본은 nil.
    let translationConfig: TranslationConfig?
}

private struct TranslationConfig: Encodable {
    let targetLanguageCode: String
    let echoTargetLanguage: Bool
}

/// `inputAudioTranscription:{}` / `outputAudioTranscription:{}` 빈 객체.
private struct EmptyConfig: Encodable {}

/// 오디오 송신: realtimeInput.audio (스펙 §5.1, 우선 형식).
private struct RealtimeInputMessage: Encodable {
    struct RealtimeInput: Encodable {
        struct Audio: Encodable {
            let data: String      // base64 Int16 LE PCM
            let mimeType: String  // "audio/pcm;rate=16000"
        }
        let audio: Audio
    }
    let realtimeInput: RealtimeInput
}

// MARK: - 수신 메시지 (Decodable, BidiGenerateContentServerMessage)

/// 서버 메시지: 다음 중 하나 + 선택적 usageMetadata (스펙 §5.1).
private struct ServerMessage: Decodable {
    let setupComplete: SetupComplete?
    let serverContent: ServerContent?
    let usageMetadata: UsageMetadata?
    let goAway: GoAway?
    let sessionResumptionUpdate: SessionResumptionUpdate?
}

private struct SetupComplete: Decodable {}

private struct ServerContent: Decodable {
    let inputTranscription: Transcription?
    let outputTranscription: Transcription?
    let modelTurn: ModelTurn?
    let turnComplete: Bool?
    let interrupted: Bool?
}

private struct Transcription: Decodable {
    let text: String?
    let languageCode: String?
}

/// modelTurn.parts[].inlineData(출력 오디오) — 자막 전용 앱이므로 파싱만 하고 폐기.
private struct ModelTurn: Decodable {
    struct Part: Decodable {
        struct InlineData: Decodable {
            let data: String?
            let mimeType: String?
        }
        let inlineData: InlineData?
    }
    let parts: [Part]?
}

/// M2b(비용 추정, 태스크 C). 출력 오디오 토큰 추출용.
///
/// `responseTokensDetails`는 modality별 토큰 분해다(예: `[{modality:"AUDIO", tokenCount:N}]`).
/// 출력 오디오 비용은 modality=="AUDIO"의 tokenCount를 우선 사용하고, 해당 분해가 없으면
/// `responseTokenCount`로 폴백한다.
private struct UsageMetadata: Decodable {
    let totalTokenCount: Int?
    let promptTokenCount: Int?
    let responseTokenCount: Int?
    let responseTokensDetails: [ModalityTokenCount]?

    struct ModalityTokenCount: Decodable {
        let modality: String?
        let tokenCount: Int?
    }

    /// 이 usageMetadata가 보고한 출력 오디오 토큰 수(없으면 nil).
    /// AUDIO modality 우선, 없으면 responseTokenCount 폴백.
    var outputAudioTokens: Int? {
        if let details = responseTokensDetails {
            let audio = details
                .filter { $0.modality?.uppercased() == "AUDIO" }
                .compactMap { $0.tokenCount }
                .reduce(0, +)
            if audio > 0 { return audio }
        }
        return responseTokenCount
    }
}

/// M2c: 서버의 연결 종료 예고. timeLeft 내에 핸들로 선제 재연결한다(무중단 핸드오버).
private struct GoAway: Decodable {
    let timeLeft: String?
}

/// M2c: 세션 재개 핸들 갱신. resumable=true면 newHandle을 보관해 재연결 시 컨텍스트를 잇는다.
private struct SessionResumptionUpdate: Decodable {
    let newHandle: String?
    let resumable: Bool?
}
