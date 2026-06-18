import SwiftUI

/// 자막 HUD 본문 뷰 (스펙 §5.3 / §5.4 / §5.5, M3 + M4).
///
/// `SubtitleEngine`의 현재 번역문(+설정 시 원문)을 영화 자막처럼 그린다.
/// - 화면 하단(또는 설정 위치) 정렬, 가독성을 위한 외곽선/그림자(스펙 §5.3 — drop shadow).
/// - **페이드 인/아웃**: `engine.isVisible` 전이 + 텍스트 변경을 `.animation`으로 ~0.25s 보간.
///
/// M4 구현: `SubtitleStyle` 기반 폰트/색/글로우/배경/정렬/줄수 반영. 렌더링은 설정
/// 미리보기와 동일한 `StyledSubtitleText`를 공유해 "미리보기=실제"를 보장한다.
struct SubtitleOverlayView: View {
    var engine: SubtitleEngine
    var settings: SettingsStore
    /// 자막 세로 위치(위/중앙/아래) — 컨테이너 정렬에 사용.
    var verticalPosition: SubtitleVerticalPosition

    var body: some View {
        let translation = engine.displayTranslation
        let source = engine.displaySource
        let visible = engine.isVisible && !translation.isEmpty
        // @Observable이므로 settings 값을 읽는 즉시 실시간 반영된다.
        let style = SubtitleStyle(settings: settings)

        VStack {
            if verticalPosition != .top { Spacer(minLength: 0) }
            subtitleBox(translation: translation, source: source, style: style)
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
    private func subtitleBox(translation: String, source: String, style: SubtitleStyle) -> some View {
        VStack(alignment: style.align.frameAlignment.horizontal, spacing: 6) {
            StyledSubtitleText(text: translation, size: style.fontSize, style: style)
            if settings.showSourceText, !source.isEmpty {
                StyledSubtitleText(text: source, size: style.fontSize * 0.65, style: style)
                    .opacity(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: style.align.frameAlignment)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(backgroundBox(style: style))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 배경 박스(켜져 있을 때만 반투명 검정). 꺼지면 배경 없음.
    @ViewBuilder
    private func backgroundBox(style: SubtitleStyle) -> some View {
        if style.backgroundEnabled {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(style.backgroundOpacity))
        } else {
            Color.clear
        }
    }
}

private extension Alignment {
    /// VStack(alignment:)에 쓸 가로 정렬 추출.
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }
}
