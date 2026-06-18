import Foundation
import Observation

/// 자막 누적 + 영화 자막식 표시 엔진 (스펙 §5.4, M3).
///
/// Gemini Live API는 번역/원문 텍스트를 **증분(delta) 조각**으로 스트리밍하고
/// `turnComplete`로 한 발화(턴)의 종료를 알린다. 따라서 클라이언트가 delta를
/// **이어붙여(append) 누적**해야 완전한 문장이 된다. 동작 모델:
///
/// - **delta 수신** → 현재 줄(`currentTranslation`/`currentSource`)에 **append**하여
///   문장이 자라는 것을 즉시 화면에 보인다. 진행 중 숨김 타이머는 취소(계속 성장).
/// - **turnComplete 수신** → 현재 줄을 **확정**으로 고정하고 버퍼를 비운다. 확정 줄을
///   **표시 유지 시간**(`holdSeconds`, 기본 2.0s) 동안 유지한 뒤 **자동 페이드아웃**.
///   이후 다음 문장은 빈 버퍼에서 처음부터 새로 자란다.
/// - **무음 fallback** → turnComplete가 누락된 연속 음성에서 자막이 영원히 누적되지
///   않도록, 마지막 delta 이후 `silenceTimeout`(기본 2.0s) 동안 새 조각이 없으면
///   자동으로 확정 처리한다(turnComplete와 동일 경로).
///
/// 페이드 인/아웃 애니메이션(~0.25s)은 표시 뷰(`SubtitleOverlayView`)가 `isVisible`
/// 전이를 SwiftUI `.animation`으로 처리한다 — 엔진은 "무엇을, 언제까지 보일지"만 결정한다.
///
/// **길이 기반 break(태스크 B)**: turnComplete/무음과 별개로, 누적 중인 번역 줄이
/// `maxCharsBeforeBreak`(약 2줄 분량)를 초과하면 현재까지를 즉시 확정(`confirmTurn`)하고
/// 버퍼를 비워 다음 조각부터 새로 누적한다. 영화 자막처럼 ~2줄만 유지하기 위함이며,
/// **줄임표(…)로 자르지 않고** 문장을 자연스럽게 다음으로 넘긴다. 번역 기준으로 break하며
/// 원문(source)도 함께 리셋되어 과도하게 길어지지 않는다.
///
/// `@MainActor @Observable` — 자막 HUD(SwiftUI)가 직접 구독해 실시간 갱신한다.
@MainActor
@Observable
final class SubtitleEngine {

    /// 길이 기반 break 임계 등 튜닝값을 읽는 설정 저장소(없으면 AppConfig 기본).
    @ObservationIgnored private let settings: SettingsStore?

    init(settings: SettingsStore? = nil) {
        self.settings = settings
    }

    // MARK: - 텍스트 상태

    /// 현재 누적 중인 번역 줄. delta가 도착할 때마다 이어붙는다.
    private(set) var currentTranslation: String = ""

    /// 현재 누적 중인 원문 줄. 원문 동시 표시 토글용(FR-8).
    private(set) var currentSource: String = ""

    /// 직전에 확정된 번역 줄(turnComplete/무음). 누적이 비었을 때 페이드아웃까지 이걸 보여준다.
    private(set) var confirmedTranslation: String = ""

    /// 직전에 확정된 원문 줄.
    private(set) var confirmedSource: String = ""

    /// 자막을 화면에 보여야 하는지. 확정 후 유지 시간 경과/무음 시 false로 내려가며,
    /// 뷰가 이 전이를 페이드 인/아웃으로 렌더한다.
    private(set) var isVisible: Bool = false

    /// HUD에 보여줄 "현재 번역문" — 누적 중이면 누적분, 아니면 마지막 확정분.
    var displayTranslation: String {
        currentTranslation.isEmpty ? confirmedTranslation : currentTranslation
    }

    /// HUD에 보여줄 "현재 원문".
    var displaySource: String {
        currentSource.isEmpty ? confirmedSource : currentSource
    }

    // MARK: - 타이밍 상수 (스펙 §5.4)

    /// 확정 자막 유지 시간(초) — turnComplete 후 이 시간만큼 보인 뒤 페이드아웃.
    /// 사용자 명세의 핵심: "turnComplete 후 ~2초 유지 후 사라짐".
    private static let holdSeconds: Double = 2.0

    /// 무음 fallback 시간(초) — 마지막 delta 이후 이 시간 동안 새 조각이 없으면 자동 확정.
    /// turnComplete가 누락된 연속 음성에서 자막이 무한 누적되지 않게 한다.
    private static let silenceTimeout: Double = 2.0

    /// 길이 기반 break 임계(번역 글자수). 설정값이 유효하면 그것, 아니면 AppConfig 기본(~2줄).
    /// 영화 자막처럼 ~2줄만 유지하고 넘으면 다음으로 넘기기 위한 누적 글자수 상한.
    private var maxCharsBeforeBreak: Int {
        let configured = settings?.subtitleMaxCharsBeforeBreak ?? 0
        return configured > 0 ? configured : AppConfig.defaultMaxCharsBeforeBreak
    }

