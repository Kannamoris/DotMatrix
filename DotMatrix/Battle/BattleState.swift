import Foundation

/// A snapshot of what's happening in a battle, sampled from emulated memory.
///
/// This carries identifiers and numbers only. Names, move names and message
/// text are read out of the cartridge at display time — none of that is stored
/// here or shipped in the app.
struct BattleState: Equatable {
    struct Combatant: Equatable {
        var speciesID: Int
        /// Decoded from gBattleMons directly, unlike move/type names — it's a
        /// per-battle RAM value tied to this specific Pokémon, not a ROM
        /// table keyed by a stable ID, so there's no separate cache to look
        /// it up from at display time the way moves and types have.
        var nickname: String
        var level: Int
        var currentHP: Int
        var maxHP: Int
        /// Status condition bitfield, as the game stores it.
        var statusFlags: UInt32
        /// Nil when the species has a single type.
        var primaryType: Int
        var secondaryType: Int?
        /// gSpeciesInfo[speciesID].catchRate — a ROM constant, only
        /// meaningful for the opponent, but read for both since it's cheap
        /// and keeps decodeCombatant from needing a "which side is this"
        /// branch. Used for the catch-chance calculator (see CatchChance).
        var catchRate: Int

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
    /// gBattleTypeFlags & BATTLE_TYPE_TRAINER — balls can't be thrown at a
    /// trainer's Pokémon at all, so the catch-chance calculator hides
    /// itself when this is set.
    var isTrainerBattle: Bool = false
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
    /// The Poké Ball pocket, for the catch-chance calculator. Independent of
    /// sample() — see its doc comment on MemoryBattleStateReader for why.
    func pokeBallInventory(_ core: any EmulatorCore) -> [(ball: CatchChance.Ball, quantity: Int)]
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
        /// gBattleMoves. struct BattleMove, 12 bytes each (see
        /// battleMoveSize below for why it's not the 9 the struct's named
        /// fields add up to), indexed by move ID.
        var battleMoves: UInt32
        /// gSpeciesInfo. struct SpeciesInfo, 28 bytes each (see
        /// speciesInfoSize below — same "trust the real ROM layout, not the
        /// struct's named-field byte count" situation as battleMoveSize).
        var speciesInfo: UInt32
        /// gSaveBlock1Ptr — a pointer *variable*, not the save data itself;
        /// dereferenced fresh on every read rather than cached, since
        /// there's no guarantee the save block never moves.
        var saveBlock1Ptr: UInt32
        /// gBattleTypeFlags. Unlike mainCallback2, this keeps its last
        /// value even once gMain.callback2 has left BattleMainCB2 (e.g.
        /// while the bag opened from battle is up), so it's still readable
        /// then. Only used for the BATTLE_TYPE_TRAINER bit here — not as an
        /// "is a battle active" signal, since it's legitimately 0 for a
        /// plain wild battle (see mainCallback2's own comment above).
        var battleTypeFlags: UInt32

        /// Verified 2026-08-13 against Pokémon Emerald (USA), BPEE.
        static let verified = Addresses(
            mainCallback2: 0x030022C4,
            battlerControllerFunc: 0x03005D60,
            battleMons: 0x0202_4084,
            battleMoves: 0x0831_C898,
            speciesInfo: 0x0832_03CC,
            saveBlock1Ptr: 0x0300_5D8C,
            battleTypeFlags: 0x0202_2FEC
        )
    }

    /// Stored callback pointers carry the Thumb-mode bit (+1 over the
    /// disassembly address), matching how they're actually found in RAM.
    private static let battleMainCB2: UInt32 = 0x0803_8421
    private static let handleInputChooseAction: UInt32 = 0x0805_7589
    private static let handleInputChooseMove: UInt32 = 0x0805_7BFD

