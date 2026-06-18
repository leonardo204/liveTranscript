import SwiftUI

/// 제어 HUD(상시 플로팅) SwiftUI 내용 (M3 — 기존 모니터 HUD 재구성).
///
/// 피드백 #1: 번역문/원문 표시를 **제거**하고, 캡처 상태/입력 레벨/VAD/입력 소스/VAD 모델
/// 상태만 보여주는 "제어 HUD"로 정리한다(번역문은 별도 자막 HUD로 분리).
/// 피드백 #4: **시작/정지 토글 버튼**과 **설정 진입 버튼**을 추가한다.
///
/// 표시 항목: ① 캡처 상태 ② VAD 발화 인디케이터 ③ 입력 레벨 미터 ④ 입력 소스명/VAD 모델
/// ⑤ 시작·정지 / 설정 컨트롤.
///
/// `AudioInputManager`의 `@Observable` 값을 구독하고, 컨트롤은 `AppState`의 액션을 호출한다.
struct MonitorHUD: View {
    /// 시작/정지·설정 액션을 위해 앱 상태를 직접 참조한다.
    var appState: AppState

    private var audio: AudioInputManager { appState.audio }

    /// 비용 행 표시 여부(설정 토글, 태스크 C). off면 행 숨김 + HUD 높이 축소.
    private var showCost: Bool { appState.settings.costHUDEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            levelMeter
            footer
            if showCost {
                costRow
            }
            Divider().opacity(0.2)
            controls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 260, height: showCost ? 176 : 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // 상단: "제어 HUD" 타이틀 + 캡처 상태 + VAD 발화 인디케이터.
    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(audio.isCapturing ? Color.red : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(audio.isCapturing ? "캡처중" : "정지")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            speakingIndicator
        }
    }

    // VAD 발화 인디케이터: 발화중 ● 초록 / 무음 ○ 회색.
    private var speakingIndicator: some View {
        let active = audio.isCapturing && audio.vadEnabled && audio.isSpeaking
        return HStack(spacing: 3) {
            Image(systemName: active ? "circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(active ? Color.green : Color.secondary)
            Text(active ? "발화" : "무음")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // 입력 레벨 미터(부드러운 바).
    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(meterColor)
                    .frame(width: max(2, geo.size.width * CGFloat(clampedLevel)))
                    .animation(.linear(duration: 0.08), value: clampedLevel)
            }
        }
        .frame(height: 6)
    }

    private var clampedLevel: Float {
        guard audio.isCapturing else { return 0 }
        return max(0, min(audio.level, 1))
    }

    private var meterColor: Color {
        let l = clampedLevel
        if l > 0.85 { return .red }
        if l > 0.6 { return .orange }
        return .green
    }

    // 하단: 입력 소스명 + VAD 모델 상태 + 번역 연결 상태.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(audio.activeSourceLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(audio.vadEnabled ? audio.vadStatus.menuLabel : "VAD 꺼짐")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            if appState.apiKeyLoaded {
                Text("번역: \(appState.geminiStatus)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // 키 없음: 눈에 띄는 경고로 노출(설정으로 유도).
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("API 키 없음 — 설정에서 입력")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
    }

    // 세션 비용 행(태스크 C, 스펙 §9.4): 전송/수신/총 $ (USD). 작은 값이라 소수 4자리.
    private var costRow: some View {
        let cost = appState.cost
        return HStack(spacing: 6) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text("전송 \(usd(cost.sessionInputUSD))")
            Text("수신 \(usd(cost.sessionOutputUSD))")
            Text("총 \(usd(cost.sessionTotalUSD))")
                .fontWeight(.semibold)
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// USD 금액을 작은 값에 맞춰 $0.0000 형식으로 포맷한다(소수 4자리).
    private func usd(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }

    // 컨트롤: 시작/정지 토글 + 설정 진입 (피드백 #4).
    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                appState.toggleCapture()
            } label: {
                HStack(spacing: 4) {
                    // 버튼 상태는 세션 단일 진실(`isRunning`)을 따른다 — 입력 소스 hot-swap
                    // 재시작 실패로 audio.isCapturing이 일시적으로 false가 돼도 "정지"가
                    // "시작"으로 뒤집히지 않는다(상태 불일치/오작동 방지).
                    Image(systemName: appState.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 9))
                    Text(appState.isRunning ? "정지" : "시작")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.isRunning ? .red : .accentColor)

            Button {
                appState.openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .help("설정 열기")
        }
    }
}
