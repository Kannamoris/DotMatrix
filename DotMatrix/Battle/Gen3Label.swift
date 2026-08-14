import SwiftUI

/// Text rendered with Pokémon Emerald's own font glyphs (see `Gen3Font`)
/// instead of the system font, drawn pixel-by-pixel via `Canvas` so it stays
/// crisp at any integer scale — the same nearest-neighbour look as the game
/// itself, rather than an antialiased system font trying to imitate it.
struct Gen3Label: View {
    let text: String
    var scale: CGFloat = 2
    var color: Color = .white
    var shadowColor: Color = .black.opacity(0.6)

    private var glyphs: [Gen3Font.Glyph] {
        Gen3FontCache.shared.glyphs(for: text)
    }

    /// Gap between glyphs. The font has no built-in kerning data available
    /// here (GetGlyphWidth_Normal already bakes each glyph's own advance
    /// into its width), so this is purely this app's own spacing choice.
    private static let glyphGap: CGFloat = 1

    var body: some View {
        let glyphs = glyphs
        let height = CGFloat(Gen3Font.height) * scale
        let width = glyphs.reduce(CGFloat(0)) { $0 + CGFloat($1.width) * scale + Self.glyphGap * scale }

        Canvas { context, _ in
            var x: CGFloat = 0
            for glyph in glyphs {
                for row in 0..<glyph.height {
                    for col in 0..<glyph.width {
                        let fillColor: Color
                        switch glyph.pixelClass(x: col, y: row) {
                        case .foreground: fillColor = color
                        case .shadow: fillColor = shadowColor
                        case .background: continue
                        }
                        let rect = CGRect(
                            x: x + CGFloat(col) * scale, y: CGFloat(row) * scale,
                            width: scale, height: scale
                        )
                        context.fill(Path(rect), with: .color(fillColor))
                    }
                }
                x += CGFloat(glyph.width) * scale + Self.glyphGap * scale
            }
        }
        .frame(width: max(width, 1), height: height)
        // Canvas has no intrinsic content — without this, a Gen3Label used
        // where SwiftUI expects to measure text (button labels, HStacks that
        // size to content) collapses to zero width, whether or not the fixed
        // frame above is present.
        .fixedSize()
    }
}
