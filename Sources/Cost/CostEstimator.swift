import Foundation
import Observation

/// 비용 추정기 (스펙 §9, M2b — 태스크 C).
///
/// 통화는 **USD**(환율 환산 없음). **세션 비용**(현재 번역 세션)과 **누적 비용**(영속, 결정적)을
/// 분리해 추적한다. 제어 HUD는 세션 비용을, 설정은 누적 비용을 표시한다.
///
/// ## 비용 계산식 (스펙 §9.1)
/// - **입력 비용**(실시간·정확): GeminiLiveClient가 송신한 오디오 누적 시간(초)으로 계산.
///   `sendAudio(chunk)` 시 `chunk.count / 16000`초를 누적 → `tokens = 초 × 25` →
///   `cost = tokens / 1_000_000 × $3.50`.
/// - **출력 비용**: 서버 `usageMetadata`의 출력 오디오 토큰 누적 → `cost = tokens / 1_000_000 × $21.00`.
///   `responseTokensDetails`에서 modality=="AUDIO"의 tokenCount를 우선 사용,
///   없으면 `responseTokenCount`로 폴백한다(GeminiLiveClient가 결정해 전달).
///
/// 세션 비용은 번역 시작 시 `resetSession()`으로 0에서 시작한다. 누적 비용은 세션 중
/// 증분만큼 SettingsStore(UserDefaults)에 더해 영속화한다(결정적).
///
/// 동시성: `@MainActor @Observable` — HUD/설정 SwiftUI가 직접 구독한다. GeminiLiveClient(actor)는
/// `Task { @MainActor in ... }`로 hop해 `addSentAudio`/`addOutputTokens`를 호출한다.
@MainActor
@Observable
final class CostEstimator {

    /// 누적 비용 영속화를 위한 설정 저장소.
    @ObservationIgnored private let settings: SettingsStore?

    init(settings: SettingsStore? = nil) {
        self.settings = settings
    }

    // MARK: - 세션 누적 원시값

    /// 이번 세션에 송신한 오디오 누적 시간(초). 입력 비용의 근거(정확).
    private(set) var sessionSentSeconds: Double = 0

    /// 이번 세션에 수신한 출력 오디오 토큰 누적. 출력 비용의 근거.
    private(set) var sessionOutputTokens: Int = 0

    // MARK: - 세션 비용(USD)

    /// 세션 입력 비용(USD) = 송신 초 × 25 tok/s / 1M × $3.50.
    var sessionInputUSD: Double {
        let tokens = sessionSentSeconds * AppConfig.costAudioTokensPerSecond
        return tokens / 1_000_000.0 * AppConfig.costInputUSDPerMillionTokens
    }

    /// 세션 출력 비용(USD) = 출력 토큰 / 1M × $21.00.
    var sessionOutputUSD: Double {
        Double(sessionOutputTokens) / 1_000_000.0 * AppConfig.costOutputUSDPerMillionTokens
    }

    /// 세션 총 비용(USD) = 입력 + 출력.
    var sessionTotalUSD: Double {
        sessionInputUSD + sessionOutputUSD
    }

    // MARK: - 누적 비용(USD, 영속)

    /// 누적 입력 비용(USD).
    var cumulativeInputUSD: Double {
        settings?.cumulativeInputUSD ?? 0
    }

    /// 누적 출력 비용(USD).
    var cumulativeOutputUSD: Double {
        settings?.cumulativeOutputUSD ?? 0
    }

    /// 누적 총 비용(USD).
    var cumulativeTotalUSD: Double {
        cumulativeInputUSD + cumulativeOutputUSD
    }

    // MARK: - 세션 수명

    /// 번역 시작 시 세션 비용을 0에서 시작한다(누적은 유지).
    func resetSession() {
        sessionSentSeconds = 0
        sessionOutputTokens = 0
    }

    /// 누적 비용을 0으로 초기화한다(설정 "누적 리셋").
    func resetCumulative() {
        settings?.resetCumulativeCost()
    }

    // MARK: - 입력(송신 오디오 시간 누적)

    /// 송신한 오디오 청크 길이로 입력 누적 시간을 더한다(스펙 §9.4 — 정확한 입력 비용).
    /// - Parameter sampleCount: 송신 청크의 16kHz mono 샘플 수.
    func addSentAudio(sampleCount: Int) {
        guard sampleCount > 0 else { return }
        let seconds = Double(sampleCount) / AppConfig.audioSampleRate
        let beforeInput = sessionInputUSD
        sessionSentSeconds += seconds
        let deltaInput = sessionInputUSD - beforeInput
        if deltaInput > 0 { settings?.cumulativeInputUSD += deltaInput }
    }

    // MARK: - 출력(usageMetadata 토큰 누적)

    /// 서버 usageMetadata로부터 이 응답의 출력 오디오 토큰을 누적한다.
    /// GeminiLiveClient가 `responseTokensDetails`(AUDIO) 우선, 없으면 `responseTokenCount`로
    /// 결정한 "이번 메시지의 출력 토큰 수"를 전달한다.
    /// - Parameter tokens: 이번 usageMetadata가 보고한 출력 오디오 토큰 수.
    func addOutputTokens(_ tokens: Int) {
        guard tokens > 0 else { return }
        let beforeOutput = sessionOutputUSD
        sessionOutputTokens += tokens
        let deltaOutput = sessionOutputUSD - beforeOutput
        if deltaOutput > 0 { settings?.cumulativeOutputUSD += deltaOutput }
    }
}
