import SwiftUI
import AppKit

/// 자막 스타일 영속화/렌더링 모델 (스펙 §5.5 / FR-7, M4).
///
/// 설정창의 스타일 값을 해석한 `SubtitleStyle` 묶음과, 자막 오버레이·설정 미리보기가
/// **동일하게** 사용하는 렌더링 뷰(`StyledSubtitleText`)를 제공한다(미리보기=실제 보장).
/// 색은 UserDefaults에 sRGB 8bit "#RRGGBBAA" 문자열로 결정적으로 저장한다(Date/난수 없음).

// MARK: - Color ↔ hex 영속화 헬퍼

extension Color {
    /// "#RRGGBBAA" 문자열에서 생성. 파싱 실패 시 fallback. (UserDefaults 영속용)
    init(hexRGBA: String, fallback: Color) {
        let s = hexRGBA.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard s.count == 8, let v = UInt64(s, radix: 16) else { self = fallback; return }
        let r = Double((v & 0xFF000000) >> 24) / 255
        let g = Double((v & 0x00FF0000) >> 16) / 255
        let b = Double((v & 0x0000FF00) >> 8) / 255
        let a = Double(v & 0x000000FF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// sRGB 8bit "#RRGGBBAA"로 직렬화. (실패 시 불투명 흰색)
    func toHexRGBA() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        let a = Int((ns.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}

// MARK: - 두께 enum

/// 자막 글자 두께(영속 raw + 한글 라벨 + Font.Weight 매핑).
enum SubtitleFontWeight: String, CaseIterable, Identifiable {
    case regular, medium, semibold, bold, heavy, black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .regular: return "보통"
        case .medium: return "중간"
        case .semibold: return "약간 굵게"
        case .bold: return "굵게"
        case .heavy: return "매우 굵게"
        case .black: return "최대"
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

// MARK: - 정렬 enum

/// 자막 가로 정렬(영속 raw + 한글 라벨 + SwiftUI 정렬 매핑).
enum SubtitleTextAlign: String, CaseIterable, Identifiable {
    case leading, center, trailing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leading: return "왼쪽"
        case .center: return "가운데"
        case .trailing: return "오른쪽"
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - 해석된 스타일 묶음

/// 설정(`SettingsStore`)의 개별 스타일 값을 렌더링에 바로 쓸 형태로 해석한 묶음.
struct SubtitleStyle {
    var fontName: String          // "" → 시스템 rounded
    var fontSize: CGFloat
    var weight: Font.Weight
    var textColor: Color
    var strokeEnabled: Bool
    var strokeColor: Color
    var glowEnabled: Bool
    var glowColor: Color
    var glowRadius: CGFloat
    var backgroundEnabled: Bool
    var backgroundOpacity: Double
    var align: SubtitleTextAlign
    var maxLines: Int

    @MainActor
    init(settings: SettingsStore) {
        self.fontName = settings.subtitleFontName
        self.fontSize = CGFloat(settings.subtitleFontSize)
        self.weight = settings.subtitleFontWeight.fontWeight
        self.textColor = settings.subtitleTextColor
        self.strokeEnabled = settings.subtitleStrokeEnabled
        self.strokeColor = settings.subtitleStrokeColor
        self.glowEnabled = settings.subtitleGlowEnabled
        self.glowColor = settings.subtitleGlowColor
        self.glowRadius = CGFloat(settings.subtitleGlowRadius)
        self.backgroundEnabled = settings.subtitleBackgroundEnabled
        self.backgroundOpacity = settings.subtitleBackgroundOpacity
        self.align = settings.subtitleTextAlign
        self.maxLines = settings.subtitleMaxLines
    }

    /// 지정 크기로 폰트 생성(fontName 비면 시스템 rounded).
    func font(size: CGFloat) -> Font {
        if fontName.isEmpty { return .system(size: size, weight: weight, design: .rounded) }
        return Font.custom(fontName, size: size).weight(weight)
    }
}

// MARK: - 공유 렌더링 뷰 (오버레이 = 미리보기)

/// 외곽선/그림자·글로우를 적용한 자막 텍스트.
/// **자막 오버레이와 설정 미리보기가 동일하게 사용**해 "미리보기=실제"를 보장한다.
struct StyledSubtitleText: View {
    let text: String
    let size: CGFloat
    let style: SubtitleStyle
    /// 줄수 제한 오버라이드. nil이면 `style.maxLines`(delta/Gemini 기본). roll-up(세그먼트) 모드는
    /// 여러 확정 문장이 각자 줄바꿈될 수 있어 더 큰 값을 넘긴다(.head 절단으로 오래된 줄부터 밀려남).
    var lineLimitOverride: Int? = nil

    var body: some View {
        // modifier 체이닝의 타입 추론 부담을 줄이기 위해 단계적 변수 + 조건 분기로 처리.
        let base = Text(text)
            .font(style.font(size: size))
            .foregroundStyle(style.textColor)
            .multilineTextAlignment(style.align.textAlignment)
            .lineLimit(lineLimitOverride ?? style.maxLines)
            .truncationMode(.head)

        return base
            .modifier(StrokeShadowModifier(enabled: style.strokeEnabled, color: style.strokeColor))
            .modifier(GlowModifier(enabled: style.glowEnabled, color: style.glowColor, radius: style.glowRadius))
    }
}

/// 외곽선 느낌의 다중 그림자(반경 1/3/6). 기존 SubtitleOverlayView의 질감을 유지하되
/// 색만 strokeColor로 바꾼다. 꺼지면 미적용.
private struct StrokeShadowModifier: ViewModifier {
    let enabled: Bool
    let color: Color

    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: color.opacity(0.9), radius: 1, x: 0, y: 0)
                .shadow(color: color.opacity(0.8), radius: 3, x: 0, y: 1)
                .shadow(color: color.opacity(0.6), radius: 6, x: 0, y: 2)
        } else {
            content
        }
    }
}

/// 은은한 글로우(blur shadow 2겹: radius, radius*1.6). 꺼지면 미적용.
private struct GlowModifier: ViewModifier {
    let enabled: Bool
    let color: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: color, radius: radius, x: 0, y: 0)
                .shadow(color: color, radius: radius * 1.6, x: 0, y: 0)
        } else {
            content
        }
    }
}
