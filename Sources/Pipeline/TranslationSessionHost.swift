import Foundation
import SwiftUI
import AppKit
import Translation
import os

/// `TranslationSession`을 SwiftUI `.translationTask`로만 발급할 수 있는 제약(spec 007 §7.4a)을
/// 메뉴바(LSUIElement) AppKit 앱에서 우회하는 **숨은 SwiftUI 호스트**.
///
/// - 화면 밖(off-screen) 좌표 + 거의 투명(alpha≈0) + 마우스 무시 `NSWindow`에 `NSHostingView`로
///   `Color.clear.translationTask(config){ session in ... }` 뷰를 띄운다. translationTask가 동작하려면
///   뷰가 윈도우 계층에 있어야 하므로 완전 orderOut 대신 orderFront(거의 보이지 않게)한다.
///
/// ## 세션 격리 (Swift 6 strict concurrency)
/// `TranslationSession`은 **비-Sendable** 클래스이고 `translate(_:)`는 nonisolated async라,
/// 세션 인스턴스를 MainActor에 보관하거나 세션 사용 도중 actor-격리 메서드를 await하면
/// "sending session risks data races"가 난다. → 세션은 **`translationTask` 콜백 클로저 내부에서만**
/// 생존시키고, 외부와의 브리지는 **nonisolated Sendable 락 박스**(`TranslationChannel`)를 통해서만 한다
/// (클로저 안에서 actor-격리 await가 일어나지 않게). 세션 인스턴스는 격리 경계를 넘지 않는다.
///
/// ## SDK 심볼 근거 (Translation / _Translation_SwiftUI swiftinterface, macOS 26.1 SDK)
/// - `View.translationTask(_ configuration: TranslationSession.Configuration?, action:)`
/// - `TranslationSession.Configuration(source:target:)`
/// - `TranslationSession.translate(_:) async throws -> Response`(`.targetText`)
/// - `TranslationSession.prepareTranslation() async throws`
/// - `LanguageAvailability().status(from:to:) async -> Status(.installed/.supported/.unsupported)`
@MainActor
final class TranslationSessionHost {

    private static let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Pipeline")

    /// 세션 콜백과 번역 단계 사이의 nonisolated Sendable 요청 채널.
    private let channel = TranslationChannel()

    /// SwiftUI 뷰가 관찰하는 설정. configuration 변경 시 translationTask 재구동(새 세션 발급).
    private let state = HostState()

    /// 숨은 호스트 창(세션 생명주기 보유). teardown 시 닫는다.
    private var window: NSWindow?

    init() {}

    /// 소스/타깃 언어를 설정해 세션 발급을 요청한다(언어 변경/시작 시). 최초 호출 시 호스트 창 생성.
    func configure(source: String?, target: String) {
        let targetLang = Locale.Language(identifier: target)
        let sourceLang: Locale.Language? = {
            guard let source, !source.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Locale.Language(identifier: source)
        }()

        ensureWindow()
        state.configuration = TranslationSession.Configuration(source: sourceLang, target: targetLang)
        Self.log.info("\(LogTag.translate, privacy: .public) configure — src=\(source ?? "auto", privacy: .public) tgt=\(target, privacy: .public)")
    }

    /// 텍스트를 번역한다. 세션 콜백 루프에 요청을 보내고 응답을 await한다. 미준비/실패 시 nil.
    func translate(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await channel.submit(text)
    }

    /// 호스트 창과 세션 채널을 해제한다(정지/핫스왑 시).
    func teardown() {
        channel.close()
        state.configuration = nil
        if let window {
            window.orderOut(nil)
            window.contentView = nil
            self.window = nil
        }
        Self.log.info("\(LogTag.translate, privacy: .public) host teardown(창/세션 해제)")
    }

    // MARK: - 숨은 호스트 창

    private func ensureWindow() {
        guard window == nil else { return }
        let hosting = NSHostingView(rootView: TranslationHostView(state: state, channel: channel))
        // 화면 밖 1x1, 거의 투명, 마우스 무시 — 시각적 방해 없이 뷰를 윈도우 계층에 둔다.
        let win = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.alphaValue = 0.001
        win.ignoresMouseEvents = true
        win.level = .normal
        win.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        win.contentView = hosting
        win.orderFront(nil)
        self.window = win
        Self.log.info("\(LogTag.translate, privacy: .public) 숨은 호스트 창 생성")
    }
}

/// 한 건의 번역 요청 — 원문 + 응답 continuation(번역 결과/nil을 단발 전달). Sendable.
private struct TranslationRequest: Sendable {
    let text: String
    let reply: CheckedContinuation<String?, Never>
}

