import SwiftUI

/// 자막 HUD 본문 뷰 (스펙 §5.3 / §5.4, M3).
///
/// `SubtitleEngine`의 현재 번역문(+설정 시 원문)을 영화 자막처럼 그린다.
/// - 화면 하단(또는 설정 위치) 중앙 정렬, 큰 흰색 굵은 글씨.
/// - 어떤 배경에서도 읽히도록 **외곽선/그림자**를 다중 적용(스펙 §5.3 — drop shadow).
/// - 은은한 반투명 배경 박스(옵션 느낌의 기본값) — 밝은 배경 위 가독성 보조.
/// - **페이드 인/아웃**: `engine.isVisible` 전이 + 텍스트 변경을 `.animation`으로 ~0.25s 보간.
///
/// 상세 스타일(폰트/색/글로우 풀세트)은 M4 — 여기선 **기본 스타일**만.
struct SubtitleOverlayView: View {
    var engine: SubtitleEngine
    var settings: SettingsStore
    /// 자막 세로 위치(위/중앙/아래) — 컨테이너 정렬에 사용.
    var verticalPosition: SubtitleVerticalPosition

    /// 기본 자막 폰트 크기(M4에서 설정화).
    private static let fontSize: CGFloat = 34
    /// 원문 폰트 크기(번역문보다 작게).
    private static let sourceFontSize: CGFloat = 22

    var body: some View {
        let translation = engine.displayTranslation
        let source = engine.displaySource
        let visible = engine.isVisible && !translation.isEmpty

        VStack {
            if verticalPosition != .top { Spacer(minLength: 0) }
            subtitleBox(translation: translation, source: source)
                .opacity(visible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: visible)
                .animation(.easeInOut(duration: 0.25), value: translation)
            if verticalPosition != .bottom { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 화면 가장자리 여백.
        .padding(.horizontal, 60)
        .padding(.vertical, 48)
        // 창 자체는 투명 — 박스만 배경을 가진다.
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func subtitleBox(translation: String, source: String) -> some View {
        VStack(spacing: 6) {
            subtitleText(translation, size: Self.fontSize, weight: .bold)
            if settings.showSourceText, !source.isEmpty {
                subtitleText(source, size: Self.sourceFontSize, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            // 은은한 반투명 배경 박스(기본). 밝은 배경 위 가독성 보조.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 외곽선/그림자를 적용한 자막 텍스트(어떤 배경에도 읽히게).
    private func subtitleText(_ text: String, size: CGFloat, weight: Font.Weight) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.head)
            // 다중 그림자로 외곽선 느낌 + 가독성(스펙 §5.3 drop shadow). 글로우 풀세트는 M4.
            .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 0)
            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
            .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
    }
}
