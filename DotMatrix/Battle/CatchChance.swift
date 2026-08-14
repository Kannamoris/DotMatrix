import Foundation

/// Gen 3's catch-chance math, transcribed from pret/pokeemerald's
/// Cmd_handleballthrow (src/battle_script_commands.c) — ball bonuses,
/// status bonus, and the two-sqrt shake-probability step all read the same
/// as the source, using the same integer truncation at each step (GBA
/// integer division floors, so this isn't one combined float expression).
/// Cross-checked against besteon/Ironmon-Tracker's independent
/// reimplementation (PokemonData.lua, calcCatchRate) for the overall shape
/// and constants; that also confirms pret's `Sqrt` is a plain floor square
/// root (Ironmon's version uses `math.floor(math.sqrt(...))` in the same
/// two places) — its exact defining source file wasn't findable directly.
enum CatchChance {
    /// FIRST_BALL...LAST_BALL from include/constants/items.h, minus Safari
    /// Ball — that one only works inside the Safari Zone, uses a completely
    /// different catch-rate substitution (safariCatchFactor) and can't
    /// normally be thrown in a regular battle, so it's out of scope here.
    enum Ball: Int, CaseIterable {
        case masterBall = 1
        case ultraBall = 2
        case greatBall = 3
        case pokeBall = 4
        case netBall = 6
        case diveBall = 7
        case nestBall = 8
        case repeatBall = 9
        case timerBall = 10
        case luxuryBall = 11
        case premierBall = 12

        /// Not read from the cartridge, unlike move/type names — these are
        /// fixed proper nouns with no per-save or per-species variation, so
        /// there's no "wrong address, plausible nonsense" risk to guard
        /// against the way there is for computed battle data.
        var displayName: String {
            switch self {
            case .masterBall: return "MASTER BALL"
            case .ultraBall: return "ULTRA BALL"
            case .greatBall: return "GREAT BALL"
            case .pokeBall: return "POKE BALL"
            case .netBall: return "NET BALL"
            case .diveBall: return "DIVE BALL"
            case .nestBall: return "NEST BALL"
            case .repeatBall: return "REPEAT BALL"
            case .timerBall: return "TIMER BALL"
            case .luxuryBall: return "LUXURY BALL"
            case .premierBall: return "PREMIER BALL"
            }
        }
    }

    /// Everything the formula needs about the target, gathered in one place.
    struct Target {
        var catchRate: Int
        var maxHP: Int
        var currentHP: Int
        var level: Int
        var statusFlags: UInt32
        var types: [Int]
    }

    // MARK: STATUS1_* bits (include/constants/battle.h)
    private static let statusSleep: UInt32 = 0x07      // first 3 bits: sleep turn counter
    private static let statusPoison: UInt32 = 1 << 3
    private static let statusBurn: UInt32 = 1 << 4
    private static let statusFreeze: UInt32 = 1 << 5
    private static let statusParalysis: UInt32 = 1 << 6
    private static let statusToxic: UInt32 = 1 << 7

    /// Percentage chance (0...100) of catching `target` with `ball` on a
    /// single throw. Matches Cmd_handleballthrow, with one caveat: Dive,
    /// Repeat and Timer balls have conditional bonuses (underwater, already
    /// caught this species, turns elapsed) that need state this app doesn't
    /// track. Each falls back to its unconditional multiplier — the same
    /// value the real game uses when the special condition isn't met — so
    /// this only ever under-promises the chance, never overstates it.
    static func percentage(ball: Ball, target: Target) -> Double {
        guard target.maxHP > 0 else { return 0 }

        if ball == .masterBall {
            // Cmd_handleballthrow special-cases this unconditionally
            // (shakes = BALL_3_SHAKES_SUCCESS) without even consulting the
            // odds calculation below.
            return 100
        }

        let ballMultiplier = ballMultiplier(ball, target: target)
        var odds = target.catchRate * ballMultiplier / 10
        odds = odds * (target.maxHP * 3 - target.currentHP * 2) / (3 * target.maxHP)

        if target.statusFlags & (statusSleep | statusFreeze) != 0 {
            odds *= 2
        }
        if target.statusFlags & (statusPoison | statusBurn | statusParalysis | statusToxic) != 0 {
            odds = odds * 15 / 10
        }

        if odds > 254 { return 100 }
        guard odds > 0 else { return 0 }

        let sqrt1 = integerSqrt(16_711_680 / odds)
        guard sqrt1 > 0 else { return 100 }
        let sqrt2 = integerSqrt(sqrt1)
        guard sqrt2 > 0 else { return 100 }

        let shakeOdds = min(1_048_560 / sqrt2, 65536)
        let perShakeProbability = Double(shakeOdds) / 65536.0
        // BALL_3_SHAKES_SUCCESS: needs 4 independent successful shake checks.
        return min(100, pow(perShakeProbability, 4) * 100)
    }

    /// Ball bonus in the ROM's ×10 fixed point (sBallCatchBonuses plus the
    /// switch in Cmd_handleballthrow). Net Ball and Nest Ball use state this
    /// app already has (opponent type, opponent level) and are exact.
    private static func ballMultiplier(_ ball: Ball, target: Target) -> Int {
        switch ball {
        case .masterBall: return 255 // unreachable: percentage() short-circuits above
        case .ultraBall: return 20
        case .greatBall: return 15
        case .pokeBall: return 10
        case .netBall:
            // TYPE_WATER = 11, TYPE_BUG = 6.
            return target.types.contains(11) || target.types.contains(6) ? 30 : 10
        case .diveBall:
            return 10 // unconditional fallback: current map type isn't tracked
        case .nestBall:
            return target.level < 40 ? max(10, 40 - target.level) : 10
        case .repeatBall:
            return 10 // unconditional fallback: Pokédex "caught" flag isn't tracked
        case .timerBall:
            return 10 // unconditional fallback: battle turn counter isn't tracked
        case .luxuryBall, .premierBall:
            return 10
        }
    }

    private static func integerSqrt(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        return Int(Double(value).squareRoot())
    }

    /// A recent opponent snapshot plus the current bag contents, computed
    /// once per frame in EmulatorSession (see its own doc comment for why
    /// this only appears once the player has left the custom battle
    /// controls — e.g. to browse the bag).
    struct Advisor: Equatable {
        struct Entry: Equatable, Identifiable {
            var ball: Ball
            var quantity: Int
            var percentage: Double
            var id: Int { ball.rawValue }
        }
        var opponentNickname: String
        var entries: [Entry]
    }
}
