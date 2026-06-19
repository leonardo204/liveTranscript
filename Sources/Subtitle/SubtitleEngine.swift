import Foundation
import Observation
import os

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

    /// 진단 로그용 Logger(자막 확정 사유/리셋 추적, A3). 민감정보(키) 미포함.
    @ObservationIgnored private let log = Logger(subsystem: AppConfig.bundleIdentifier, category: "Subtitle")

    init(settings: SettingsStore? = nil) {
        self.settings = settings
    }

    /// 자막 확정 사유(A3 진단 로그용). turnComplete/무음/길이 break를 구분해 폭주 원인을 식별한다.
    private enum ConfirmReason: String {
        case turnComplete
        case silence
        case charBreak
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

    // MARK: - roll-up(세그먼트 모드) 상태 (B안, spec 007 §5)

    /// 세그먼트(STT/MT) 모드에서 확정 번역 문장들의 FIFO. 깊이 = `subtitleMaxLines`.
    /// 새 확정 문장이 들어오면 위로 굴러가고(오래된 것 제거), 문장마다 사라지지 않는다(roll-up 표준).
    /// 1줄 설정이면 A안(교체), N줄이면 FIFO roll-up이 된다.
    private(set) var rollupLines: [String] = []

    /// 세그먼트 경로(`ingestSegment`)가 한 번이라도 쓰이면 true → 표시 모델을 roll-up으로 전환.
    /// Gemini delta 경로와 한 세션에서 섞이지 않으며, `reset()`에서 false로 되돌린다.
    private(set) var segmentMode = false

    /// roll-up 무음 정리 타이머(긴 무음에만 전체 정리 — 문장마다 페이드하지 않기 위함).
    @ObservationIgnored private var idleClearTask: Task<Void, Never>?

    /// roll-up 모드에서 마지막 세그먼트 이후 이 시간(초) 동안 조용하면 화면을 정리한다.
    /// 문장 간 공백마다 사라지지 않도록 holdSeconds(2s)보다 충분히 길게 둔다.
    private static let rollupIdleClearSeconds: Double = 8.0

    /// roll-up 깊이(= 사용자 자막 줄수). 최소 1.
    private var rollupDepth: Int { max(1, settings?.subtitleMaxLines ?? 2) }

    /// HUD에 보여줄 "현재 번역문".
    /// - 세그먼트 모드: 확정 문장 FIFO(최근 `rollupDepth`개)를 줄바꿈으로 이어 표시(roll-up).
    /// - delta(Gemini) 모드: 누적 중이면 누적분, 아니면 마지막 확정분.
    var displayTranslation: String {
        if segmentMode {
            let lines = currentTranslation.isEmpty ? rollupLines : rollupLines + [currentTranslation]
            return lines.suffix(rollupDepth).joined(separator: "\n")
        }
        return currentTranslation.isEmpty ? confirmedTranslation : currentTranslation
    }

    /// HUD에 보여줄 "현재 원문". 세그먼트 모드에선 진행 중(interim) 원문 1줄.
    var displaySource: String {
        if segmentMode { return currentSource }
        return currentSource.isEmpty ? confirmedSource : currentSource
    }

    // MARK: - 타이밍 상수 (스펙 §5.4)

    /// 확정 자막 유지 시간(초) — turnComplete 후 이 시간만큼 보인 뒤 페이드아웃.
    /// 사용자 명세의 핵심: "turnComplete 후 ~2초 유지 후 사라짐".
    private static let holdSeconds: Double = 2.0

    /// 무음 fallback 시간(초) — 마지막 delta 이후 이 시간 동안 새 조각이 없으면 자동 확정.
    /// turnComplete가 누락된 연속 음성에서 자막이 무한 누적되지 않게 한다.
    private static let silenceTimeout: Double = 2.0

    /// 길이 기반 break 임계(번역 글자수). **뷰의 줄수(`subtitleMaxLines`)와 연동(B2)**한다.
    ///
    /// 기존에는 `subtitleMaxCharsBeforeBreak`(기본 50)만 읽어 뷰 줄수와 무관했다 → 줄수를
    /// 2→3으로 올려도 엔진 누적량이 그대로라 실제로 1줄만 보이는 버그가 있었다. 수정:
    /// `charsPerSubtitleLine × subtitleMaxLines`를 줄수 기반 임계로 계산하고, 사용자가 명시한
    /// `subtitleMaxCharsBeforeBreak` 설정값이 있으면 둘 중 **큰 값**을 써서 줄수 증가가
    /// 항상 누적량 증가로 이어지게 한다(예: 줄수 2→56, 3→84로 커져 2~3줄이 누적·표시).
    /// 뷰의 `.lineLimit(style.maxLines)`는 이미 연결돼 있으므로 엔진 누적 상한만 키우면 된다.
    private var maxCharsBeforeBreak: Int {
        let lines = settings?.subtitleMaxLines ?? 2
        let byLines = AppConfig.charsPerSubtitleLine * max(1, lines)
        let configured = settings?.subtitleMaxCharsBeforeBreak ?? 0
        return max(byLines, configured)
    }

    /// 확정 줄을 내리는 단발 타이머(holdSeconds). 새 delta가 오면 취소된다.
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// 무음 fallback 타이머(silenceTimeout). delta마다 재설정, turnComplete/확정 시 취소.
    @ObservationIgnored private var silenceTask: Task<Void, Never>?

    /// generation(재번역 단위) 경계 리셋 대기 플래그.
    ///
    /// translate 모델은 한 turn 안에서 같은 구절을 여러 generation으로 반복 재번역(revise)한다.
    /// 각 generation은 "현재까지 최선의 번역"을 처음부터 다시 내보내므로, generation 경계
    /// (generationComplete/turnComplete) 이후 **처음 도착하는 delta는 새 generation의 시작**이다.
    /// 그 첫 delta에서 직전 generation의 누적(current)을 비워, 재번역이 위에 누적되지 않고
    /// 새로 자라며 대체되게 한다(무한 append/반복 차단). 경계 신호 수신 시 즉시 비우지 않고
    /// **다음 delta가 올 때 비우는** 이유: 경계 직후에도 화면에 직전 generation을 유지해
    /// 깜빡임을 줄이기 위함이다.
    @ObservationIgnored private var pendingGenerationReset = false

    // MARK: - 수신 처리

    /// 번역 delta 조각 수신 → 현재 줄에 이어붙여 누적하고 즉시 표시한다.
    /// 빈 조각/비정상 중복 조각은 무시한다.
    func ingestTranslationDelta(_ delta: String) {
        // 진단: delta 원문(앞 40자)과 길이 — 증분/누적/반복 전송 여부 판별용(자막 텍스트, 키 아님).
        log.debug("\(LogTag.subtitle, privacy: .public) 번역 delta: \"\(delta.prefix(40), privacy: .public)\" len=\(delta.count)")
        applyPendingGenerationResetIfNeeded()
        guard appendIfMeaningful(delta, to: &currentTranslation) else { return }
        showAndCancelHide()
        // 길이 기반 break(태스크 B): ~2줄 분량 초과 시 현재까지를 확정하고 다음으로 넘긴다.
        // turnComplete/무음 fallback과 별개 경로. 줄임표 없이 문장을 자연스럽게 분리한다.
        if currentTranslation.count >= maxCharsBeforeBreak {
            // 진단: charBreak 임계 계산 내역(줄수/byLines/configured/최종)을 함께 로그(1줄만 보이는 원인 확정용).
            let lines = settings?.subtitleMaxLines ?? 2
            let byLines = AppConfig.charsPerSubtitleLine * max(1, lines)
            let configured = settings?.subtitleMaxCharsBeforeBreak ?? 0
            log.debug("\(LogTag.subtitle, privacy: .public) charBreak 발생: len=\(self.currentTranslation.count, privacy: .public) 임계=\(self.maxCharsBeforeBreak, privacy: .public) (줄수=\(lines, privacy: .public) byLines=\(byLines, privacy: .public) configured=\(configured, privacy: .public))")
            confirmTurn(reason: .charBreak)   // 확정 줄은 holdSeconds 유지 후 페이드 → 새 버퍼에서 다음 누적 시작.
            return
        }
        scheduleSilenceFallback()
    }

    /// 원문 delta 조각 수신 → 현재 원문 줄에 누적한다. 표시/확정 타이밍은 turnComplete 기준.
    func ingestSourceDelta(_ delta: String) {
        // 진단: 피드백 루프(번역 오디오 재캡처) 여부 확인용 — 원문 delta가 한국어 번역과 같으면 피드백 신호.
        log.debug("\(LogTag.subtitle, privacy: .public) 원문 delta: \"\(delta.prefix(40), privacy: .public)\" len=\(delta.count)")
        applyPendingGenerationResetIfNeeded()
        _ = appendIfMeaningful(delta, to: &currentSource)
    }

    /// generation(재번역 단위) 경계 신호 수신 — 다음 delta에서 직전 generation을 리셋하도록 표시한다.
    ///
    /// 화면은 **현재 줄을 그대로 유지**하고(다음 generation 첫 delta가 와서 대체할 때까지),
    /// 페이드/확정을 걸지 않는다(turn은 계속 진행 중일 수 있음). 무음 fallback 타이머만 취소해,
    /// 경계 직후 무음으로 잘못 확정되는 것을 막는다. 실제 버퍼 비움은
    /// `applyPendingGenerationResetIfNeeded()`가 다음 delta 진입 시 수행한다.
    func ingestGenerationComplete() {
        pendingGenerationReset = true
        silenceTask?.cancel(); silenceTask = nil
        log.debug("\(LogTag.subtitle, privacy: .public) generation 경계 — 다음 delta에서 버퍼 리셋")
    }

    /// generation 리셋이 대기 중이면(직전 generation/turn 종료 후 첫 delta), 직전 generation의
    /// 누적(current)을 confirmed로 옮겨 표시를 유지한 채 current를 비운다.
    ///
    /// 이렇게 하면 새 generation의 재번역이 직전 generation 위에 누적되지 않고 빈 버퍼에서
    /// 처음부터 자라며 대체된다. displayTranslation은 current 우선이라 새 generation을 보여주고,
    /// current가 빈 짧은 순간에도 confirmed가 직전 줄을 보여줘 깜빡임을 줄인다.
    private func applyPendingGenerationResetIfNeeded() {
        guard pendingGenerationReset else { return }
        if !currentTranslation.isEmpty { confirmedTranslation = currentTranslation }
        if !currentSource.isEmpty { confirmedSource = currentSource }
        currentTranslation = ""
        currentSource = ""
        pendingGenerationReset = false
        log.debug("\(LogTag.subtitle, privacy: .public) generation 리셋 적용: 직전 generation을 confirmed로 이동, current 비움")
    }

    /// 턴(발화) 종료 — 누적된 현재 줄을 확정 줄로 고정하고 유지 시간 후 페이드아웃한다.
    /// 이후 버퍼를 비워 다음 문장이 처음부터 새로 시작하게 한다.
    func ingestTurnComplete() {
        confirmTurn(reason: .turnComplete)
        // turn 종료 후 도착하는 첫 delta는 새 turn(새 generation)의 시작이므로, 다음 delta에서
        // 버퍼를 비워 새로 누적되게 한다(이전 turn 잔재가 다음 turn에 append되지 않도록).
        pendingGenerationReset = true
    }

    // MARK: - 세그먼트(교체) 경로 (spec 007 §5 — STT/MT 엔진용)

    /// STT/MT 같은 **세그먼트 엔진**용 수신 경로. delta append와 달리 현재 줄을 **교체**한다.
    ///
    /// SpeechTranscriber/Translation은 "현재 가설 전체(volatile)"를 반복 갱신하고 final로
    /// 확정한다 → 누적-append가 아니라 매번 전체 텍스트를 set 한다. Gemini delta 경로
    /// (`ingestTranslationDelta` 등)와 **완전히 별개**이며, 한 세션에서 둘이 섞이지 않는다
    /// (엔진 종류가 둘 중 하나만 방출).
    ///
    /// - Parameters:
    ///   - translation: 번역 세그먼트 전체. nil이면 번역 줄을 **유지**(원문만 갱신할 때).
    ///   - source: 원문 세그먼트 전체. nil이면 원문 줄을 유지(번역만 갱신할 때).
    ///   - isFinal: true면 확정 경계(`confirmTurn` 재사용 — hold/dedup/scheduleHide),
    ///     false면 라이브 갱신만(current 교체 + isVisible 유지).
    func ingestSegment(translation: String?, source: String?, isFinal: Bool) {
        // 진단: 어떤 줄을 어떻게 갱신했는지(앞 40자/길이/확정 여부) — roll-up 추적용(텍스트, 키 아님).
        log.debug("\(LogTag.subtitle, privacy: .public) segment: t=\"\((translation ?? "·").prefix(40), privacy: .public)\" s=\"\((source ?? "·").prefix(40), privacy: .public)\" final=\(isFinal, privacy: .public)")

        // roll-up(세그먼트) 모드로 전환. delta 누적 모델의 generation-리셋 플래그는 무관 → false 고정.
        segmentMode = true
        pendingGenerationReset = false

        // 원문(원문 동시 표시)은 진행 중 interim을 라이브로 갱신만 한다(확정/페이드 없음).
        if let source { currentSource = source }

        if let translation {
            if isFinal {
                // 확정 문장 → dedup/collapse 후 roll-up FIFO에 push(직전과 동일하면 무시).
                let collapsed = Self.dedupGlobalSentences(Self.collapseRepeats(translation))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !collapsed.isEmpty, rollupLines.last != collapsed {
                    rollupLines.append(collapsed)
                    if rollupLines.count > rollupDepth {
                        rollupLines.removeFirst(rollupLines.count - rollupDepth)
                    }
                }
                currentTranslation = ""   // 진행 중 번역 줄 없음(final-only)
            } else {
                // volatile 번역(현재 final-only라 사실상 안 옴) — 진행 줄로만 표시.
                currentTranslation = translation
            }
        }

        // roll-up은 문장마다 페이드하지 않는다 — 짧은 hide/silence 타이머를 끄고, 긴 무음 정리만 건다.
        hideTask?.cancel(); hideTask = nil
        silenceTask?.cancel(); silenceTask = nil
        isVisible = true
        armIdleClear()
    }

    /// roll-up 모드 무음 정리: 마지막 세그먼트 이후 rollupIdleClearSeconds 동안 조용하면 화면을 비운다.
    /// 세그먼트마다 재설정되므로 말이 이어지는 동안에는 유지된다(문장 사이 공백마다 사라지지 않음).
    private func armIdleClear() {
        idleClearTask?.cancel()
        let nanos = UInt64(Self.rollupIdleClearSeconds * 1_000_000_000)
        idleClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.log.debug("\(LogTag.subtitle, privacy: .public) roll-up idle clear: 무음 \(Self.rollupIdleClearSeconds, privacy: .public)s → 화면 정리")
            self.rollupLines = []
            self.currentTranslation = ""
            self.currentSource = ""
            self.isVisible = false
        }
    }

    // MARK: - 고정 미리보기 (테스트 자막 토글)

    /// 테스트 자막 토글 ON: 페이드/확정 없이 **고정 표시**한다(슬라이더/스타일 변경 시 위치만 갱신).
    ///
    /// 일반 ingest 경로와 달리 hold/silence 타이머를 일절 걸지 않아 자동으로 사라지지 않는다.
    /// current와 confirmed를 동일하게 채워, 어느 표시 경로(displayTranslation/displaySource)에서도
    /// 빈 버퍼로 인해 자막이 사라지지 않게 한다. generation 리셋 대기 플래그도 false로 둔다.
    func showPreview(translation: String, source: String?) {
        // 진행 중일 수 있는 모든 타이머를 취소(자동 확정/페이드 예약 차단).
        hideTask?.cancel(); hideTask = nil
        silenceTask?.cancel(); silenceTask = nil
        let src = source ?? ""
        currentTranslation = translation
        currentSource = src
        confirmedTranslation = translation
        confirmedSource = src
        pendingGenerationReset = false
        isVisible = true
        log.debug("\(LogTag.subtitle, privacy: .public) showPreview: 고정 미리보기 표시(타이머 없음)")
    }

    /// 테스트 자막 토글 OFF: 미리보기 텍스트를 비우고 즉시 숨긴다(reset과 동일 경로).
    func hidePreview() {
        reset()
    }

    /// 세션 정지/재시작 시 누적 텍스트를 비우고 즉시 숨긴다.
    func reset() {
        // A3: 세션 재시작 폭주 여부 확인용(짧은 간격으로 반복되면 재연결 storm 신호).
        log.debug("\(LogTag.subtitle, privacy: .public) 자막 reset")
        hideTask?.cancel(); hideTask = nil
        silenceTask?.cancel(); silenceTask = nil
        idleClearTask?.cancel(); idleClearTask = nil
        currentTranslation = ""
        currentSource = ""
        confirmedTranslation = ""
        confirmedSource = ""
        rollupLines = []
        segmentMode = false
        pendingGenerationReset = false   // generation 경계 상태도 초기화(다음 세션은 깨끗하게 시작)
        isVisible = false
    }

    // MARK: - 내부: 누적

    /// delta를 버퍼에 누적한다. 모델/전사가 **증분·누적·반복**을 섞어 보내도 중복 없이 합친다.
    ///
    /// 1) **겹침 억제 머지**: delta의 접두사가 buffer의 접미사와 겹치면 겹친 만큼 제외하고 새 부분만 붙인다.
    ///    - 증분 전송(겹침 0) / 누적 전송(buffer 전체가 겹침) / 경계 중복을 한 번에 처리.
    /// 2) **연속 동일 문장 붕괴**: 같은 문장을 반복 전송(모델 반복/피드백)해도 1회만 남긴다.
    /// - Returns: 실질적으로 버퍼가 바뀌어 표시 갱신이 필요하면 true.
    private func appendIfMeaningful(_ delta: String, to buffer: inout String) -> Bool {
        guard !delta.isEmpty else { return false }
        if buffer.isEmpty {
            // collapseRepeats(즉시 반복) → dedupGlobalSentences(전역 중복 문장) 순으로 정리.
            let collapsed = Self.dedupGlobalSentences(Self.collapseRepeats(delta))
            guard !collapsed.isEmpty else { return false }
            buffer = collapsed
            return true
        }
        let bChars = Array(buffer)
        let dChars = Array(delta)
        // buffer 접미사와 delta 접두사가 일치하는 최대 길이 k.
        var k = min(bChars.count, dChars.count)
        while k > 0 {
            if Array(bChars.suffix(k)) == Array(dChars.prefix(k)) { break }
            k -= 1
        }
        let newPart = String(dChars.dropFirst(k))
        guard !newPart.isEmpty else { return false }
        let merged = buffer + newPart
        // collapseRepeats(즉시 반복) → dedupGlobalSentences(전역 중복 문장) 순으로 정리.
        let collapsed = Self.dedupGlobalSentences(Self.collapseRepeats(merged))
        guard collapsed != buffer else { return false }
        // 진단: 겹침 k / 새로 붙인 길이. 정리로 줄어든 경우 중복 붕괴 remark(반복/피드백 신호).
        // 길이 변화는 collapseRepeats + dedupGlobalSentences 둘을 합친 전후 길이(merged→collapsed).
        if collapsed.count < merged.count {
            log.debug("\(LogTag.subtitle, privacy: .public) append: 겹침k=\(k, privacy: .public) newPart=\(newPart.count, privacy: .public)자, 중복 붕괴: \(merged.count, privacy: .public)→\(collapsed.count, privacy: .public)자")
        } else {
            log.debug("\(LogTag.subtitle, privacy: .public) append: 겹침k=\(k, privacy: .public) newPart=\(newPart.count, privacy: .public)자")
        }
        buffer = collapsed
        return true
    }

    /// 공백으로 분리한 토큰열에서 **끝에 연속으로 반복된 동일 부분열**을 1회로 합친다(반복 적용).
    /// 모델이 같은 구/문장을 반복 전송해도(종결부호 유무 무관) 표시 중복을 제거한다.
    /// 예: "A B C A B C" → "A B C", "that makes the brain that makes the brain" → "that makes the brain".
    /// 최소 3토큰 반복부터 붕괴(우연한 1~2토큰 반복 보호). 자막 특성상 즉시 반복은 사실상 오류다.
    ///
    /// 기존 `collapseRepeatedSentences`(종결부호 기준)는 완성된 동일 문장만 잡아 종결부호 없는
    /// 구 단위 반복을 놓쳤다 → 토큰 단위로 일반화한다. 토큰 배열 동등성 비교라 다중/선행 공백
    /// 차이도 흡수하고, 한국어(어절)/영어(단어) 혼합 모두 공백 토큰으로 동작한다.
    private static func collapseRepeats(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 6 else { return text }   // 너무 짧으면 그대로
        var guardLoop = 0
        var changed = true
        while changed && guardLoop < 200 {
            guardLoop += 1
            changed = false
            let n = tokens.count
            // 큰 반복 블록부터 시도(긴 반복 우선 제거). 최소 3토큰.
            var m = n / 2
            while m >= 3 {
                // m ≤ n/2 이므로 n - 2*m ≥ 0 보장(인덱스 안전).
                if Array(tokens[(n - m)..<n]) == Array(tokens[(n - 2 * m)..<(n - m)]) {
                    tokens.removeLast(m)
                    changed = true
                    break
                }
                m -= 1
            }
        }
        return tokens.joined(separator: " ")
    }

    /// 누적 버퍼에서 **이미 등장한 동일 문장의 재등장**을 제거한다(첫 등장만 유지).
    /// translate 모델이 앞 문장을 나중에 다시 흘리는(비연속) 반복을 정리한다.
    /// 종결부호(. ! ? 。 ！ ？) 기준으로 문장을 나누고, 공백 무시 정규화로 비교한다.
    /// **진행 중인 마지막 조각(종결부호로 안 끝남)은 성장 중이므로 절대 제거하지 않는다.**
    /// 너무 짧은 문장(norm 길이 < 4)은 우연 중복 방지를 위해 dedup 대상에서 제외한다("네." "음." 보호).
    private static func dedupGlobalSentences(_ text: String) -> String {
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
        // 문장 토큰화(종결부호 포함). 마지막 토큰이 종결부호로 안 끝나면 "진행 중"으로 표시.
        var sentences: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if terminators.contains(ch) { sentences.append(cur); cur = "" }
        }
        let hasPartialTail = !cur.isEmpty
        if hasPartialTail { sentences.append(cur) }
        func norm(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        var seen = Set<String>()
        var result: [String] = []
        for (i, s) in sentences.enumerated() {
            let isPartialLast = hasPartialTail && i == sentences.count - 1
            let key = norm(s)
            // 짧은 문장(norm < 4)은 seen 비교를 건너뛰고 항상 유지(우연 중복/짧은 감탄 보호).
            if !isPartialLast, key.count >= 4, seen.contains(key) {
                continue   // 이미 표시한 완성 문장의 재등장 → 제거
            }
            if !isPartialLast, key.count >= 4 { seen.insert(key) }
            result.append(s)
        }
        return result.joined()
    }

    // MARK: - 내부: 확정/표시

    /// 현재 누적 줄을 확정으로 고정하고 holdSeconds 후 페이드아웃 타이머를 건다.
    /// turnComplete와 무음 fallback이 공유하는 단일 경로.
    private func confirmTurn(reason: ConfirmReason) {
        // A3: 확정 사유와 누적 길이를 함께 로그(자막이 1줄로 빨리 끊기는 원인 확정용). 텍스트 내용은 미포함.
        log.debug("\(LogTag.subtitle, privacy: .public) 자막 확정: 사유=\(reason.rawValue, privacy: .public), len=\(self.currentTranslation.count)")
        silenceTask?.cancel(); silenceTask = nil

        // 수정2: 확정 직전 정리를 한 번 더 적용한다. charBreak가 중복 구가 완성되기
        // 전에 끊어 누적 버퍼에 반복 잔여가 남는 경우가 있어, 확정 줄에 중복이 고정되지
        // 않도록 번역/원문 모두 collapseRepeats(즉시 반복) → dedupGlobalSentences(전역
        // 중복 문장) 순으로 재정리한다.
        let collapsedTranslation = Self.dedupGlobalSentences(Self.collapseRepeats(currentTranslation))
        let collapsedSource = Self.dedupGlobalSentences(Self.collapseRepeats(currentSource))

        // 공백 무시 비교(확정↔다음 줄 경계 중복 판정용).
        func norm(_ s: String) -> String { s.filter { !$0.isWhitespace } }

        // 수정2: 확정↔다음 줄 경계 중복 방지. 새로 확정할 번역(collapsed)이 직전 확정 줄과
        // 공백 무시 동일하면 중복 확정으로 간주해 새로 확정하지 않는다(표시 유지). 누적 버퍼만
        // 비우고, 직전 확정 줄을 그대로 holdSeconds 유지한다.
        if !collapsedTranslation.isEmpty,
           !confirmedTranslation.isEmpty,
           norm(collapsedTranslation) == norm(confirmedTranslation) {
            log.debug("\(LogTag.subtitle, privacy: .public) 자막 확정 무시: 직전 확정과 동일(중복 경계) len=\(collapsedTranslation.count, privacy: .public)")
            currentTranslation = ""
            currentSource = ""
            scheduleHide()
            return
        }

        if !collapsedTranslation.isEmpty { confirmedTranslation = collapsedTranslation }
        if !collapsedSource.isEmpty { confirmedSource = collapsedSource }
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
                self.log.debug("\(LogTag.subtitle, privacy: .public) scheduleHide fire: isVisible=false 전이(holdSeconds 경과)")
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
                self.log.debug("\(LogTag.subtitle, privacy: .public) silence fallback fire: 무음 \(Self.silenceTimeout, privacy: .public)s 경과 → 자동 확정")
                self.confirmTurn(reason: .silence)
            }
        }
    }
}
