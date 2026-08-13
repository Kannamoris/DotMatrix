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
    /// Which slot the game's own cursor is on, purely for highlighting it in
    /// the native-equivalent position. -1 (nothing highlighted) when unknown:
    /// synthesized input doesn't need this to work — the game's own cursor
    /// toggles are gated by side (pressing left when already on the left
    /// column is a no-op), so driving to a target slot is one horizontal +
    /// one vertical press regardless of where the cursor currently is.
    var cursorIndex: Int = -1

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

/// Reads battle state out of emulated RAM.
///
/// Every address below was found empirically, not guessed — the risk the
/// original placeholder warned about (a wrong address producing
/// plausible-looking nonsense) is exactly why. `gMain.callback2` and
/// `gBattlerControllerFuncs[0]` in particular have no address published
/// anywhere public: both were found by loading a save state and scanning RAM
/// live for the exact pointer *values* the game is known to store there
/// (verified from EmeraldRecomp's byte-matched symbol table, built from the
/// actual decompiled ELF) at specific, controlled moments — mid-battle vs.
/// overworld, action-select vs. move-select — and confirming the same
/// address held the corresponding different value in each capture. Everything
/// else (struct layouts, PP-Up math, cursor grid adjacency) is transcribed
/// directly from pret/pokeemerald's own source, not recalled from memory.
struct MemoryBattleStateReader: BattleStateReading {
    struct Addresses {
        /// gMain.callback2. BattleMainCB2 throughout an active battle,
        /// something else (an overworld callback) otherwise — the only
        /// reliable "is a battle happening at all" signal, since
        /// gBattleTypeFlags is legitimately 0 for a plain wild battle.
        var mainCallback2: UInt32
        /// gBattlerControllerFuncs[0] (the player battler's slot). Compared
        /// against the known addresses of HandleInputChooseAction and
        /// HandleInputChooseMove to tell the two menus apart.
        var battlerControllerFunc: UInt32
        /// gBattleMons. struct BattlePokemon, 0x58 bytes each, indexed by
        /// battler: [0] is the player's active mon, [1] the opponent's, for
        /// the single (non-double) battles this UI targets.
        var battleMons: UInt32
        /// gBattleMoves. struct BattleMove, 9 bytes each, indexed by move ID.
        var battleMoves: UInt32

        /// Verified 2026-08-13 against Pokémon Emerald (USA), BPEE.
        static let verified = Addresses(
            mainCallback2: 0x030022C4,
            battlerControllerFunc: 0x03005D60,
            battleMons: 0x0202_4084,
            battleMoves: 0x0831_C898
        )
    }

    /// Stored callback pointers carry the Thumb-mode bit (+1 over the
    /// disassembly address), matching how they're actually found in RAM.
    private static let battleMainCB2: UInt32 = 0x0803_8421
    private static let handleInputChooseAction: UInt32 = 0x0805_7589
    private static let handleInputChooseMove: UInt32 = 0x0805_7BFD

    private static let battlePokemonSize: UInt32 = 0x58
    private static let battleMoveSize: UInt32 = 9

    var addresses: Addresses?

    func sample(_ core: any EmulatorCore) -> BattleState {
        guard let addresses else { return .inactive }
        guard readWord(core, addresses.mainCallback2) == Self.battleMainCB2 else { return .inactive }

        var state = BattleState()

        switch readWord(core, addresses.battlerControllerFunc) {
        case Self.handleInputChooseAction: state.phase = .actionSelection
        case Self.handleInputChooseMove: state.phase = .moveSelection
        default: state.phase = .resolving
        }

        let playerBytes = core.readMemory(addresses.battleMons, count: Int(Self.battlePokemonSize))
        let opponentBytes = core.readMemory(
            addresses.battleMons + Self.battlePokemonSize,
            count: Int(Self.battlePokemonSize)
        )
        state.player = decodeCombatant(playerBytes)
        state.opponent = decodeCombatant(opponentBytes)
        state.moves = decodeMoves(playerBytes, core: core, battleMoves: addresses.battleMoves)

        return state
    }

    // MARK: Decoding

    private func readWord(_ core: any EmulatorCore, _ address: UInt32) -> UInt32 {
        let bytes = core.readMemory(address, count: 4)
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    /// struct BattlePokemon (include/pokemon.h): species@0x00, moves[4]@0x0C,
    /// types[2]@0x21, pp[4]@0x24, hp@0x28, level@0x2A, maxHP@0x2C,
    /// ppBonuses@0x3B, status1@0x4C.
    private func decodeCombatant(_ bytes: [UInt8]) -> BattleState.Combatant? {
        guard bytes.count == Int(Self.battlePokemonSize) else { return nil }
        let species = u16(bytes, 0x00)
        guard species != 0 else { return nil }

        let type0 = Int(bytes[0x21])
        let type1 = Int(bytes[0x22])

        return BattleState.Combatant(
            speciesID: species,
            level: Int(bytes[0x2A]),
            currentHP: u16(bytes, 0x28),
            maxHP: u16(bytes, 0x2C),
            statusFlags: u32(bytes, 0x4C),
            primaryType: type0,
            secondaryType: type1 == type0 ? nil : type1
        )
    }

    private func decodeMoves(_ playerBytes: [UInt8], core: any EmulatorCore, battleMoves: UInt32) -> [BattleState.Move] {
        guard playerBytes.count == Int(Self.battlePokemonSize) else { return [] }
        let ppBonuses = playerBytes[0x3B]

        var moves: [BattleState.Move] = []
        for slot in 0..<4 {
            let moveID = u16(playerBytes, 0x0C + slot * 2)
            guard moveID != 0 else { continue }

            let moveBase = battleMoves + UInt32(moveID) * Self.battleMoveSize
            let moveBytes = core.readMemory(moveBase, count: Int(Self.battleMoveSize))
            guard moveBytes.count == Int(Self.battleMoveSize) else { continue }

            // CalculatePPWithBonus (src/pokemon.c): basePP + basePP*20%*upCount,
            // upCount packed 2 bits per move slot.
            let basePP = Int(moveBytes[4])
            let ppUpCount = Int((ppBonuses >> UInt8(2 * slot)) & 0x3)
            let maxPP = basePP + (basePP * 20 * ppUpCount) / 100

            moves.append(BattleState.Move(
                moveID: moveID,
                currentPP: Int(playerBytes[0x24 + slot]),
                maxPP: maxPP,
                type: Int(moveBytes[2]),
                power: Int(moveBytes[1]),
                accuracy: Int(moveBytes[3])
            ))
        }
        return moves
    }

    private func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
