import Foundation
import os

/// 조합형 파이프라인(spec 004 §5.3, spec 007 §2.2): STT 단계 + (선택)번역 단계를 묶어
/// 단일 `PipelineEvent` 스트림을 내는 `TranslationProvider`.
///
/// - `transform` 있음(번역): STT 원문 세그먼트를 (showSource면) `.sourceSegment`로 방출하면서
///   동시에 번역 단계 입력으로 전달하고, 번역 단계 출력을 `.translatedSegment`로 방출한다.
/// - `transform` 없음(전사 전용): STT 세그먼트를 그대로 `.translatedSegment`(메인 자막)로 방출한다.
///
/// 세그먼트 모델이므로 `TextSegmentEvent.segment(text:isFinal:)` → `PipelineEvent.(source|translated)Segment`
/// 로 매핑한다(누적 delta 아님 — spec 007 §5).
///
/// ⚠️ spec 007 §7.2 단계에서는 **실제 STT/Transform 엔진이 없어 인스턴스화되지 않는다**(팩토리가
/// `.onDeviceTranslate`에서 nil 반환). 타입/배선만 컴파일·동시성 검증한다(§7.3/§7.4에서 실엔진 주입).
///
/// 동시성(spec 004 §7.0/§7.10): actor 격리. 펌프 Task는 `stop()`에서 cancel + 각 Stage `stop()`을
/// await하고, 출력/내부 스트림은 상류 종료/`finish()`로 자연 종료한다.
actor ComposedTranslationProvider: TranslationProvider {
    nonisolated let capabilities: EngineCapabilities

    private let stt: any SpeechToTextStage
    private let transform: (any TextTransformStage)?
    /// 원문 자막을 함께 낼지(`.sourceSegment` 방출 여부). 번역 자막은 항상 방출한다.
    private let showSource: Bool

    /// STT(및 번역) 세그먼트를 PipelineEvent로 사상해 방출하는 단일 펌프 Task. stop에서 cancel.
    private var pumpTask: Task<Void, Never>?

    private static let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Pipeline")

    init(
        stt: any SpeechToTextStage,
        transform: (any TextTransformStage)?,
        showSource: Bool,
        capabilities: EngineCapabilities
    ) {
        self.stt = stt
        self.transform = transform
        self.showSource = showSource
        self.capabilities = capabilities
    }

    func start() async -> AsyncStream<PipelineEvent> {
        let sttStream = await stt.start()
        let showSource = self.showSource
        let transform = self.transform

        return AsyncStream<PipelineEvent> { continuation in
            let task = Task {
                continuation.yield(.state(.preparing))
                continuation.yield(.state(.ready))

                if let transform {
                    // 번역 경로: STT 세그먼트를 (a) showSource면 .sourceSegment로 방출하고
                    // (b) 번역 단계 입력으로 전달한다. 번역 출력은 .translatedSegment로 방출.
                    // 입력/출력을 별도 Task로 처리해 한쪽이 다른 쪽을 블록하지 않게 한다.
                    let (transformInput, inputCont) = AsyncStream<TextSegmentEvent>.makeStream()
                    let transformOutput = transform.transform(transformInput)

                    // 번역 출력 펌프(자식 Task) — .translatedSegment로 방출.
                    let outPump = Task {
                        for await ev in transformOutput {
                            Self.map(ev, isSource: false, into: continuation)
                        }
                    }

                    // STT 입력 펌프 — 원문 방출 + 번역 입력 전달.
                    for await ev in sttStream {
                        if case .segment(let text, let isFinal) = ev, showSource {
                            continuation.yield(.sourceSegment(text: text, isFinal: isFinal))
                        } else if case .info(let msg) = ev {
                            continuation.yield(.info(msg))
                        } else if case .failure(let reason) = ev {
                            continuation.yield(.permanentFailure(reason: reason))
                        }
                        inputCont.yield(ev)
                    }
                    inputCont.finish()       // STT 종료 → 번역 입력도 종료 → 번역 출력 자연 종료.
                    await outPump.value      // 번역 출력 펌프 완료까지 대기 후 스트림 닫기.
                } else {
                    // 전사 전용: STT 세그먼트를 메인 자막(.translatedSegment)으로 방출.
                    for await ev in sttStream {
                        Self.map(ev, isSource: false, into: continuation)
                    }
                }
                continuation.finish()
            }
            pumpTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `TextSegmentEvent`를 `PipelineEvent`로 사상한다. isSource=true면 원문 세그먼트로,
    /// false면 번역 세그먼트로 방출한다. info/failure는 양쪽 공통.
    private static func map(
        _ ev: TextSegmentEvent,
        isSource: Bool,
        into continuation: AsyncStream<PipelineEvent>.Continuation
    ) {
        switch ev {
        case .segment(let text, let isFinal):
            if isSource {
                continuation.yield(.sourceSegment(text: text, isFinal: isFinal))
            } else {
                continuation.yield(.translatedSegment(text: text, isFinal: isFinal))
            }
        case .info(let msg):
            continuation.yield(.info(msg))
        case .failure(let reason):
            continuation.yield(.permanentFailure(reason: reason))
        }
    }

    nonisolated func send(_ chunk: AudioChunk) {
        // 오디오 청크는 STT 단계로만 주입(번역 단계는 텍스트 입력). nonisolated 경로.
        stt.send(chunk)
    }

    func stop() async {
        // 수명 계약(spec 004 §7.13.2): 펌프 Task cancel → 각 Stage stop()을 순서 무관 전부 await.
        pumpTask?.cancel()
        pumpTask = nil
        await transform?.stop()
        await stt.stop()
        Self.log.info("\(LogTag.provider, privacy: .public) ComposedTranslationProvider stop done")
    }

    func setTranslatedAudioPlayback(_ on: Bool) async {
        // 번역 오디오 미지원(translatedAudio=false) — no-op.
    }
}
