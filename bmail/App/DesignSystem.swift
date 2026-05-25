/// DesignSystem.swift — bmail Liquid Glass design system foundation.
///
/// Phase 1: tokens, materials, modifiers, and components for the iOS 18+
/// Liquid Glass visual language. Views in bmail/Views/ still use the legacy
/// Theme.swift primitives; subsequent migration passes will adopt DS.* APIs.
///
/// See: bmail/App/Theme.swift (legacy API — do not delete until migration done)

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Tokens

/// Top-level namespace for every design-system constant.
///
/// Usage:
/// ```swift
/// .cornerRadius(DS.Radius.card, antialiased: true)
/// .padding(DS.Space.l)
/// ```
enum DS {

    // MARK: Radii
    /// Corner radius constants. Always pair with `.continuous` (`squircle`) style.
    enum Radius {
        /// Small controls: chips, tags, segmented segments.
        static let chip:   CGFloat =  9
        /// Buttons, inputs, segmented container.
        static let button: CGFloat = 12
        /// Standard cards and list rows.
        static let card:   CGFloat = 16
        /// Sheet tops and large cards.
        static let sheet:  CGFloat = 22
        /// Hero surfaces and full-screen covers.
        static let hero:   CGFloat = 28
    }

    // MARK: Spacing
    /// Spacing constants aligned to the 4pt baseline grid.
    enum Space {
        static let xs:  CGFloat =  4
        static let s:   CGFloat =  8
        static let m:   CGFloat = 12
        static let l:   CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Row heights
    /// Canonical row heights per HIG multi-line row guidance.
    enum RowHeight {
        /// Single-line row (label only).
        static let single: CGFloat = 56
        /// Two-line row (label + subtitle).
        static let double: CGFloat = 72
        /// Three-line row (label + subtitle + meta).
        static let triple: CGFloat = 88
    }

    // MARK: Colors
    /// Semantic color aliases that map to the closest iOS system color.
    /// Prefer SwiftUI's `.primary`, `.secondary`, `Color(.tertiaryLabel)`
    /// at call sites when possible; use these for explicit typing or
    /// contexts that need a named constant.
    enum Color {
        /// Maps to `SwiftUI.Color.primary` — headings, primary body text.
        static var ink:      SwiftUI.Color { .primary }
        /// Maps to `SwiftUI.Color.secondary` — snippets, helper text.
        static var inkMuted: SwiftUI.Color { .secondary }
        /// Maps to `Color(.tertiaryLabel)` — timestamps, eyebrows, disabled.
        static var inkFaint: SwiftUI.Color { SwiftUI.Color(.tertiaryLabel) }
    }
}

// MARK: - Material semantic aliases

extension Material {
    /// Background for cards and list rows. Equivalent to `.regularMaterial`.
    static var dsCard: Material    { .regularMaterial }
    /// Floating chrome (tab bar, search header strips). Equivalent to `.bar`.
    static var dsBar: Material     { .bar }
    /// Modal sheet background — content behind recedes. Equivalent to `.thickMaterial`.
    static var dsSheet: Material   { .thickMaterial }
    /// Toast overlays, popovers. Equivalent to `.ultraThinMaterial`.
    static var dsOverlay: Material { .ultraThinMaterial }
}

// MARK: - Font helpers

extension Font {
    /// Monospaced Dynamic Type style. Use for addresses, hashes, and tokens.
    ///
    /// Uses SF Mono (the system monospaced typeface on iOS) — no third-party
    /// font installation needed.
    ///
    /// ```swift
    /// Text(address)
    ///     .font(.dsMono(.body))
    ///     .foregroundStyle(.secondary)
    /// ```
    static func dsMono(
        _ style: Font.TextStyle = .body,
        weight: Font.Weight = .regular
    ) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }
}

// MARK: - Wallpaper

