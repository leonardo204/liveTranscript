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

    /// 실제 렌더된 자막 박스 높이(측정값). 0이면 아직 미측정 → 추정값으로 폴백.
    /// 측정값을 쓰면 짧은 1줄 자막에서도 '하' 영역이 화면 바닥에 정확히 닿는다.
    @State private var measuredBoxHeight: CGFloat = 0

    var body: some View {
        let translation = engine.displayTranslation
        let source = engine.displaySource
        let visible = engine.isVisible && !translation.isEmpty
        // 세로 위치/오프셋/스타일 모두 @Observable settings에서 직접 읽어 실시간 반영한다.
        // (자막 텍스트가 engine @Observable로 실시간 갱신되는 것과 동일 메커니즘 — 호스팅 뷰를
        //  재생성하지 않고도 슬라이더/Picker 변경이 즉시 위치에 반영된다.)
        let verticalPosition = settings.subtitleVerticalPosition
        let style = SubtitleStyle(settings: settings)

        // GeometryReader로 화면 폭을 읽어 자막 박스의 최대 폭을 제한한다.
        // 박스가 전체 폭으로 퍼지면 긴 번역(예: 84자)이 한 줄로 나와 lineLimit이
        // 적용되지 않으므로, 박스를 화면 폭의 70%(최소 400pt)로 제한해 텍스트가
        // 자연스럽게 여러 줄로 줄바꿈되어 lineLimit(maxLines)까지 표시되게 한다.
        GeometryReader { geo in
            // 박스 최대 폭: 화면 폭의 70%, 단 너무 좁아지지 않도록 400pt 하한.
            let maxBoxWidth = max(400, geo.size.width * 0.7)

            // 화면을 상/중/하 3등분하고, 영역 안에서 offset(0~1)으로 완전 이동시킨다.
            // 전역 비율 t = (영역index + offset) / 3  →  0~1 (화면 전체 기준).
            //   상: t∈[0, 1/3]   중: t∈[1/3, 2/3]   하: t∈[2/3, 1]
            // 경계가 정확히 맞물려(상1=중0, 중1=하0) 연속적이고, 각 영역이 화면의 1/3을 담당한다.
            let regionIndex = regionIndex(for: verticalPosition)
            // @Observable이므로 슬라이더 변경 시 실시간 반영된다(0~1, 영역 내 위치).
            let offset = max(0, min(1, CGFloat(settings.subtitleVerticalOffset)))
            let t = (CGFloat(regionIndex) + offset) / 3.0
            // 이동 가능 범위(travel)를 구한다. t=0이면 박스 상단이 맨 위,
            // t=1이면 박스 하단이 맨 아래에 딱 닿는다(travel = 화면높이 - 박스높이).
            // 실제 측정 높이를 우선 사용(짧은 자막도 바닥까지 도달), 미측정 시 추정값 폴백.
            let boxHeight = measuredBoxHeight > 0
                ? measuredBoxHeight
                : estimatedBoxHeight(style: style, hasSource: settings.showSourceText && !source.isEmpty)
            let travel = max(0, geo.size.height - boxHeight)
            let topPad = travel * t

            // 세로 배치: 위쪽 Spacer로 박스 상단을 topPad만큼 내리고, 나머지는 아래로 흘린다.
            VStack(spacing: 0) {
                Spacer().frame(height: topPad)
                subtitleBox(translation: translation, source: source, style: style, maxBoxWidth: maxBoxWidth)
                    .opacity(visible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: visible)
                    .animation(.easeInOut(duration: 0.25), value: translation)
                Spacer(minLength: 0)
            }
            // 바깥 컨테이너는 화면 전체를 채우고 가로 중앙 정렬 — 박스만 maxBoxWidth로
            // 제한되어 화면 중앙(또는 정렬)에 위치한다.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        // 측정된 박스 높이를 @State에 반영 → travel 재계산(짧은 자막도 정확히 바닥 도달).
        .onPreferenceChange(SubtitleBoxHeightKey.self) { height in
            if height > 0 { measuredBoxHeight = height }
        }
        // 가로 가장자리 여백만 둔다. 세로는 '상' 맨 위/'하' 맨 아래가 모니터 끝까지
        // 닿아야 하므로 여백을 최소화(8pt)한다 — 너무 0이면 글자가 화면 끝에 붙어 가독성 저하.
        .padding(.horizontal, 60)
        .padding(.vertical, 8)
        // 창 자체는 투명 — 박스만 배경을 가진다.
        .allowsHitTesting(false)
    }

    /// 영역(상/중/하)을 0/1/2 인덱스로 변환한다. 화면을 균등 3등분하는 전역 비율 계산에 쓰인다.
    private func regionIndex(for position: SubtitleVerticalPosition) -> Int {
        switch position {
        case .top: return 0
        case .center: return 1
        case .bottom: return 2
        }
    }

    /// 박스 높이를 보수적으로 추정한다(클램프용). 실제 측정이 아닌 상한 근사.
    /// 줄수 × 폰트크기 × 1.5(줄간격 여유) + 패딩 80. 원문 표시면 추가 가산.
    private func estimatedBoxHeight(style: SubtitleStyle, hasSource: Bool) -> CGFloat {
        let lines = CGFloat(max(1, style.maxLines))
        var height = style.fontSize * lines * 1.5 + 80
        if hasSource {
            // 원문은 0.65 크기로 최대 줄수만큼 추가될 수 있어 보수적으로 더한다.
            height += style.fontSize * 0.65 * lines * 1.5
        }
        return height
    }

    @ViewBuilder
    private func subtitleBox(translation: String, source: String, style: SubtitleStyle, maxBoxWidth: CGFloat) -> some View {
        VStack(alignment: style.align.frameAlignment.horizontal, spacing: 6) {
            StyledSubtitleText(text: translation, size: style.fontSize, style: style)
            if settings.showSourceText, !source.isEmpty {
                StyledSubtitleText(text: source, size: style.fontSize * 0.65, style: style)
                    .opacity(0.85)
            }
        }
        // 박스 폭을 maxBoxWidth로 제한 → 긴 텍스트가 이 폭 안에서 줄바꿈된다.
        .frame(maxWidth: maxBoxWidth, alignment: style.align.frameAlignment)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(backgroundBox(style: style))
        .fixedSize(horizontal: false, vertical: true)
        // 실제 박스 높이를 PreferenceKey로 위로 전달(세로 배치 travel 계산용).
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SubtitleBoxHeightKey.self, value: proxy.size.height)
            }
        )
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

/// 자막 박스의 실제 렌더 높이를 부모로 전달하는 PreferenceKey.
/// 세로 위치 계산(travel = 화면높이 - 박스높이)에서 추정값 대신 실측값을 쓰기 위함.
private struct SubtitleBoxHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
