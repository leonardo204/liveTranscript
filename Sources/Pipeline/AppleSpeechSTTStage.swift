import Foundation
import AVFoundation
import Speech
import os

/// Apple `SpeechTranscriber`/`SpeechAnalyzer`(macOS 26+) 기반 온디바이스 STT 단계(spec 007 §7.3).
///
/// 오디오 청크(16kHz mono Float32)를 받아 `transcriber.results`의 volatile/final 가설을
/// `TextSegmentEvent.segment(text:isFinal:)`로 흘린다. **세그먼트 교체 모델**(delta 누적 아님 — §5).
///
/// ## 동시성 (spec 004 §7.0/§7.10)
/// - actor 격리. `send(_:)`는 실시간 오디오 스레드에서 nonisolated로 진입하므로, 변환에 필요한
///   상태(`inputBuilder`/`converter`/`analyzerFormat`)는 락 기반 `@unchecked Sendable` 박스
///   (`SpeechFeedBox`)에 격리해 actor hop 없이 직접 접근한다(SystemTapAudioSource.TapCaptureSink 패턴).
/// - 결과 소비 Task는 `start()`에서 띄우고 `stop()`에서 cancel + 자원 해제까지 await.
///
/// ## SDK 심볼 근거 (Speech.swiftinterface, macOS 26.1 SDK에서 확인 — 추측 아님)
/// - `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`
/// - `SpeechAnalyzer(modules:)` + `start(inputSequence:)` + `finalizeAndFinishThroughEndOfInput()`
/// - `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`
/// - `transcriber.results`(AsyncSequence<SpeechTranscriber.Result, Error>), `result.text`(AttributedString),
///   `result.isFinal`(SpeechModuleResult extension)
/// - `AnalyzerInput(buffer:)`
/// - 모델 설치: `SpeechTranscriber.supportedLocales`/`installedLocales`,
///   `AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`
/// - 권한: `SFSpeechRecognizer.requestAuthorization`(Objective-C 콜백 → continuation 래핑)
///
/// ⚠️ deploymentTarget=26.0이라 `@available(macOS 26)` 래핑은 불필요(전부 가용).
actor AppleSpeechSTTStage: SpeechToTextStage {

    /// 전사 대상(소스) 로케일 식별자(BCP-47, 예 "en"/"en-US"). 설정 sourceLanguageCode에서 만든다.
    nonisolated let sourceLocaleIdentifier: String

    /// 실시간 send 경로용 변환/주입 박스(락 보호). actor 격리 밖에서 직접 접근한다.
    private let feed = SpeechFeedBox()

    /// 출력 세그먼트 스트림 continuation(결과 소비 Task가 yield, stop이 finish).
    private var outputContinuation: AsyncStream<TextSegmentEvent>.Continuation?

    /// 전사 모듈/분석기/입력 시퀀스 continuation(자원 추적·해제용).
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    /// 결과 소비 Task(transcriber.results → segment). stop에서 cancel + await.
    private var resultsTask: Task<Void, Never>?

    /// 세그먼트 로그 스로틀(고빈도 volatile 갱신). 첫 1회 + N회마다 1회만 debug.
    private var segmentLogCount = 0

    private static let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Pipeline")

    init(sourceLocaleIdentifier: String) {
        // 빈 문자열 방어: 기본 "en"으로 폴백(로케일 해석 실패 방지).
        let trimmed = sourceLocaleIdentifier.trimmingCharacters(in: .whitespaces)
        self.sourceLocaleIdentifier = trimmed.isEmpty ? "en" : trimmed
    }

    // MARK: - SpeechToTextStage

    func start() async -> AsyncStream<TextSegmentEvent> {
        let (stream, continuation) = AsyncStream<TextSegmentEvent>.makeStream()
        self.outputContinuation = continuation

        // 권한 → 모델 → 분석기 구성을 별도 Task로 진행(실패 시 .failure yield + finish).
        // start()는 즉시 스트림을 반환하고, 준비/소비는 비동기로 진행한다.
        let setupTask = Task { [weak self] () -> Void in
            await self?.setupAndConsume(continuation: continuation)
        }
        // 결과 소비 Task로 보관(stop에서 cancel). setup 내부에서 results 루프를 돈다.
        self.resultsTask = setupTask

        Self.log.info("\(LogTag.speech, privacy: .public) start — locale=\(self.sourceLocaleIdentifier, privacy: .public)")
        return stream
    }

    /// 권한/모델/분석기 구성 후 results 루프를 소비한다. 실패는 모두 graceful(.failure + finish).
    private func setupAndConsume(continuation: AsyncStream<TextSegmentEvent>.Continuation) async {
        // 1) 권한.
        let authorized = await Self.requestAuthorization()
        guard authorized else {
            Self.log.error("\(LogTag.speech, privacy: .public) 권한 거부/미허용 — 음성 인식 비활성")
            continuation.yield(.failure("음성 인식 권한이 필요합니다(시스템 설정 > 개인정보 보호 > 음성 인식)."))
            continuation.finish()
            return
        }
        Self.log.info("\(LogTag.speech, privacy: .public) 권한 authorized")

        // 2) 소스 언어 코드를 실제 '지원 로케일'로 해석한다(예: "en" → "en-US").
        //    SpeechTranscriber/AssetInventory.reserve는 정확한 지원 식별자를 요구하므로,
        //    언어코드만("en") 넘기면 "Unable to reserve unsupported locale"로 거부된다.
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = Self.resolveSupportedLocale(code: sourceLocaleIdentifier, supported: supported) else {
            let ids = supported.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
            Self.log.error("\(LogTag.speech, privacy: .public) 지원 로케일 매칭 실패 — wanted=\(self.sourceLocaleIdentifier, privacy: .public) supported=[\(ids, privacy: .public)]")
            continuation.yield(.failure("이 언어는 온디바이스 전사를 지원하지 않습니다(\(self.sourceLocaleIdentifier))."))
            continuation.finish()
            return
        }
        Self.log.info("\(LogTag.speech, privacy: .public) locale 해석 — wanted=\(self.sourceLocaleIdentifier, privacy: .public) resolved=\(locale.identifier(.bcp47), privacy: .public)")

        // 3) 전사 모듈 구성(해석된 정확 로케일 사용).
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        // 3) 로케일 모델 설치 보장(미설치 시 다운로드 시도). API 불확실 지점 — try/catch로 graceful.
        do {
            try await Self.ensureModelInstalled(for: transcriber, locale: locale)
        } catch {
            Self.log.error("\(LogTag.speech, privacy: .public) 모델 설치/확인 실패: \(String(describing: error), privacy: .public)")
            continuation.yield(.failure("이 언어의 음성 인식 모델을 설치하지 못했습니다(\(self.sourceLocaleIdentifier))."))
            continuation.finish()
            return
        }

        // 4) 분석기 + best 포맷.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let bestFormat else {
            Self.log.error("\(LogTag.speech, privacy: .public) bestAvailableAudioFormat=nil — 호환 포맷 없음")
            continuation.yield(.failure("음성 인식 호환 오디오 포맷을 찾지 못했습니다."))
            continuation.finish()
            return
        }
        Self.log.info("\(LogTag.speech, privacy: .public) analyzerFormat sr=\(bestFormat.sampleRate, privacy: .public) ch=\(bestFormat.channelCount, privacy: .public)")

        // 5) 입력 시퀀스 구성 → 박스에 변환기/포맷/continuation 주입(실시간 send 경로용).
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputBuilder
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AppConfig.audioSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: bestFormat) else {
            Self.log.error("\(LogTag.speech, privacy: .public) 입력 변환기 생성 실패(16k mono → analyzerFormat)")
            continuation.yield(.failure("오디오 변환기 구성에 실패했습니다."))
            continuation.finish()
            return
        }
        feed.configure(
            sourceFormat: sourceFormat,
            analyzerFormat: bestFormat,
            converter: converter,
            builder: inputBuilder
        )

        // 6) 분석 시작.
        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            Self.log.error("\(LogTag.speech, privacy: .public) analyzer.start 실패: \(String(describing: error), privacy: .public)")
            continuation.yield(.failure("음성 분석을 시작하지 못했습니다."))
            continuation.finish()
            return
        }
        Self.log.info("\(LogTag.speech, privacy: .public) ready — 전사 시작")
        continuation.yield(.info("온디바이스 전사 준비 완료"))

        // 7) 결과 소비 루프. Task cancel 시 자연 종료.
        do {
            for try await result in transcriber.results {
                if Task.isCancelled { break }
                let text = String(result.text.characters)
                let isFinal = result.isFinal
                continuation.yield(.segment(text: text, isFinal: isFinal))

                segmentLogCount += 1
                if isFinal || segmentLogCount == 1 || segmentLogCount % 25 == 0 {
                    let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
                    Self.log.debug("\(LogTag.speech, privacy: .public) seg final=\(isFinal, privacy: .public) n=\(self.segmentLogCount, privacy: .public) text=\"\(preview, privacy: .public)\"")
                }
            }
        } catch {
            if !Task.isCancelled {
                Self.log.error("\(LogTag.speech, privacy: .public) results 루프 오류: \(String(describing: error), privacy: .public)")
                continuation.yield(.failure("전사 중 오류가 발생했습니다."))
            }
        }
        continuation.finish()
        Self.log.info("\(LogTag.speech, privacy: .public) results 루프 종료")
    }

    nonisolated func send(_ chunk: AudioChunk) {
        // 실시간 오디오 스레드 — actor hop 없이 박스에서 직접 변환/주입.
        feed.feed(chunk)
    }

    func stop() async {
        Self.log.info("\(LogTag.speech, privacy: .public) stop 시작")
        // 입력 종료 → 분석 마무리 → 결과 Task cancel → 자원 해제.
        inputContinuation?.finish()
        feed.teardown()
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Self.log.debug("\(LogTag.speech, privacy: .public) finalizeAndFinish 예외(무해 가능): \(String(describing: error), privacy: .public)")
            }
        }
        resultsTask?.cancel()
        await resultsTask?.value
        resultsTask = nil

        outputContinuation?.finish()
        outputContinuation = nil
        inputContinuation = nil
        analyzer = nil
        transcriber = nil
        Self.log.info("\(LogTag.speech, privacy: .public) stop 완료(자원 해제)")
    }

    // MARK: - Helpers

    /// `SFSpeechRecognizer.requestAuthorization`(콜백)를 async로 래핑한다(.authorized만 true).
    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// 소스 언어 코드("en", "ko" 등 또는 "en-US")를 SpeechTranscriber가 실제 지원하는
    /// 정확 로케일로 해석한다. 정확 식별자가 아니면 reserve/install이 거부되므로 필수.
    /// 우선순위: ① 정확(bcp47) 일치 → ② 같은 언어코드 + 현재 지역 → ③ en은 en-US 선호 → ④ 같은 언어코드 첫 번째.
    private static func resolveSupportedLocale(code: String, supported: [Locale]) -> Locale? {
        let wanted = code.lowercased()
        let wantedLang = wanted.split(separator: "-").first.map(String.init) ?? wanted

        // ① 정확 일치(bcp47, 대소문자 무시)
        if let exact = supported.first(where: { $0.identifier(.bcp47).lowercased() == wanted }) {
            return exact
        }
        // 같은 언어코드 후보들
        let sameLang = supported.filter {
            ($0.language.languageCode?.identifier.lowercased() ?? "") == wantedLang
        }
        guard !sameLang.isEmpty else { return nil }
        // ② 현재 지역 우선
        if let region = Locale.current.region?.identifier,
           let regional = sameLang.first(where: { $0.region?.identifier == region }) {
            return regional
        }
        // ③ 영어는 en-US 선호
        if wantedLang == "en",
           let us = sameLang.first(where: { $0.identifier(.bcp47).lowercased() == "en-us" }) {
            return us
        }
        // ④ 같은 언어코드 첫 번째(결정적 순서를 위해 정렬)
        return sameLang.sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }.first
    }

    /// 로케일 모델 설치 보장(spec 007 §7.3). 설치돼 있으면 no-op, 미설치면 다운로드 요청.
    ///
    /// ⚠️ 정확한 자산 설치 API는 SDK 버전에 따라 다를 수 있어 try/throws로 감싼다 — 실패 시
    /// 호출자가 `.failure`로 graceful 처리한다. 설치 상태/시도를 `[Speech]` 로그로 남겨 진단 가능.
    private static func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let installedIDs = installed.map { $0.identifier(.bcp47) }
        let supported = await SpeechTranscriber.supportedLocales
        let supportedIDs = supported.map { $0.identifier(.bcp47) }
        let wanted = locale.identifier(.bcp47)

        let isInstalled = installedIDs.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            || installedIDs.contains { $0.split(separator: "-").first.map(String.init)?.caseInsensitiveCompare(wanted.split(separator: "-").first.map(String.init) ?? wanted) == .orderedSame }
        let isSupported = supportedIDs.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            || supportedIDs.contains { $0.split(separator: "-").first.map(String.init)?.caseInsensitiveCompare(wanted.split(separator: "-").first.map(String.init) ?? wanted) == .orderedSame }

        Self.log.info("\(LogTag.speech, privacy: .public) model — wanted=\(wanted, privacy: .public) installed=\(isInstalled, privacy: .public) supported=\(isSupported, privacy: .public)")

        if isInstalled { return }
        guard isSupported else {
            // 지원 목록에 없으면 설치 불가 — 명확히 throw해 호출자가 안내하게 한다.
            throw NSError(domain: "AppleSpeechSTTStage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "지원하지 않는 전사 로케일: \(wanted)"
            ])
        }

        // 미설치 + 지원 → 다운로드/설치 요청.
        Self.log.info("\(LogTag.speech, privacy: .public) model 미설치 — 다운로드 요청 시작 wanted=\(wanted, privacy: .public)")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
            Self.log.info("\(LogTag.speech, privacy: .public) model 다운로드/설치 완료 wanted=\(wanted, privacy: .public)")
        } else {
            // 설치 요청이 nil이면 이미 가용한 것으로 간주(추가 설치 불필요).
            Self.log.info("\(LogTag.speech, privacy: .public) model 설치 요청 불필요(이미 가용) wanted=\(wanted, privacy: .public)")
        }
    }
}

