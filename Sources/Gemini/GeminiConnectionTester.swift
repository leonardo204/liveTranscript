import Foundation
import os

/// Gemini Live API 연결 테스터 (설정 화면 "연결 테스트" 버튼).
///
/// 목적: 사용자가 입력/저장한 키가 **실제로 Live Translate 세션을 열 수 있는지** 검증한다.
/// 오디오는 한 청크도 보내지 않고 `setup`만 전송한 뒤 `setupComplete` 수신 여부로 판정하므로
/// 과금이 사실상 0이다. (GeminiLiveClient와 동일한 setup 형식을 사용한다 — 검증된 nested 형식.)
///
/// 흐름:
///   1. URLSessionWebSocketTask로 BidiGenerateContent 엔드포인트에 연결.
///   2. didOpen(핸드셰이크 완료) → setup 전송.
///   3. `setupComplete` 수신 → `.success`.
///   4. close(1007/4xx 등) / 타임아웃(기본 10초) → `.failure(reason:)`.
///
/// 동시성: `actor`로 격리. `test(apiKey:)`는 async. 테스트 종료 시 소켓을 정리한다.
///
/// 보안: URL 쿼리에 키가 들어가므로 **URL/에러 원문을 절대 로그/결과에 노출하지 않는다.**
/// 로그는 마스킹된 표현만, 실패 사유는 키가 섞이지 않는 사람이 읽는 메시지만 반환한다.
actor GeminiConnectionTester {

    /// 테스트 결과. 실패 사유는 사람이 읽는 메시지(키 비포함).
    enum TestResult: Sendable, Equatable {
        case success
        case failure(reason: String)
    }

    private let model: String
    private let targetLanguageCode: String
    private let timeout: TimeInterval

    private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "GeminiConnTest")

    // MARK: - 진행 중 테스트 상태 (테스트당 1회 사용 후 정리)

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var delegate: TesterDelegate?
    /// 결과를 한 번만 전달하기 위한 continuation. 첫 신호에서 resume 후 nil.
    private var resultContinuation: CheckedContinuation<TestResult, Never>?
    /// setup을 보냈는지(didOpen 1회 보장).
    private var setupSent = false

    init(model: String = AppConfig.geminiModel,
         targetLanguageCode: String = AppConfig.defaultTargetLanguageCode,
         timeout: TimeInterval = 10.0) {
        self.model = model
        self.targetLanguageCode = targetLanguageCode
        self.timeout = timeout
    }

    // MARK: - 공개 API

    /// 주어진 키로 연결을 시도해 setup→setupComplete까지 검증한다.
    /// 항상 소켓을 정리하고 단일 결과를 반환한다(중복 신호는 무시).
    /// - Parameter apiKey: 검증할 Gemini 키. **로그/결과에 노출 금지.**
    func test(apiKey: String) async -> TestResult {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(reason: "API 키가 비어 있습니다")
        }
        guard let url = makeURL(apiKey: trimmed) else {
            return .failure(reason: "엔드포인트 URL 생성 실패")
        }

        // 이전 테스트 잔재 정리(연속 호출 안전).
        teardown()
        setupSent = false

        let delegate = TesterDelegate(tester: self)
        self.delegate = delegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task

        // 타임아웃 워치독: 제한 시간 내 결과가 없으면 실패로 마감한다.
        let to = timeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(to * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.finish(.failure(reason: "시간 초과 — 응답이 없습니다"))
        }

        // 수신 루프(설정 setupComplete 또는 close 메시지 파싱).
        let receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        task.resume()
        log.info("연결 테스트 시작: \(self.maskedURLString, privacy: .public)")

        // 결과를 기다린다(어느 경로든 finish가 호출되면 resume).
        let result = await withCheckedContinuation { (cont: CheckedContinuation<TestResult, Never>) in
            self.resultContinuation = cont
        }

        timeoutTask.cancel()
        receiveTask.cancel()
        teardown()
        return result
    }

    // MARK: - delegate hop

    /// 핸드셰이크 완료 → setup 전송.
    fileprivate func handleDidOpen() {
        guard !setupSent, let task else { return }
        setupSent = true
        log.info("테스트 handshake 완료 → setup 전송")
        let setup = makeSetupMessage()
        guard let data = try? JSONEncoder().encode(setup),
              let json = String(data: data, encoding: .utf8) else {
            finish(.failure(reason: "setup 인코딩 실패"))
            return
        }
        task.send(.string(json)) { [weak self] error in
            if error != nil {
                Task { await self?.finish(.failure(reason: "setup 전송 실패")) }
            }
        }
    }

    /// 서버 close frame 수신 → 코드별 사유 매핑.
    fileprivate func handleDidClose(closeCode: URLSessionWebSocketTask.CloseCode) {
        log.error("테스트 close 수신: code=\(closeCode.rawValue)")
        let reason: String
        switch closeCode {
        case .policyViolation, .unsupportedData, .invalidFramePayloadData:
            // 1007/1003/1008류 — 보통 키 거부 또는 잘못된 요청.
            reason = "API 키가 거부되었습니다 (close \(closeCode.rawValue))"
        case .goingAway, .normalClosure:
            // setup 완료 전 정상/이탈 종료 → 키 문제로 간주.
            reason = "연결이 완료되기 전에 종료되었습니다 (close \(closeCode.rawValue))"
        default:
            reason = "연결이 종료되었습니다 (close \(closeCode.rawValue))"
        }
        finish(.failure(reason: reason))
    }

    /// task 완료(에러/HTTP 상태) → 핸드셰이크 실패 원인 매핑.
    fileprivate func handleDidComplete(httpStatus: Int?, errorDomain: String?, errorCode: Int?) {
        if let status = httpStatus, (400...499).contains(status) {
            log.error("테스트 종료: HTTP status=\(status)")
            let hint: String
            switch status {
            case 401, 403: hint = "API 키가 거부되었습니다"
            case 404:      hint = "모델/엔드포인트를 찾을 수 없습니다"
            case 429:      hint = "요청 한도 초과입니다"
            default:       hint = "잘못된 요청입니다"
            }
            finish(.failure(reason: "\(hint) (HTTP \(status))"))
            return
        }
        if let domain = errorDomain {
            log.error("테스트 종료: \(domain, privacy: .public) code=\(errorCode ?? 0)")
            // 네트워크/소켓 오류(원문 비노출).
            finish(.failure(reason: "네트워크 오류로 연결하지 못했습니다"))
        }
        // 성공/타임아웃 경로에서는 이미 finish 되었을 수 있으므로 여기서 추가 신호는 무시된다.
    }

    // MARK: - 내부

    /// 수신 메시지에서 setupComplete를 찾으면 성공으로 마감한다.
    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data?
                switch message {
                case .string(let text): data = text.data(using: .utf8)
                case .data(let d):      data = d
                @unknown default:       data = nil
                }
                if let data, isSetupComplete(data) {
                    finish(.success)
                    return
                }
            } catch {
                // 끊김은 delegate(didComplete/didClose)에서 사유와 함께 마감한다.
                return
            }
        }
    }

    /// 서버 메시지가 setupComplete인지 가볍게 판별한다(전체 디코딩 불필요).
    private func isSetupComplete(_ data: Data) -> Bool {
        struct Probe: Decodable { let setupComplete: SetupCompleteProbe? }
        struct SetupCompleteProbe: Decodable {}
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            return false
        }
        return probe.setupComplete != nil
    }

    /// 단일 결과를 한 번만 전달하고 continuation을 소비한다(중복 신호 무시).
    private func finish(_ result: TestResult) {
        guard let cont = resultContinuation else { return }
        resultContinuation = nil
        cont.resume(returning: result)
    }

    /// 소켓/세션/delegate를 정리한다.
    private func teardown() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
    }

    // MARK: - 메시지/URL 빌더 (GeminiLiveClient와 동일 형식)

    private func makeSetupMessage() -> TestSetupMessage {
        // 검증된 사실: translationConfig는 **generationConfig 내부**에 둬야 한다
        // (top-level은 서버가 close 1007 "Unknown name translationConfig"로 거부).
        let generationConfig = TestGenerationConfig(
            responseModalities: ["AUDIO"],
            translationConfig: TestTranslationConfig(
                targetLanguageCode: targetLanguageCode,
                echoTargetLanguage: false
            )
        )
        return TestSetupMessage(setup: .init(
            model: model,
            generationConfig: generationConfig,
            inputAudioTranscription: .init(),
            outputAudioTranscription: .init()
        ))
    }

    private func makeURL(apiKey: String) -> URL? {
        var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components?.url
    }

    /// 로그용 마스킹 URL. **실제 키 미포함.**
    private nonisolated var maskedURLString: String {
        "wss://generativelanguage.googleapis.com/ws/...BidiGenerateContent?key=****"
    }
}

