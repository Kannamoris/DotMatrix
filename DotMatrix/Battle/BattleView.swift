import SwiftUI

/// The native battle screen.
///
/// The scene is the emulator's own output, cropped to the region the game draws
/// the battlefield into and scaled at whole multiples so the pixel art stays
/// crisp. Everything below it is native: the game's own menu and text box are
/// left out of the crop and replaced with controls sized for thumbs.
///
/// No game logic lives here. Every number shown is read from emulated memory,
/// and every tap becomes a button sequence the emulator receives exactly as it
/// would from a real pad, so damage, accuracy and AI stay the hardware's.
struct BattleView: View {
    @ObservedObject var session: EmulatorSession
    let state: BattleState

    /// Sends a chosen move back for translation into button presses.
    var onSelectMove: (Int) -> Void
    var onSelectAction: (BattleAction) -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                scene
                    .frame(height: sceneHeight(in: geometry))
                    .clipped()

                controls
                    .frame(maxHeight: .infinity)
                    .background(Color(white: 0.08))
            }
        }
        .background(Color.black)
    }

    // MARK: Scene

    /// The battlefield region of the emulated screen, without the game's own
    /// menu or message box.
    private var scene: some View {
        MetalDisplayView(
            session: session,
            gridStrength: 0,
            smoothing: 0,
            sourceRect: BattleLayout.sceneRegion
        )
        .aspectRatio(BattleLayout.sceneAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func sceneHeight(in geometry: GeometryProxy) -> CGFloat {
        // Give the scene the width, and whatever height that implies, capped so
        // the controls always keep a usable share of a short screen.
        let natural = geometry.size.width / BattleLayout.sceneAspect
        return min(natural, geometry.size.height * 0.55)
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            combatantBars

            switch state.phase {
            case .moveSelection:
                moveGrid
            case .actionSelection:
                actionGrid
            default:
                waitingIndicator
            }
        }
        .padding(12)
    }

    private var combatantBars: some View {
        HStack(spacing: 14) {
            if let player = state.player {
                HealthBar(combatant: player, label: "Yours", alignment: .leading)
            }
            if let opponent = state.opponent {
                HealthBar(combatant: opponent, label: "Foe", alignment: .trailing)
            }
        }
    }

    private var moveGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(Array(state.moves.enumerated()), id: \.offset) { index, move in
                MoveButton(move: move, isSelected: index == state.cursorIndex) {
                    onSelectMove(index)
                }
                .disabled(!state.acceptsInput || !move.isUsable)
            }
        }
    }

    private var actionGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(BattleAction.allCases, id: \.self) { action in
                Button {
                    onSelectAction(action)
                } label: {
                    Text(action.title)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(action.tint)
                .disabled(!state.acceptsInput)
            }
        }
    }

    private var waitingIndicator: some View {
        // The game is animating or printing; taps would be swallowed anyway, so
        // say so rather than showing dead buttons.
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for the battle to continue")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
    }
}

/// The top-level choices the game offers each turn.
enum BattleAction: CaseIterable {
    case fight, bag, pokemon, run

    var title: String {
        switch self {
        case .fight: return "Fight"
        case .bag: return "Bag"
        case .pokemon: return "Party"
        case .run: return "Run"
        }
    }

    var tint: Color {
        switch self {
        case .fight: return .red
        case .bag: return .orange
        case .pokemon: return .green
        case .run: return .gray
        }
    }
}

/// Where the battlefield sits within the emulated screen, and how it is scaled.
enum BattleLayout {
    /// The game draws its menu and message box across the bottom of the screen.
    /// Cropping them away leaves the battlefield, which the native layout
    /// presents on its own.
    ///
    /// Expressed in source pixels; refined once a real battle can be inspected.
    static let sceneRegion = CGRect(x: 0, y: 0, width: 240, height: 112)

    static var sceneAspect: CGFloat {
        sceneRegion.width / sceneRegion.height
    }
}

// MARK: - Pieces

private struct HealthBar: View {
    let combatant: BattleState.Combatant
    let label: String
    let alignment: HorizontalAlignment

    private var tint: Color {
        switch combatant.hpFraction {
        case ..<0.2: return .red
        case ..<0.5: return .yellow
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Lv\(combatant.level)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * combatant.hpFraction)
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.25), value: combatant.currentHP)

            Text("\(combatant.currentHP)/\(combatant.maxHP)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

private struct MoveButton: View {
    let move: BattleState.Move
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                // The move's name comes from the cartridge at display time.
                Text(MoveNameCache.shared.name(for: move.moveID) ?? "Move \(move.moveID)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    TypeChip(type: move.type)
                    Spacer(minLength: 0)
                    Text("\(move.currentPP)/\(move.maxPP)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(move.isUsable ? .secondary : .red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .buttonStyle(.bordered)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}

private struct TypeChip: View {
    let type: Int

    var body: some View {
        Text(TypeNameCache.shared.name(for: type) ?? "—")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(TypeNameCache.shared.colour(for: type).opacity(0.3))
            )
    }
}