/// 실시간 오디오 스레드에서 16kHz mono Float32 청크를 `analyzerFormat`으로 변환해
/// `AnalyzerInput`을 입력 시퀀스로 주입하는 락 보호 박스(spec 007 §7.3).
///
/// `send`는 actor 격리 밖(오디오 스레드)에서 호출되므로 상태를 락으로 보호한다.
/// (SystemTapAudioSource.TapCaptureSink와 동일 패턴.) 변환 실패는 드롭 + 스로틀 로그.
private final class SpeechFeedBox: @unchecked Sendable {

    private let lock = NSLock()
    private var sourceFormat: AVAudioFormat?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var builder: AsyncStream<AnalyzerInput>.Continuation?

    private var sentCount = 0
    private var dropCount = 0

    private static let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Pipeline")

    func configure(
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        converter: AVAudioConverter,
        builder: AsyncStream<AnalyzerInput>.Continuation
    ) {
        lock.withLock {
            self.sourceFormat = sourceFormat
            self.analyzerFormat = analyzerFormat
            self.converter = converter
            self.builder = builder
            self.sentCount = 0
            self.dropCount = 0
        }
    }

    func teardown() {
        lock.withLock {
            self.sourceFormat = nil
            self.analyzerFormat = nil
            self.converter = nil
            self.builder = nil
        }
    }

