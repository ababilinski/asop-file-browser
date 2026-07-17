import SwiftUI

struct LiquidGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

extension View {
    @ViewBuilder
    func liquidGlassPanel<S: Shape>(
        in shape: S,
        fallbackMaterial: Material = .thinMaterial
    ) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(fallbackMaterial, in: shape)
        }
    }

    @ViewBuilder
    func liquidGlassTintedPanel<S: Shape>(
        tint: Color,
        in shape: S,
        fallbackMaterial: Material = .thinMaterial
    ) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint.opacity(0.22)), in: shape)
        } else {
            background(fallbackMaterial, in: shape)
        }
    }

    @ViewBuilder
    func liquidGlassInteractivePanel<S: Shape>(
        tint: Color,
        in shape: S,
        fallbackMaterial: Material = .thinMaterial
    ) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            background(fallbackMaterial, in: shape)
        }
    }

    @ViewBuilder
    func liquidGlassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func liquidGlassProminentButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