/// Warm cream wallpaper with sage and amber radial gradients.
///
/// Sits behind glass content on Inbox, Thread, and Settings root so that
/// materials have something interesting to refract. Adapts to dark mode:
/// the base becomes charcoal and gradient opacities are reduced.
///
/// ```swift
/// ZStack {
///     Wallpaper()
///     contentView
/// }
/// ```
struct Wallpaper: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            // Base
            if dark {
                Color(white: 0.10)
            } else {
                Color(.systemBackground)
            }

            // Sage — top right
            RadialGradient(
                colors: [
                    Color(red: 0.49, green: 0.66, blue: 0.52)
                        .opacity(dark ? 0.18 : 0.28),
                    .clear
                ],
                center: UnitPoint(x: 0.80, y: 0.12),
                startRadius: 0,
                endRadius: 320
            )

            // Amber — bottom left
            RadialGradient(
                colors: [
                    Color(red: 0.79, green: 0.64, blue: 0.44)
                        .opacity(dark ? 0.15 : 0.22),
                    .clear
                ],
                center: UnitPoint(x: 0.12, y: 0.88),
                startRadius: 0,
                endRadius: 320
            )

            // Cool-indigo centre tint
            RadialGradient(
                colors: [
                    Color(red: 0.52, green: 0.56, blue: 0.72)
                        .opacity(dark ? 0.12 : 0.18),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 280
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - GlassCard

/// A `.regularMaterial` card with continuous corner rounding and the
/// iOS-spec 0.5px inset specular highlight.
///
/// Place inside scroll content. Apply external padding using `DS.Space.l`.
///
/// ```swift
/// GlassCard {
///     VStack { /* row content */ }
/// }
/// .padding(.horizontal, DS.Space.l)
/// ```
struct GlassCard<Content: View>: View {
    var radius: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        radius: CGFloat = DS.Radius.card,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.radius = radius
        self.content = content
    }

    var body: some View {
        content()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .glassEdge(radius: radius)
    }
}

// MARK: - View Modifiers

// MARK: GlassCardModifier
private struct GlassCardModifier: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .glassEdge(radius: radius)
    }
}

// MARK: GlassEdgeModifier
private struct GlassEdgeModifier: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(.white.opacity(0.55), lineWidth: 0.5)
                .blendMode(.softLight)
        )
    }
}

// MARK: EncryptionPillModifier
private struct EncryptionPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "lock.fill")
                .font(.caption2)
            content
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .foregroundStyle(Color.accentColor)
    }
}

extension View {
    /// Wraps the receiver in a `.regularMaterial` card with continuous
    /// squircle corners and the specular edge highlight.
    func glassCard(radius: CGFloat = DS.Radius.card) -> some View {
        modifier(GlassCardModifier(radius: radius))
    }

    /// Applies the 0.5px white inset highlight that imitates Apple's
    /// specular detail on hand-rolled glass surfaces.
    ///
    /// Skip if the surface is already a system material — system materials
    /// draw this automatically.
    func glassEdge(radius: CGFloat) -> some View {
        modifier(GlassEdgeModifier(radius: radius))
    }

    /// Wraps the receiver inside an encryption-pill layout: lock glyph on
    /// leading, accent-soft capsule background.
    func encryptionPill() -> some View {
        modifier(EncryptionPillModifier())
    }
}

// MARK: - DSSectionHeader

/// Compact, hairline-separated section header for grouped lists.
///
/// Displays the title in sentence-case caption style with optional
/// trailing accessory. Replaces the legacy uppercase mono section header.
struct DSSectionHeader: View {
    let title: String
    let trailing: AnyView?

    init(_ title: String, trailing: AnyView? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(DS.Color.inkFaint)
                .textCase(nil)

            Spacer()

            trailing
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.xs)
    }
}

// MARK: - DSRow

