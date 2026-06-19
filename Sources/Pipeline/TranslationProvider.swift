import Foundation

/// 오디오를 받아 `PipelineEvent` 스트림을 내는 완성된 번역 경로(spec 004 P0).
///
/// AppState는 이 추상만 안다. 통합형 클라우드 엔진 1개일 수도, 여러 Stage 합성일 수도 있다.
/// 구현은 actor로 격리하는 것을 권장한다(상태 변경/연결 수명 관리).
protocol TranslationProvider: AnyObject, Sendable {
    /// 엔진 능력 선언(자막/오디오/비용 UI 조정 및 폴백 판단용). 불변 — nonisolated.
    nonisolated var capabilities: EngineCapabilities { get }

    /// 결과 이벤트 스트림 시작(내부 연결/모델로드/배선 수행). 1회 호출.
    /// actor 구현이 격리를 유지하도록 async — 호출자는 `await`로 진입한다.
    func start() async -> AsyncStream<PipelineEvent>

    /// 오디오 청크 주입(실시간 오디오 스레드에서 호출 가능 — nonisolated).
    nonisolated func send(_ chunk: AudioChunk)

    /// 완전 종료까지 await(좀비/중복 방지).
    func stop() async

    /// 번역 오디오 재생 런타임 토글(미지원이면 no-op).
    func setTranslatedAudioPlayback(_ on: Bool) async
}