    /// 확정 줄을 내리는 단발 타이머(holdSeconds). 새 delta가 오면 취소된다.
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// 무음 fallback 타이머(silenceTimeout). delta마다 재설정, turnComplete/확정 시 취소.
    @ObservationIgnored private var silenceTask: Task<Void, Never>?

    // MARK: - 수신 처리

    /// 번역 delta 조각 수신 → 현재 줄에 이어붙여 누적하고 즉시 표시한다.
    /// 빈 조각/비정상 중복 조각은 무시한다.
    func ingestTranslationDelta(_ delta: String) {
        guard appendIfMeaningful(delta, to: &currentTranslation) else { return }
        showAndCancelHide()
        // 길이 기반 break(태스크 B): ~2줄 분량 초과 시 현재까지를 확정하고 다음으로 넘긴다.
        // turnComplete/무음 fallback과 별개 경로. 줄임표 없이 문장을 자연스럽게 분리한다.
        if currentTranslation.count >= maxCharsBeforeBreak {
            confirmTurn()   // 확정 줄은 holdSeconds 유지 후 페이드 → 새 버퍼에서 다음 누적 시작.
            return
        }
        scheduleSilenceFallback()
    }

    /// 원문 delta 조각 수신 → 현재 원문 줄에 누적한다. 표시/확정 타이밍은 turnComplete 기준.
    func ingestSourceDelta(_ delta: String) {
        _ = appendIfMeaningful(delta, to: &currentSource)
    }

    /// 턴(발화) 종료 — 누적된 현재 줄을 확정 줄로 고정하고 유지 시간 후 페이드아웃한다.
    /// 이후 버퍼를 비워 다음 문장이 처음부터 새로 시작하게 한다.
    func ingestTurnComplete() {
        confirmTurn()
    }

    /// 세션 정지/재시작 시 누적 텍스트를 비우고 즉시 숨긴다.
    func reset() {
        hideTask?.cancel(); hideTask = nil
        silenceTask?.cancel(); silenceTask = nil
        currentTranslation = ""
        currentSource = ""
        confirmedTranslation = ""
        confirmedSource = ""
        isVisible = false
    }

    // MARK: - 내부: 누적

    /// delta를 버퍼에 이어붙인다. delta에는 보통 자체 공백이 포함되므로 **단순 concat**.
    /// 방어: 빈 조각 무시, 직전과 동일한 조각의 중복 수신 무시.
    /// - Returns: 실제로 append되어 표시 갱신이 필요하면 true.
    private func appendIfMeaningful(_ delta: String, to buffer: inout String) -> Bool {
        guard !delta.isEmpty else { return false }
        // 동일 조각이 그대로 다시 끝에 붙는 중복(네트워크 재전송류) 방어.
        if !delta.isEmpty, buffer.hasSuffix(delta) { return false }
        buffer += delta
        return true
    }

    // MARK: - 내부: 확정/표시

    /// 현재 누적 줄을 확정으로 고정하고 holdSeconds 후 페이드아웃 타이머를 건다.
    /// turnComplete와 무음 fallback이 공유하는 단일 경로.
    private func confirmTurn() {
        silenceTask?.cancel(); silenceTask = nil

        if !currentTranslation.isEmpty { confirmedTranslation = currentTranslation }
        if !currentSource.isEmpty { confirmedSource = currentSource }
        currentTranslation = ""
        currentSource = ""

        scheduleHide()
    }

    /// 새 delta가 들어왔을 때: 보이게 하고 진행 중 숨김 타이머를 취소한다(문장이 계속 성장).
    private func showAndCancelHide() {
        hideTask?.cancel(); hideTask = nil
        isVisible = true
    }

    /// 확정 줄을 holdSeconds만큼 유지 후 숨긴다(결정적 시간).
    private func scheduleHide() {
        hideTask?.cancel()
        guard !confirmedTranslation.isEmpty else {
            isVisible = false
            hideTask = nil
            return
        }
        isVisible = true
        let nanos = UInt64(Self.holdSeconds * 1_000_000_000)
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            // 그동안 새 delta가 와서 다음 문장이 자라기 시작했으면 내리지 않는다.
            if self.currentTranslation.isEmpty {
                self.isVisible = false
            }
        }
    }

    /// 무음 fallback: 마지막 delta 이후 silenceTimeout 동안 조용하면 자동 확정한다.
    /// delta마다 재설정되므로, 말이 이어지는 동안에는 발화되지 않는다.
    private func scheduleSilenceFallback() {
        silenceTask?.cancel()
        let nanos = UInt64(Self.silenceTimeout * 1_000_000_000)
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            // 아직 확정되지 않은 누적분이 남아 있을 때만 자동 확정.
            if !self.currentTranslation.isEmpty || !self.currentSource.isEmpty {
                self.confirmTurn()
            }
        }
    }
}
