import SwiftUI

/// A small "cheat sheet" panel showing catch odds for every Poké Ball in the
/// bag, for the opponent the player was just battling.
///
/// Unlike the rest of the reskinned battle UI, this deliberately doesn't try
/// to look like part of the game — the real game has no equivalent of it at
/// all, so there's nothing to imitate. It reads like the other app-native
/// overlays (the FPS/diagnostics readout) instead: system font, dark panel.
///
/// See `EmulatorSession.catchAdvisor` for exactly when this appears (short
/// version: once the player has stepped out to the bag mid wild-battle).
struct CatchAdvisorOverlay: View {
    let advisor: CatchChance.Advisor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CATCH CHANCE — \(advisor.opponentNickname.uppercased())")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))

            ForEach(advisor.entries) { entry in
                HStack(spacing: 8) {
                    Text(entry.ball.displayName)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("×\(entry.quantity)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 12)
                    Text(percentageText(entry.percentage))
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(color(for: entry.percentage))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
    }

    private func percentageText(_ value: Double) -> String {
        value >= 99.95 ? "100%" : String(format: "%.0f%%", value)
    }

    /// Chosen here, not derived from the game — a rough "how likely is
    /// this actually going to work" traffic-light, same spirit as the type
    /// effectiveness colouring.
    private func color(for percentage: Double) -> Color {
        switch percentage {
        case ..<15: return .red
        case ..<50: return .yellow
        default: return .green
        }
    }
}
