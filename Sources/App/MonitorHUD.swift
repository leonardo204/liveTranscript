import SwiftUI

/// 미니 HUD(상시 플로팅 모니터)의 SwiftUI 내용 (M1.5 피드백 #1).
///
/// 메뉴를 열지 않아도 캡처 상태를 한눈에 볼 수 있도록 작은 패널에 실시간으로 그린다.
/// 표시 항목: ① 캡처 상태 ② 입력 레벨 미터(부드러운 바) ③ VAD 발화 인디케이터
/// ④ 현재 입력 소스명 ⑤ VAD 모델 상태.
///
/// `AudioInputManager`의 `@Observable` 값(`level`/`isSpeaking`/`vadStatus`/`isCapturing`/
/// `activeSourceLabel`)을 직접 구독해 갱신한다. 레벨은 값 바인딩만으로 부드럽게 반영하고,
/// `animation`으로 바를 매끄럽게 보간한다(과한 재드로우 없이).
struct MonitorHUD: View {
    var audio: AudioInputManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            levelMeter
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 220, height: 90, alignment: .topLeading)
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

    // 상단: 캡처 상태 + VAD 발화 인디케이터.
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

    // 하단: 입력 소스명 + VAD 모델 상태.
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
        }
    }
}
