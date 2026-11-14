import AppKit
import SwiftUI

/// Hosting view that never paints an opaque window fill, so AppKit glass can show through.
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

/// Liquid Glass on macOS 26+, with material / fill fallbacks on earlier OS versions.
enum LiquidGlass {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    /// Wraps a SwiftUI hosting view so a floating panel samples the desktop
    /// through `NSGlassEffectView` on macOS 26+. Older systems keep the hosting
    /// view as-is; SwiftUI supplies an opaque fill instead.
    @MainActor
    static func embed(_ hosting: NSView, cornerRadius: CGFloat) -> NSView {
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.autoresizingMask = [.width, .height]

        guard #available(macOS 26.0, *) else {
            hosting.layer?.cornerRadius = cornerRadius
            hosting.layer?.cornerCurve = .continuous
            hosting.layer?.masksToBounds = true
            return hosting
        }

        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.style = .regular
        glass.frame = hosting.frame
        hosting.frame = glass.bounds
        withoutImplicitAnimation {
            glass.contentView = hosting
        }
        return glass
    }

    @MainActor
    static func applyWindowShape(_ view: NSView?, cornerRadius: CGFloat) {
        guard let view else { return }
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            return
        }
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }

    @MainActor
    private static func withoutImplicitAnimation(_ body: () -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            body()
        }
    }
}

enum LiquidGlassKind {
    case regular
    case clear
    case interactive
    case tinted(Color)
    case tintedInteractive(Color)

    @available(macOS 26.0, *)
    var native: Glass {
        switch self {
        case .regular: .regular
        case .clear: .clear
        case .interactive: .regular.interactive()
        case .tinted(let color): .regular.tint(color)
        case .tintedInteractive(let color): .regular.tint(color).interactive()
        }
    }
}

/// Merges nearby glass controls on macOS 26+; identity on earlier OS versions.
struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

enum LiquidGlassMetrics {
    static let panelOpacity: CGFloat = 0.6
    static let controlFillOpacity: CGFloat = 0.10
    static let panelRadius: CGFloat = 24
    static let iconButtonSize: CGFloat = 36
    static let iconRadius: CGFloat = 12
    static let iconFont: CGFloat = 15
    static let pillPaddingH: CGFloat = 14
    static let pillPaddingV: CGFloat = 9
}

private struct LiquidGlassModifier<S: Shape, F: ShapeStyle>: ViewModifier {
    var kind: LiquidGlassKind
    var shape: S
    var fallback: F

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(Color.primary.opacity(LiquidGlassMetrics.controlFillOpacity), in: shape)
                .glassEffect(kind.native, in: shape)
        } else {
            content.background(fallback, in: shape)
        }
    }
}

private struct ClipwordPanelBackground: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(panelFill, in: shape)
            .clipShape(shape)
    }

    private var panelFill: Color {
        if #available(macOS 26.0, *) {
            colorScheme == .dark
                ? Color.black.opacity(LiquidGlassMetrics.panelOpacity)
                : Color.white.opacity(LiquidGlassMetrics.panelOpacity)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

private struct ClipwordChromeBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.background(.background)
        }
    }
}

extension View {
    /// Raised glass control. Uses Liquid Glass on macOS 26+ and `fallback` otherwise.
    func liquidGlass<S: Shape, F: ShapeStyle>(
        _ kind: LiquidGlassKind = .regular,
        in shape: S,
        fallback: F
    ) -> some View {
        modifier(LiquidGlassModifier(kind: kind, shape: shape, fallback: fallback))
    }

    func liquidGlass<S: Shape>(
        _ kind: LiquidGlassKind = .regular,
        in shape: S
    ) -> some View {
        liquidGlass(kind, in: shape, fallback: .ultraThinMaterial)
    }

    /// Floating-panel fill: clear over `NSGlassEffectView` on macOS 26+, opaque otherwise.
    func clipwordPanelBackground(cornerRadius: CGFloat = LiquidGlassMetrics.panelRadius) -> some View {
        modifier(ClipwordPanelBackground(cornerRadius: cornerRadius))
    }

    /// Search / footer bars: transparent on glass panels so the window glass reads as one surface.
    func clipwordChromeBackground() -> some View {
        modifier(ClipwordChromeBackground())
    }

    @ViewBuilder
    func clipwordGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.borderless)
        }
    }
}