    /// 16k mono Float32 `[Float]` → AVAudioPCMBuffer → 변환 → AnalyzerInput 주입.
    func feed(_ chunk: AudioChunk) {
        lock.lock()
        guard let sourceFormat, let analyzerFormat, let converter, let builder else {
            lock.unlock()
            return
        }

        guard !chunk.isEmpty,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(chunk.count)),
              let inChannel = inBuffer.floatChannelData else {
            dropCount += 1
            let n = dropCount
            lock.unlock()
            Self.throttledDropLog(n, reason: "buffer 생성")
            return
        }
        inBuffer.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { src in
            inChannel[0].update(from: src.baseAddress!, count: chunk.count)
        }

        // 출력 용량: 샘플레이트 비율 기반.
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(chunk.count) * ratio) + 16
        guard capacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            dropCount += 1
            let n = dropCount
            lock.unlock()
            Self.throttledDropLog(n, reason: "out buffer")
            return
        }

        let feed = SpeechConverterFeed(buffer: inBuffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in feed.next(outStatus) }
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
        guard status == .haveData || status == .inputRanDry, outBuffer.frameLength > 0 else {
            dropCount += 1
            let n = dropCount
            lock.unlock()
            Self.throttledDropLog(n, reason: "convert(\(status.rawValue))")
            return
        }

        builder.yield(AnalyzerInput(buffer: outBuffer))
        sentCount += 1
        let n = sentCount
        lock.unlock()
        if n == 1 || n % 50 == 0 {
            Self.log.debug("\(LogTag.speech, privacy: .public) feed 송신 누적=\(n, privacy: .public)")
        }
    }

    private static func throttledDropLog(_ n: Int, reason: String) {
        if n == 1 || n % 50 == 0 {
            log.debug("\(LogTag.speech, privacy: .public) feed 드롭(\(reason, privacy: .public)) 누적=\(n, privacy: .public)")
        }
    }
}

/// AVAudioConverter 입력 블록용 1회성 버퍼 공급 박스(SystemTapAudioSource.TapConverterFeed와 동일 패턴).
private final class SpeechConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        guard let b = buffer else {
            outStatus.pointee = .noDataNow
            return nil
        }
        buffer = nil
        outStatus.pointee = .haveData
        return b
    }
}