// MARK: - WebSocket Delegate

/// 테스터 전용 delegate. 콜백을 actor로 hop한다. (GeminiLiveClient의 delegate와 동일 패턴.)
private final class TesterDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private weak var tester: GeminiConnectionTester?

    init(tester: GeminiConnectionTester) {
        self.tester = tester
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        Task { [weak tester] in await tester?.handleDidOpen() }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        Task { [weak tester] in await tester?.handleDidClose(closeCode: closeCode) }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode
        let ns = error as NSError?
        let errorDomain = ns?.domain
        let errorCode = ns?.code
        Task { [weak tester] in
            await tester?.handleDidComplete(httpStatus: httpStatus,
                                            errorDomain: errorDomain,
                                            errorCode: errorCode)
        }
    }
}

// MARK: - 송신 메시지 (Encodable, GeminiLiveClient setup과 동일 형식)

private struct TestSetupMessage: Encodable {
    struct Setup: Encodable {
        let model: String
        let generationConfig: TestGenerationConfig
        let inputAudioTranscription: TestEmptyConfig
        let outputAudioTranscription: TestEmptyConfig
    }
    let setup: Setup
}

private struct TestGenerationConfig: Encodable {
    let responseModalities: [String]
    let translationConfig: TestTranslationConfig
}

private struct TestTranslationConfig: Encodable {
    let targetLanguageCode: String
    let echoTargetLanguage: Bool
}

private struct TestEmptyConfig: Encodable {}