    private static let battlePokemonSize: UInt32 = 0x58
    /// struct BattleMove is 9 bytes of named fields (effect, power, type,
    /// accuracy, pp, secondaryEffectChance, target, priority, flags) per
    /// pret/pokeemerald's include/pokemon.h, but the real per-entry stride in
    /// ROM is 12 (0xC), not 9 — confirmed two ways: EmeraldRecomp's symbol
    /// table places the next data symbol (sCombinedMoves) exactly 4260 bytes
    /// after gBattleMoves, and 4260 / 355 (MOVES_COUNT) = 12 exactly; and
    /// besteon/Ironmon-Tracker, which reads this same table from live
    /// hardware/emulator RAM, hardcodes `sizeofBattleMove = 0xC`. Using 9
    /// here previously made every move's PP read drift by 3 bytes per move
    /// ID — coincidentally landing exactly on POUND's own power stat (40)
    /// for slot 0, and on HORN DRILL's priority byte (0) for LEER (id 43),
    /// which is what actually surfaced this as a visible bug.
    private static let battleMoveSize: UInt32 = 12
    /// struct SpeciesInfo's named fields (include/pokemon.h) sum to 26
    /// bytes, but the real ROM stride is 28 (0x1C) — confirmed the same two
    /// ways as battleMoveSize: EmeraldRecomp's symbol table places the next
    /// data symbol (sBulbasaurLevelUpLearnset) exactly 11536 bytes after
    /// gSpeciesInfo, and 11536 / 412 (NUM_SPECIES) = 28 exactly; and
    /// besteon/Ironmon-Tracker hardcodes sizeofBaseStatsPokemon = 0x1C.
    private static let speciesInfoSize: UInt32 = 28
    /// SpeciesInfo.catchRate's offset within an entry — this one wasn't
    /// affected by the stride bug above, pret's own offset comment
    /// (/* 0x08 */) matches Ironmon's offsetCatchRate = 0x8 exactly.
    private static let catchRateOffset: UInt32 = 0x08
    /// BATTLE_TYPE_TRAINER (include/constants/battle.h).
    private static let battleTypeTrainerFlag: UInt32 = 1 << 3
    /// SaveBlock1's bagPocket_PokeBalls field (include/global.h) — offset
    /// within the save block, and its slot count. Each slot is a 4-byte
    /// struct ItemSlot (u16 itemId, u16 quantity). Confirmed against
    /// besteon/Ironmon-Tracker's independently-sourced
    /// bagPocket_Balls_offset (0x650) / bagPocket_Balls_Size (0x10), which
    /// match pret's own offset comment and the byte gap to the next pocket
    /// field (bagPocket_TMHM at 0x690) exactly: (0x690-0x650)/4 = 16.
    private static let pokeBallPocketOffset: UInt32 = 0x650
    private static let pokeBallPocketSlotCount = 16

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
        state.player = decodeCombatant(playerBytes, core: core, speciesInfo: addresses.speciesInfo)
        state.opponent = decodeCombatant(opponentBytes, core: core, speciesInfo: addresses.speciesInfo)
        state.moves = decodeMoves(playerBytes, core: core, battleMoves: addresses.battleMoves)
        state.isTrainerBattle = readWord(core, addresses.battleTypeFlags) & Self.battleTypeTrainerFlag != 0

        return state
    }

    /// The Poké Ball pocket, read independently of sample() — opening the
    /// bag from battle moves gMain.callback2 away from BattleMainCB2 (the
    /// same signal sample() gates everything on), but the save block itself
    /// is unaffected and still readable throughout.
    func pokeBallInventory(_ core: any EmulatorCore) -> [(ball: CatchChance.Ball, quantity: Int)] {
        guard let addresses else { return [] }
        let saveBlock1 = readWord(core, addresses.saveBlock1Ptr)
        guard saveBlock1 != 0 else { return [] }

        let byteCount = Self.pokeBallPocketSlotCount * 4
        let bytes = core.readMemory(saveBlock1 + Self.pokeBallPocketOffset, count: byteCount)
        guard bytes.count == byteCount else { return [] }

        var slots: [(ball: CatchChance.Ball, quantity: Int)] = []
        for slot in 0..<Self.pokeBallPocketSlotCount {
            let itemID = u16(bytes, slot * 4)
            let quantity = u16(bytes, slot * 4 + 2)
            guard quantity > 0, let ball = CatchChance.Ball(rawValue: itemID) else { continue }
            slots.append((ball, quantity))
        }
        return slots
    }

    // MARK: Decoding

    private func readWord(_ core: any EmulatorCore, _ address: UInt32) -> UInt32 {
        let bytes = core.readMemory(address, count: 4)
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    /// struct BattlePokemon (include/pokemon.h): species@0x00, moves[4]@0x0C,
    /// types[2]@0x21, pp[4]@0x24, hp@0x28, level@0x2A, maxHP@0x2C,
    /// nickname[11]@0x30, ppBonuses@0x3B, status1@0x4C.
    private func decodeCombatant(
        _ bytes: [UInt8], core: any EmulatorCore, speciesInfo: UInt32
    ) -> BattleState.Combatant? {
        guard bytes.count == Int(Self.battlePokemonSize) else { return nil }
        let species = u16(bytes, 0x00)
        guard species != 0 else { return nil }

        let type0 = Int(bytes[0x21])
        let type1 = Int(bytes[0x22])
        let nickname = Gen3Text.decode(Array(bytes[0x30..<0x3B])) ?? "???"

        return BattleState.Combatant(
            speciesID: species,
            nickname: nickname,
            level: Int(bytes[0x2A]),
            currentHP: u16(bytes, 0x28),
            maxHP: u16(bytes, 0x2C),
            statusFlags: u32(bytes, 0x4C),
            primaryType: type0,
            secondaryType: type1 == type0 ? nil : type1,
            catchRate: speciesCatchRate(species: species, core: core, speciesInfo: speciesInfo)
        )
    }

    private func speciesCatchRate(species: Int, core: any EmulatorCore, speciesInfo: UInt32) -> Int {
        let address = speciesInfo + UInt32(species) * Self.speciesInfoSize + Self.catchRateOffset
        let bytes = core.readMemory(address, count: 1)
        return Int(bytes.first ?? 0)
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
