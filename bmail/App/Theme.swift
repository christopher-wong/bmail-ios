import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum Theme {
    static let ink = Color.primary
    static let mute = Color.secondary
    /// Hairline color. In `.increaseContrast` and AX-large text sizes we
    /// brighten it; default is the same soft 18% black that matches the web.
    static func hairline(for environment: EnvironmentValues) -> Color {
        environment.colorSchemeContrast == .increased
            ? Color.primary.opacity(0.45)
            : Color.primary.opacity(0.18)
    }
    static let hairline = Color.primary.opacity(0.18)
#if canImport(UIKit)
    static let inverseInk = Color(uiColor: .systemBackground)
#else
    static let inverseInk = Color.white
#endif
    static let inverseBg = Color.primary
}

extension Font {
    /// Semantic-style monospaced font — scales with Dynamic Type. Prefer
    /// this overload for new code.
    static func mono(_ style: TextStyle, weight: Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    /// Legacy fixed-point overload kept for compatibility. The CGFloat is
    /// mapped to the nearest `TextStyle` so existing call sites still
    /// respect the user's Dynamic Type setting — values aren't pinned to
    /// raw points anymore.
    static func mono(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .system(textStyle(forApproximatePoints: size), design: .monospaced, weight: weight)
    }

    static var monoLabel: Font { .mono(.caption2) }
    static var monoBody: Font { .mono(.body) }
    static var monoLead: Font { .mono(.callout, weight: .medium) }
    static var monoHeading: Font { .mono(.largeTitle) }

    private static func textStyle(forApproximatePoints size: CGFloat) -> TextStyle {
        // Default-size point sizes for each TextStyle (iOS HIG defaults):
        // caption2 11 · caption 12 · footnote 13 · subheadline 15 · body 17 ·
        // callout 16 · headline 17 · title3 20 · title2 22 · title 28 · largeTitle 34.
        // The mapping below picks the closest semantic that preserves the
        // intended visual hierarchy from when the design used raw points.
        switch size {
        case ..<11:    return .caption2
        case 11..<12:  return .caption
        case 12..<13:  return .footnote
        case 13..<15:  return .subheadline
        case 15..<17:  return .callout
        case 17..<20:  return .headline
        case 20..<25:  return .title3
        case 25..<32:  return .title2
        case 32..<40:  return .title
        default:       return .largeTitle
        }
    }
}

struct Hairline: View {
    @Environment(\.self) private var env
    var axis: Axis = .horizontal
    var body: some View {
        Rectangle()
            .fill(Theme.hairline(for: env))
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

struct MonoLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.monoLabel)
            .textCase(.lowercase)
            .tracking(0.6)
            .foregroundStyle(Theme.mute)
    }
}

struct MonoButton: ViewModifier {
    var prominent: Bool = false
    var disabled: Bool = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return content
            .font(.mono(.footnote, weight: .medium))
            .textCase(.uppercase)
            .tracking(0.8)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(prominent ? Theme.inverseInk : Theme.ink)
            .background(prominent ? AnyShapeStyle(Theme.inverseBg) : AnyShapeStyle(Color.clear), in: shape)
            .overlay(shape.stroke(prominent ? Color.clear : Theme.hairline, lineWidth: 1))
            // Meet Apple's 44pt minimum tap-target recommendation.
            .frame(minHeight: 44)
            .contentShape(shape)
            .opacity(disabled ? 0.4 : 1)
    }
}

extension View {
    func monoLabel() -> some View { modifier(MonoLabel()) }
    func monoButton(prominent: Bool = false, disabled: Bool = false) -> some View {
        modifier(MonoButton(prominent: prominent, disabled: disabled))
    }
}
