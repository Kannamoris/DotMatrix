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
    /// A single A press — advances messages, damage/faint text, and anything
    /// else where the game is just waiting for acknowledgement rather than a
    /// menu choice.
    var onAdvance: () -> Void

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

    /// The emulated screen. Cropped to just the battlefield while the custom
    /// action/move grid is up (it replaces the game's own menu there, so
    /// showing both would be redundant) and shown in full otherwise — the
    /// game draws messages, damage numbers and faint text in the bottom third
    /// that the crop would otherwise hide with no way to read or advance it.
    private var scene: some View {
        MetalDisplayView(
            session: session,
            gridStrength: 0,
            smoothing: 0,
            sourceRect: BattleLayout.sceneRegion(for: state.phase)
        )
        .aspectRatio(BattleLayout.sceneAspect(for: state.phase), contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func sceneHeight(in geometry: GeometryProxy) -> CGFloat {
        // Give the scene the width, and whatever height that implies, capped so
        // the controls always keep a usable share of a short screen.
        let natural = geometry.size.width / BattleLayout.sceneAspect(for: state.phase)
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
        // Covers both "the game is animating, taps do nothing" and "the game
        // is printing a message and A advances it" — there's no reliable way
        // to tell those apart from memory alone, and sending A when the game
        // isn't listening for it is a harmless no-op, so the whole area is
        // always tappable rather than guessing which case this is.
        Button(action: onAdvance) {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .foregroundStyle(.secondary)
                Text("Tap to continue")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    /// Position in the game's own 2x2 action grid (top-left to bottom-right),
    /// confirmed directly from HandleInputChooseAction in
    /// battle_controller_player.c — not this app's own layout choice.
    var slotIndex: Int {
        switch self {
        case .fight: return 0
        case .bag: return 1
        case .pokemon: return 2
        case .run: return 3
        }
    }
}

/// Where the battlefield sits within the emulated screen, and how it is scaled.
enum BattleLayout {
    /// Full native screen, 240x160.
    static let fullScreen = CGRect(x: 0, y: 0, width: 240, height: 160)

    /// The game draws its menu across the bottom third of the screen.
    /// Cropping it away leaves just the battlefield, in source pixels.
    static let battlefieldOnly = CGRect(x: 0, y: 0, width: 240, height: 112)

    /// Cropped to the battlefield only while the custom action/move grid
    /// replaces the game's own menu; full screen otherwise, so messages,
    /// damage numbers and faint text — which the game draws in the region
    /// that would otherwise be cropped away — stay visible.
    static func sceneRegion(for phase: BattleState.Phase) -> CGRect {
        switch phase {
        case .actionSelection, .moveSelection: return battlefieldOnly
        default: return fullScreen
        }
    }

    static func sceneAspect(for phase: BattleState.Phase) -> CGFloat {
        let region = sceneRegion(for: phase)
        return region.width / region.height
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
                        // Both branches must be the same ShapeStyle type; the
                        // hierarchical styles and Color don't unify.
                        .foregroundStyle(move.isUsable ? Color.secondary : Color.red)
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
