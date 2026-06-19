import Foundation

/// 조합형 파이프라인(spec 004 §5.2, spec 007 §2.1)의 단계(Stage) 프로토콜.
///
/// Gemini Live는 텍스트를 **append-delta**로 흘리지만(`PipelineEvent.translatedText(delta:)`),
/// STT(SpeechTranscriber)/MT(Translation)는 **현재 세그먼트 전체(volatile)를 반복 갱신**하고
/// `isFinal`로 확정하는 **세그먼트 교체** 모델이다. 그래서 단계 간 전달 이벤트도 delta가 아니라
/// `segment(text:isFinal:)`(전체 텍스트 교체)로 정의한다.
///
/// 이 파일은 **타입 골격만** 정의한다(spec 007 §7.2). 실제 Apple Speech/Translation 엔진
/// (`import Speech`/`import Translation`)은 §7.3/§7.4에서 별도 추가한다 — 여기서는 import하지 않는다.

/// 단계 간 텍스트 전달 이벤트. STT/MT는 delta 누적이 아니라 "현재 세그먼트 전체"를 교체한다.
enum TextSegmentEvent: Sendable {
    /// 현재 세그먼트의 전체 텍스트(누적이 아니라 교체). isFinal=true면 발화/세그먼트 확정.
    case segment(text: String, isFinal: Bool)
    /// 사람이 읽는 상태 메시지(키/민감값 비포함).
    case info(String)
    /// 복구 불가 실패 사유(상위가 정지/수렴).
    case failure(String)
}

/// (b) 음성 → 원문 세그먼트 단계(ASR/STT). 오디오 in → `segment` out.
///
/// 수명 계약(spec 004 §7.13.3): `start()`는 멱등, `send`는 실시간 오디오 스레드에서 호출 가능
/// (nonisolated), `stop()`은 내부 Task cancel + 큐/버퍼 flush + OS 자원 해제 + 출력 스트림
/// `continuation.finish()`까지 완료를 await한다.
protocol SpeechToTextStage: AnyObject, Sendable {
    /// 전사 대상(소스) 로케일 식별자(BCP-47, 예 "en"). 실제 엔진은 Locale로 해석한다.
    var sourceLocaleIdentifier: String { get }
    /// 원문 세그먼트 스트림 시작(내부 모델 로드/배선). 1회 호출.
    func start() async -> AsyncStream<TextSegmentEvent>
    /// 오디오 청크 주입(실시간 오디오 스레드 — nonisolated).
    nonisolated func send(_ chunk: AudioChunk)
    /// 완전 종료까지 await(좀비/중복 방지).
    func stop() async
}

/// (c) 텍스트 → 텍스트 단계(번역/교정). 원문 세그먼트 스트림 → 번역 세그먼트 스트림.
///
/// `isFinal`은 보존한다(volatile 원문 → volatile 번역, final 원문 → final 번역). 비용/지연
/// 균형을 위해 구현체는 final 세그먼트만 번역하는 등 자체 정책을 둘 수 있다(spec 007 §4).
protocol TextTransformStage: AnyObject, Sendable {
    /// 원문 세그먼트 스트림을 받아 번역 세그먼트 스트림을 낸다(세그먼트 단위, isFinal 보존).
    func transform(_ input: AsyncStream<TextSegmentEvent>) -> AsyncStream<TextSegmentEvent>
    /// 완전 종료까지 await(내부 Task cancel + 자원 해제 + 출력 스트림 finish).
    func stop() async
}
