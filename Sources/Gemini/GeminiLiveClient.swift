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
/// - 연결 끊김 시 단순 백오프 재연결(무중단 핸드오버/sessionResumption은 M2c).
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
    enum Event: Sendable {
        /// 연결 상태 변화.
        case state(State)
        /// 번역 자막(부분/확정). `isFinal`은 turnComplete로 확정된 줄.
        case translation(text: String, isFinal: Bool)
        /// 원문 전사(부분/확정). 원문 동시 표시 토글용(FR-8).
        case source(text: String, isFinal: Bool)
        /// 정보성 알림(연결됨/재연결 등) — HUD/로그용. 키는 절대 포함하지 않는다.
        case info(String)
    }

    // MARK: - 설정

    private let apiKey: String
    private let model: String
    private let targetLanguageCode: String

    /// 재연결 백오프(초). 끊길 때마다 증가, 연결 성공 시 리셋.
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0

    /// translationConfig 위치 폴백 플래그.
    /// 서버가 top-level translationConfig를 거부하면 generationConfig 내부로 재시도한다(스펙 주의).
    private var useNestedTranslationConfig = false

    // MARK: - 런타임 상태

    private(set) var state: State = .disconnected {
        didSet {
            guard state != oldValue else { return }
            emit(.state(state))
        }
    }

    /// 사용자가 stop()을 호출했는지 — true면 재연결하지 않는다.
    private var stopped = true

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?

    /// 이벤트 스트림 continuation. connect 시 생성된다.
    private var continuation: AsyncStream<Event>.Continuation?

    private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "GeminiLive")

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

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        self.session = session

        guard let url = makeURL() else {
            state = .error("잘못된 엔드포인트 URL")
            return
        }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // setup 먼저 전송(첫 메시지).
        sendSetup()

        // 수신 루프 시작.
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            await self?.receiveMessages()
        }
        log.info("WebSocket 연결 시도: \(self.maskedURLString, privacy: .public)")
    }

    private func teardownSocket() {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// setup 메시지를 전송한다(연결 직후 첫 메시지). 스펙 §5.1.
    private func sendSetup() {
        guard let task else { return }
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

    private func receiveMessages() async {
        guard let task else { return }
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
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
            // 취소가 아니면 연결 끊김 → 재연결.
            if !Task.isCancelled {
                await handleDisconnect(error)
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
            reconnectDelay = 1.0
            state = .ready
            emit(.info("Gemini 연결됨 (setup 완료)"))
            return
        }

        if let content = msg.serverContent {
            let isFinal = content.turnComplete ?? false
            if let out = content.outputTranscription?.text, !out.isEmpty {
                emit(.translation(text: out, isFinal: isFinal))
            }
            if let inp = content.inputTranscription?.text, !inp.isEmpty {
                emit(.source(text: inp, isFinal: isFinal))
            }
            // modelTurn의 inlineData(출력 오디오 24kHz)는 자막 전용 앱이므로 폐기(디코드/재생 안 함).
            // turnComplete만 별도로 알려 부분 텍스트 확정 처리를 돕는다.
            if isFinal {
                emit(.translation(text: "", isFinal: true))
            }
        }

        // usageMetadata: M2b(비용 추정)에서 사용 — 지금은 파싱 자리만 두고 무시.
        // _ = msg.usageMetadata

        // goAway / sessionResumptionUpdate: M2c(무중단 재연결)에서 처리 — 지금은 로그만.
        if msg.goAway != nil {
            log.info("goAway 수신 (M2c에서 처리 예정)")
            emit(.info("세션 종료 예고 수신"))
        }
        if msg.sessionResumptionUpdate != nil {
            log.debug("sessionResumptionUpdate 수신 (M2c에서 처리 예정)")
        }
    }

    // MARK: - 에러/재연결

    private func handleSendError(_ error: Error) {
        guard !stopped else { return }
        log.error("송신 오류 → 재연결 시도")
        Task { await handleDisconnect(error) }
    }

    private func handleDisconnect(_ error: Error) async {
        guard !stopped else { return }
        // 에러 메시지에 URL/키가 섞일 수 있으므로 원문을 그대로 노출하지 않는다.
        log.error("연결 끊김 → \(self.reconnectDelay, format: .fixed(precision: 1))s 후 재연결")
        teardownSocket()
        state = .error("연결 끊김 — 재연결 중")
        emit(.info("연결 끊김 — 재연결 중"))

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
            translationConfig: useNestedTranslationConfig ? nil : translationConfig()
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
    }
    let setup: Setup
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

/// M2b(비용 추정)에서 사용. 지금은 파싱 자리만.
private struct UsageMetadata: Decodable {
    let totalTokenCount: Int?
    let promptTokenCount: Int?
    let responseTokenCount: Int?
}

/// M2c(무중단 재연결)에서 처리. 지금은 로그만.
private struct GoAway: Decodable {
    let timeLeft: String?
}

/// M2c. 세션 재개 핸들.
private struct SessionResumptionUpdate: Decodable {
    let newHandle: String?
    let resumable: Bool?
}
