import SwiftUI

/// Gen 3's type matchup chart, transcribed from pret/pokeemerald's
/// gTypeEffectiveness (src/battle_main.c) — generated mechanically from the
/// source table's 110 real entries rather than typed by hand, to rule out
/// transcription mistakes.
///
/// This is static, cartridge-invariant game data (identical on every
/// Emerald ROM), so unlike move/species data it's hardcoded here rather than
/// read from ROM at runtime — the same choice already made for Gen3Font's
/// glyph-decoding tables.
///
/// The real table also has two entries (Normal and Fighting do nothing to
/// Ghost) that come after a TYPE_FORESIGHT sentinel row: the game only
/// applies them when the target *isn't* under Foresight/Odor Sleuth, which
/// bypasses Ghost's immunity. This app doesn't track that status, so those
/// two entries are just included unconditionally — this is the base type
/// chart, not battle-state-aware effectiveness.
enum TypeEffectiveness {
    /// Combined multiplier of `moveType` against every type in
    /// `defenderTypes` — each defending type is looked up independently and
    /// the results multiply together, same as the real damage formula (a
    /// move that's super effective against both of a dual-type Pokémon's
    /// types ends up ×4, not ×2).
    static func multiplier(moveType: Int, defenderTypes: [Int]) -> Double {
        defenderTypes.reduce(1.0) { result, defType in
            result * (chart[Key(atk: moveType, def: defType)] ?? 1.0)
        }
    }

    /// Compact label for the multiplier, or nil for neutral (×1) — the real
    /// game only calls out effectiveness when it isn't normal, so a neutral
    /// matchup shows nothing rather than "1X" on every single move.
    static func label(for multiplier: Double) -> String? {
        switch multiplier {
        case 0: return "0X"
        case 0.25: return "1/4X"
        case 0.5: return "1/2X"
        case 1: return nil
        case 2: return "2X"
        case 4: return "4X"
        default: return nil
        }
    }

    /// Chosen here, not derived from the game — green reads as "good for
    /// you," red as "weak," gray as "does nothing," matching the intent
    /// behind the game's own super/not-very-effective sound cues.
    static func color(for multiplier: Double) -> Color {
        if multiplier == 0 { return .gray }
        if multiplier < 1 { return .red }
        return .green
    }

    private struct Key: Hashable {
        var atk: Int
        var def: Int
    }

    private static let chart: [Key: Double] = {
        // (attacking type, defending type, multiplier). Only non-1.0
        // matchups are listed, exactly as in the ROM table; anything absent
        // here is neutral (×1), same as the real game's fallthrough.
        let entries: [(Int, Int, Double)] = [
            (0, 5, 0.5), (0, 8, 0.5), (10, 10, 0.5), (10, 11, 0.5), (10, 12, 2), (10, 15, 2),
            (10, 6, 2), (10, 5, 0.5), (10, 16, 0.5), (10, 8, 2), (11, 10, 2), (11, 11, 0.5),
            (11, 12, 0.5), (11, 4, 2), (11, 5, 2), (11, 16, 0.5), (13, 11, 2), (13, 13, 0.5),
            (13, 12, 0.5), (13, 4, 0), (13, 2, 2), (13, 16, 0.5), (12, 10, 0.5), (12, 11, 2),
            (12, 12, 0.5), (12, 3, 0.5), (12, 4, 2), (12, 2, 0.5), (12, 6, 0.5), (12, 5, 2),
            (12, 16, 0.5), (12, 8, 0.5), (15, 11, 0.5), (15, 12, 2), (15, 15, 0.5), (15, 4, 2),
            (15, 2, 2), (15, 16, 2), (15, 8, 0.5), (15, 10, 0.5), (1, 0, 2), (1, 15, 2),
            (1, 3, 0.5), (1, 2, 0.5), (1, 14, 0.5), (1, 6, 0.5), (1, 5, 2), (1, 17, 2),
            (1, 8, 2), (3, 12, 2), (3, 3, 0.5), (3, 4, 0.5), (3, 5, 0.5), (3, 7, 0.5),
            (3, 8, 0), (4, 10, 2), (4, 13, 2), (4, 12, 0.5), (4, 3, 2), (4, 2, 0),
            (4, 6, 0.5), (4, 5, 2), (4, 8, 2), (2, 13, 0.5), (2, 12, 2), (2, 1, 2),
            (2, 6, 2), (2, 5, 0.5), (2, 8, 0.5), (14, 1, 2), (14, 3, 2), (14, 14, 0.5),
            (14, 17, 0), (14, 8, 0.5), (6, 10, 0.5), (6, 12, 2), (6, 1, 0.5), (6, 3, 0.5),
            (6, 2, 0.5), (6, 14, 2), (6, 7, 0.5), (6, 17, 2), (6, 8, 0.5), (5, 10, 2),
            (5, 15, 2), (5, 1, 0.5), (5, 4, 0.5), (5, 2, 2), (5, 6, 2), (5, 8, 0.5),
            (7, 0, 0), (7, 14, 2), (7, 17, 0.5), (7, 8, 0.5), (7, 7, 2), (16, 16, 2),
            (16, 8, 0.5), (17, 1, 0.5), (17, 14, 2), (17, 7, 2), (17, 17, 0.5), (17, 8, 0.5),
            (8, 10, 0.5), (8, 11, 0.5), (8, 13, 0.5), (8, 15, 2), (8, 5, 2), (8, 8, 0.5),
            (0, 7, 0), (1, 7, 0),
        ]
        var chart: [Key: Double] = [:]
        for (atk, def, mult) in entries {
            chart[Key(atk: atk, def: def)] = mult
        }
        return chart
    }()
}
