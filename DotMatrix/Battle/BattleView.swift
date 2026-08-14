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
    /// A single B press — backs out of move selection to the action menu,
    /// same as the real menu, without choosing a move.
    var onCancelMove: () -> Void

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

    /// The emulated screen, always shown in full and at a fixed aspect ratio.
    ///
    /// This used to crop to just the battlefield while the custom action/move
    /// grid was up, to hide the game's own (now redundant) menu — but the
    /// phase changes constantly during a turn (action select, move select,
    /// message, back to action select...), and flipping the crop each time
    /// changed the scene's aspect ratio, so the video pane visibly resized on
    /// every single transition. Showing the same fixed frame at every phase
    /// trades a small sliver of redundant native menu for a scene that never
    /// jumps around.
    private var scene: some View {
        MetalDisplayView(
            session: session,
            gridStrength: 0,
            smoothing: 0,
            sourceRect: BattleLayout.fullScreen
        )
        .aspectRatio(BattleLayout.aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func sceneHeight(in geometry: GeometryProxy) -> CGFloat {
        // Give the scene the width, and whatever height that implies, capped so
        // the controls always keep a usable share of a short screen.
        let natural = geometry.size.width / BattleLayout.aspect
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
                HealthBar(combatant: player, alignment: .leading)
            }
            if let opponent = state.opponent {
                HealthBar(combatant: opponent, alignment: .trailing)
            }
        }
    }

    private var moveGrid: some View {
        HStack(spacing: 8) {
            backButton
            GBAWindowBox {
                VStack(spacing: 0) {
                    windowRow(moveCell(index: 0), moveCell(index: 1))
                    windowDivider(vertical: false)
                    windowRow(moveCell(index: 2), moveCell(index: 3))
                }
            }
        }
        .frame(height: 132)
    }

    /// The touch equivalent of pressing B during move selection — there's no
    /// on-screen gamepad during battle (this grid replaces it), so without
    /// this there was no way to back out of move selection short of picking
    /// a move.
    private var backButton: some View {
        Button(action: onCancelMove) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .disabled(!state.acceptsInput)
    }

    @ViewBuilder
    private func moveCell(index: Int) -> some View {
        if let move = state.moves[safe: index] {
            let enabled = state.acceptsInput && move.isUsable
            MoveCell(
                move: move,
                isSelected: index == state.cursorIndex,
                action: { onSelectMove(index) }
            )
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        } else {
            Color.clear
        }
    }

    private var actionGrid: some View {
        GBAWindowBox {
            VStack(spacing: 0) {
                windowRow(actionCell(.fight), actionCell(.bag))
                windowDivider(vertical: false)
                windowRow(actionCell(.pokemon), actionCell(.run))
            }
        }
        .frame(height: 120)
    }

    private func actionCell(_ action: BattleAction) -> some View {
        Button {
            onSelectAction(action)
        } label: {
            Gen3Label(text: action.title, scale: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(WindowCellButtonStyle())
        .disabled(!state.acceptsInput)
        .opacity(state.acceptsInput ? 1 : 0.5)
    }

    /// Two cells side by side with the vertical divider the game's own
    /// menu boxes draw between quadrants.
    private func windowRow(_ left: some View, _ right: some View) -> some View {
        HStack(spacing: 0) {
            left
            windowDivider(vertical: true)
            right
        }
        .frame(maxHeight: .infinity)
    }

    private func windowDivider(vertical: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.5))
            .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
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
                    .foregroundStyle(.white.opacity(0.7))
                Gen3Label(text: "TAP TO CONTINUE", scale: 1, color: .white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A GBA menu window: rounded box, blue gradient fill, white border — the
/// game's own look for its action/move menus, reused here as the container
/// for this app's native replacements so they read as part of the same UI
/// rather than an iOS control sitting on top of it.
private struct GBAWindowBox<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(
                LinearGradient(
                    colors: [Color(red: 0.42, green: 0.58, blue: 0.86), Color(red: 0.14, green: 0.22, blue: 0.52)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white, lineWidth: 3))
    }
}

/// Pressed state darkens the cell instead of the system's default highlight,
/// matching a menu cursor landing on an option rather than an iOS button tap.
private struct WindowCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.black.opacity(0.25) : Color.clear)
    }
}

/// The top-level choices the game offers each turn.
enum BattleAction: CaseIterable {
    case fight, bag, pokemon, run

    /// The game's own labels, all caps — matches what's rendered with
    /// Gen3Label now, so it should read exactly like the native menu.
    var title: String {
        switch self {
        case .fight: return "FIGHT"
        case .bag: return "BAG"
        case .pokemon: return "POKEMON"
        case .run: return "RUN"
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

/// The emulated screen's native size and aspect ratio. The scene is always
/// shown in full at this fixed shape — see the comment on `scene` in
/// `BattleView` for why it no longer varies by phase.
enum BattleLayout {
    static let fullScreen = CGRect(x: 0, y: 0, width: 240, height: 160)
    static let aspect: CGFloat = fullScreen.width / fullScreen.height
}

// MARK: - Pieces

private struct HealthBar: View {
    let combatant: BattleState.Combatant
    let alignment: HorizontalAlignment

    private var tint: Color {
        switch combatant.hpFraction {
        case ..<0.2: return .red
        case ..<0.5: return .yellow
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            HStack(spacing: 6) {
                Gen3Label(text: combatant.nickname, scale: 1)
                Gen3Label(text: "LV\(combatant.level)", scale: 1, color: .white.opacity(0.7))
            }

            // A rectangular, black-bordered bar rather than an iOS Capsule —
            // the game's own HP gauge is square-cornered, not pill-shaped.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.6))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint)
                        .frame(width: max(2, geometry.size.width * combatant.hpFraction))
                }
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.black, lineWidth: 1))
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.25), value: combatant.currentHP)

            Gen3Label(text: "\(combatant.currentHP)/\(combatant.maxHP)", scale: 1, color: .white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

private struct MoveCell: View {
    let move: BattleState.Move
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Gen3Label(
                    text: MoveNameCache.shared.name(for: move.moveID) ?? "MOVE \(move.moveID)",
                    scale: 1
                )

                HStack(spacing: 6) {
                    if let typeName = TypeNameCache.shared.name(for: move.type) {
                        Gen3Label(text: typeName.uppercased(), scale: 1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(TypeNameCache.shared.colour(for: move.type))
                            )
                    }
                    Spacer(minLength: 0)
                    Gen3Label(
                        text: "\(move.currentPP)/\(move.maxPP)",
                        scale: 1,
                        color: move.isUsable ? .white.opacity(0.8) : .red
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .frame(maxHeight: .infinity)
            .background(isSelected ? Color.white.opacity(0.15) : Color.clear)
        }
        .buttonStyle(WindowCellButtonStyle())
    }
}

private extension Array {
    /// `state.moves` can have fewer than 4 entries mid-battle-load; this
    /// keeps the 2x2 grid from indexing past the end while it fills in.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