/// A row primitive for grouped Form-style lists.
///
/// 44pt minimum height; leading icon slot (optional); title with optional
/// subtitle; trailing accessory (chevron, value string, or custom view).
///
/// ```swift
/// DSRow(
///     icon: "person.fill",
///     title: "Display name",
///     subtitle: nil
/// ) {
///     Text("Christopher").foregroundStyle(.secondary)
/// }
/// ```
struct DSRow<Trailing: View>: View {
    let icon: String?
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(
        icon: String? = nil,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            if let icon {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            trailing()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.l)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension DSRow where Trailing == EmptyView {
    /// Convenience initialiser for rows with no trailing accessory.
    init(icon: String? = nil, title: String, subtitle: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - DSAvatar

/// Avatar in the bmail style: monogram on a deep-sage circle.
///
/// Three HIG-aligned sizes:
/// - `.table` (28pt) — for tab bars and compact contexts
/// - `.row` (36pt) — for list rows (default)
/// - `.header` (56pt) — for thread and profile headers
struct DSAvatar: View {
    enum Size: CGFloat {
        case table  = 28
        case row    = 36
        case header = 56
    }

    let initials: String
    var size: Size = .row

    var body: some View {
        Text(initials.prefix(2).uppercased())
            .font(.system(size: size.rawValue * 0.36, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size.rawValue, height: size.rawValue)
            .background(Color(red: 0.36, green: 0.48, blue: 0.42), in: Circle())
    }
}

// MARK: - DSEncryptionPill

/// Encryption indicator pill: sage-soft background, lock glyph + label.
///
/// Used in compose headers, sender identity headers, and thread title bars.
/// Always carry a meaningful accessibility label so VoiceOver doesn't
/// read "lock" and "encrypted" separately.
///
/// ```swift
/// DSEncryptionPill()
///     .accessibilityLabel("End-to-end encrypted")
/// ```
struct DSEncryptionPill: View {
    var label: String = "encrypted"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.caption2)
            Text(label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel("End-to-end encrypted")
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - DSIconButton

/// SF Symbols-only tap target with a proper 44pt hit area and an
/// accessibility label. Use wherever a bare symbol would be tappable.
///
/// ```swift
/// DSIconButton(systemName: "square.and.pencil", label: "Compose") {
///     showCompose = true
/// }
/// ```
struct DSIconButton: View {
    let systemName: String
    let label: String
    var font: Font = .body
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(font)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - DSEmptyState

/// Standard empty-state: large SF Symbol + title + optional explanatory hint.
///
/// ```swift
/// DSEmptyState(
///     systemName: "tray",
///     title: "No messages",
///     hint: "New encrypted mail will appear here."
/// )
/// ```
struct DSEmptyState: View {
    let systemName: String
    let title: String
    var hint: String? = nil

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: systemName)
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(DS.Color.inkFaint)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: DS.Space.xs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                if let hint {
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Space.xxl)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.xxl)
    }
}

// MARK: - DSHaptics

/// Centralised haptic feedback helpers.
///
/// Call sites should request feedback at the semantic level — don't pick
/// a style to match a competitor app, pick the one that fits the action.
///
/// | Action                  | Call                        |
/// |-------------------------|-----------------------------|
/// | Tab switch              | `selection()`               |
/// | Toggle on/off           | `impactLight()`             |
/// | Swipe-to-archive        | `impactMedium()`            |
/// | Successful send         | `notifySuccess()`           |
/// | Destructive confirm     | `notifyWarning()`           |
enum DSHaptics {
    /// Lightweight selection tick. Use for tab switches and picker changes.
    static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }

    /// Light physical impact. Use for toggles and small confirmations.
    static func impactLight() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
    }

    /// Medium physical impact. Use for swipe actions and drag drops.
    static func impactMedium() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        g.impactOccurred()
    }

    /// Success notification pulse. Use after a message sends successfully.
    static func notifySuccess() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
    }

    /// Warning notification pulse. Use before destructive confirmations.
    static func notifyWarning() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.warning)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Wallpaper") {
    Wallpaper()
}

#Preview("DSEncryptionPill") {
    VStack(spacing: DS.Space.l) {
        DSEncryptionPill()
        DSEncryptionPill(label: "end-to-end encrypted")
    }
    .padding()
    .background(Wallpaper())
}

#Preview("GlassCard") {
    GlassCard {
        VStack(spacing: 0) {
            DSRow(icon: "person.fill", title: "Display name") {
                Text("Christopher").foregroundStyle(.secondary)
            }
            Divider().padding(.leading, DS.Space.l)
            DSRow(icon: "at", title: "Address") {
                Text("cw@bmail.app")
                    .font(.dsMono(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(DS.Space.l)
    .background(Wallpaper())
}

#Preview("DSRow + DSSectionHeader") {
    VStack(spacing: 0) {
        DSSectionHeader("Identity")
        GlassCard {
            DSRow(icon: "person.fill", title: "Name", subtitle: "Christopher Wong") {
                Image(systemName: "chevron.right").font(.caption)
            }
        }
        .padding(.horizontal, DS.Space.l)
    }
    .background(Wallpaper())
}
#endif