/// 세션 콜백 루프와 번역 단계 사이의 **nonisolated Sendable** 요청 채널(락 보호).
///
/// 세션 콜백 클로저 안에서 actor-격리(MainActor) await 없이 요청을 받기 위해, 요청 스트림과
/// continuation을 락으로 보호하는 별도 박스에 둔다. (`translationTask` 콜백이 세션을 사용하는
/// 동안 cross-actor await가 일어나지 않게 하여 "sending session" 데이터레이스를 회피한다.)
private final class TranslationChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<TranslationRequest>.Continuation?

    /// 새 세션 루프용 요청 스트림을 만든다(translationTask 콜백마다 호출 → 항상 fresh).
    /// 이전 continuation은 종료해 옛 루프를 닫는다(세션 재발급 시 좀비 방지).
    func makeStream() -> AsyncStream<TranslationRequest> {
        lock.lock()
        continuation?.finish()
        let (stream, cont) = AsyncStream<TranslationRequest>.makeStream()
        continuation = cont
        lock.unlock()
        return stream
    }

    /// 번역 요청을 활성 채널에 넣고 결과를 await한다. 채널이 없으면(세션 미발급) nil.
    func submit(_ text: String) async -> String? {
        let cont = lock.withLock { continuation }
        guard let cont else { return nil }
        return await withCheckedContinuation { (reply: CheckedContinuation<String?, Never>) in
            let result = cont.yield(TranslationRequest(text: text, reply: reply))
            switch result {
            case .enqueued:
                break
            case .terminated, .dropped:
                reply.resume(returning: nil)
            @unknown default:
                reply.resume(returning: nil)
            }
        }
    }

    /// 채널을 닫는다(teardown). 활성 루프가 종료된다(버퍼된 요청은 종료 전 전달됨).
    func close() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}

/// 숨은 호스트 뷰가 관찰하는 설정 보관소(@MainActor @Observable). configuration 변경 시 재구동.
@MainActor
@Observable
private final class HostState {
    var configuration: TranslationSession.Configuration?
}

/// `translationTask`로 세션을 받아 요청 채널을 소비하는 보이지 않는 SwiftUI 뷰.
///
/// 세션은 이 클로저 안에서만 사용되며, 클로저 내부에서 actor-격리(MainActor) await를 하지 않는다
/// (요청 스트림은 nonisolated `TranslationChannel`에서 받음). 따라서 세션이 격리 경계를 넘지 않는다.
private struct TranslationHostView: View {
    @State var state: HostState
    let channel: TranslationChannel

    private nonisolated static let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Pipeline")

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(state.configuration) { @Sendable [channel] session in
                // 세션 전 생명주기를 자유 함수(완전 nonisolated)에 위임한다. 클로저를 @Sendable로 만들어
                // MainActor 격리를 상속하지 않게 하고(nonisolated 실행), 세션은 이 함수 안에서만 사용되어
                // 어떤 actor 경계도 넘지 않으므로 "sending session" 데이터레이스가 없다.
                await runTranslationSession(session, channel: channel)
            }
    }
}

/// 발급된 `TranslationSession`의 생명주기(가용성/prepare/요청 루프)를 처리하는 **자유 함수**.
///
/// 어떤 actor에도 격리되지 않으므로 세션(비-Sendable)을 단일 격리 영역에서만 사용한다
/// → strict concurrency 데이터레이스 없음. 채널은 nonisolated Sendable 박스라 안전하게 캡처된다.
private func runTranslationSession(_ session: TranslationSession, channel: TranslationChannel) async {
    let logger = Logger(subsystem: AppConfig.bundleIdentifier, category: "Pipeline")
    logger.info("\(LogTag.translate, privacy: .public) 세션 수신")

    do {
        try await session.prepareTranslation()
        logger.info("\(LogTag.translate, privacy: .public) prepareTranslation 완료")
    } catch {
        logger.debug("\(LogTag.translate, privacy: .public) prepareTranslation 예외(무해 가능): \(String(describing: error), privacy: .public)")
    }

    // 요청 스트림 소비 — nonisolated 채널에서 받으므로 actor hop 없음(세션이 경계를 넘지 않음).
    let requests = channel.makeStream()
    for await req in requests {
        do {
            let response = try await session.translate(req.text)
            req.reply.resume(returning: response.targetText)
        } catch {
            let preview = req.text.count > 40 ? String(req.text.prefix(40)) + "…" : req.text
            logger.debug("\(LogTag.translate, privacy: .public) translate 실패: \(String(describing: error), privacy: .public) text=\"\(preview, privacy: .public)\"")
            req.reply.resume(returning: nil)
        }
    }
    logger.info("\(LogTag.translate, privacy: .public) 세션 요청 루프 종료")
}
