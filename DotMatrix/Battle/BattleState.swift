import Foundation

/// A snapshot of what's happening in a battle, sampled from emulated memory.
///
/// This carries identifiers and numbers only. Names, move names and message
/// text are read out of the cartridge at display time — none of that is stored
/// here or shipped in the app.
struct BattleState: Equatable {
    struct Combatant: Equatable {
        var speciesID: Int
        var level: Int
        var currentHP: Int
        var maxHP: Int
        /// Status condition bitfield, as the game stores it.
        var statusFlags: UInt32
        /// Nil when the species has a single type.
        var primaryType: Int
        var secondaryType: Int?

        var hpFraction: Double {
            maxHP > 0 ? min(1, max(0, Double(currentHP) / Double(maxHP))) : 0
        }

        var isFainted: Bool { currentHP <= 0 }
    }

    struct Move: Equatable {
        var moveID: Int
        var currentPP: Int
        var maxPP: Int
        /// Type index, for colouring and effectiveness.
        var type: Int
        var power: Int
        var accuracy: Int

        var isUsable: Bool { currentPP > 0 }
    }

    /// What the game is waiting for, which decides whether the native controls
    /// should be live.
    enum Phase: Equatable {
        /// Not in a battle at all.
        case none
        /// Transition animation — the moment to swap views.
        case starting
        /// Waiting for the player to pick FIGHT/BAG/POKEMON/RUN.
        case actionSelection
        /// Waiting for a move choice.
        case moveSelection
        /// Animations, damage, messages: the game is driving, controls idle.
        case resolving
        case ending
    }

    var phase: Phase = .none
    var player: Combatant?
    var opponent: Combatant?
    var moves: [Move] = []
    /// Which slot the game's own cursor is on, so synthesized input knows how
    /// far it has to travel.
    var cursorIndex: Int = 0

    var isActive: Bool { phase != .none }

    /// True when a tap should be accepted right now.
    var acceptsInput: Bool {
        phase == .actionSelection || phase == .moveSelection
    }

    static let inactive = BattleState()
}

/// Supplies battle snapshots. Implemented against emulated memory in the real
/// build, and by a stub while the UI is being developed.
protocol BattleStateReading {
    /// Sample the current state. Called once per frame from the emulation
    /// thread, so it must not block.
    func sample(_ core: any EmulatorCore) -> BattleState
}

/// Placeholder state for building and reviewing the interface before the
/// memory addresses are pinned down.
///
/// It cycles through the phases on a timer so the layout, the transitions and
/// the control behaviour can all be exercised on device against something
/// predictable.
struct SimulatedBattleStateReader: BattleStateReading {
    private static let start = Date()

    func sample(_ core: any EmulatorCore) -> BattleState {
        let elapsed = Date().timeIntervalSince(Self.start)

        var state = BattleState()
        state.phase = .moveSelection
        state.player = .init(speciesID: 252, level: 12, currentHP: 27, maxHP: 34,
                             statusFlags: 0, primaryType: 12, secondaryType: nil)
        state.opponent = .init(speciesID: 261, level: 10, currentHP: 9, maxHP: 31,
                               statusFlags: 0, primaryType: 17, secondaryType: nil)
        state.moves = [
            .init(moveID: 33, currentPP: 30, maxPP: 35, type: 0, power: 35, accuracy: 95),
            .init(moveID: 45, currentPP: 40, maxPP: 40, type: 0, power: 0, accuracy: 100),
            .init(moveID: 71, currentPP: 22, maxPP: 25, type: 12, power: 20, accuracy: 100),
            .init(moveID: 73, currentPP: 0, maxPP: 10, type: 12, power: 0, accuracy: 90),
        ]
        // Drift the opponent's HP so the bar animation is visible.
        let wave = (sin(elapsed / 3) + 1) / 2
        state.opponent?.currentHP = Int(wave * 31)
        return state
    }
}

/// Reads battle state out of emulated RAM.
///
/// The addresses are deliberately absent: they will be found empirically by
/// diffing memory across known state changes rather than guessed, because a
/// wrong address here produces plausible-looking numbers that are silently
/// meaningless. Until then this reports no battle, and the UI runs against the
/// simulated reader.
struct MemoryBattleStateReader: BattleStateReading {
    /// Filled in once verified against a running battle.
    struct Addresses {
        var battleTypeFlags: UInt32
        var battleMainFunc: UInt32
        var playerParty: UInt32
        var enemyParty: UInt32
        var battleMons: UInt32
        var moveSelectionCursor: UInt32
    }

    var addresses: Addresses?

    func sample(_ core: any EmulatorCore) -> BattleState {
        guard addresses != nil else { return .inactive }
        // Decoding lands here once the addresses are confirmed.
        return .inactive
    }
}
