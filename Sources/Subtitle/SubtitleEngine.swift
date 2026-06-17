import Foundation
import Observation

/// 자막 누적 엔진 (스펙 §5.4, M2a 간단 버전).
///
/// Gemini는 번역/원문 텍스트를 부분(partial)으로 점진 전송하고 turnComplete로 확정한다.
/// M2a 범위는 "현재 번역문(+선택적 원문)"을 문자열로 관리해 HUD/로그에 노출하는 것까지다.
/// 영화 자막식 페이드/타이밍/큐·문장 분할(최대 2줄, 표시시간 산정)은 M3로 미룬다.
///
/// 동작:
/// - partial 텍스트가 오면 현재 줄(`liveTranslation`/`liveSource`)을 갱신한다.
///   Gemini가 동일 턴 내에서 누적 텍스트를 보내든 증분만 보내든, **부분 텍스트는 현재 줄을
///   "치환"**한다(누적 전송 가정). 빈 문자열은 무시.
/// - turnComplete가 오면 현재 줄을 확정해 `lastTranslation`/`lastSource`로 고정하고
///   live 줄을 비운다.
///
/// `@MainActor @Observable` — HUD(SwiftUI)가 직접 구독해 갱신한다.
@MainActor
@Observable
final class SubtitleEngine {

    /// 현재 진행 중(라이브) 번역 줄. 부분 텍스트로 계속 갱신된다.
    private(set) var liveTranslation: String = ""

    /// 현재 진행 중(라이브) 원문 줄. 원문 동시 표시 토글용(FR-8).
    private(set) var liveSource: String = ""

    /// 직전에 확정된 번역 줄(turnComplete). 라이브가 비었을 때 HUD가 이걸 보여준다.
    private(set) var lastTranslation: String = ""

    /// 직전에 확정된 원문 줄.
    private(set) var lastSource: String = ""

    /// HUD에 보여줄 "현재 번역문" — 라이브 우선, 없으면 마지막 확정.
    var displayTranslation: String {
        liveTranslation.isEmpty ? lastTranslation : liveTranslation
    }

    /// HUD에 보여줄 "현재 원문".
    var displaySource: String {
        liveSource.isEmpty ? lastSource : liveSource
    }

    /// 번역 텍스트 수신 처리. 부분=현재 줄 갱신, 확정=고정.
    func ingestTranslation(_ text: String, isFinal: Bool) {
        if !text.isEmpty {
            liveTranslation = text
        }
        if isFinal {
            if !liveTranslation.isEmpty {
                lastTranslation = liveTranslation
            }
            liveTranslation = ""
        }
    }

    /// 원문 텍스트 수신 처리.
    func ingestSource(_ text: String, isFinal: Bool) {
        if !text.isEmpty {
            liveSource = text
        }
        if isFinal {
            if !liveSource.isEmpty {
                lastSource = liveSource
            }
            liveSource = ""
        }
    }

    /// 세션 정지/재시작 시 누적 텍스트를 비운다.
    func reset() {
        liveTranslation = ""
        liveSource = ""
        lastTranslation = ""
        lastSource = ""
    }
}
