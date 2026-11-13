import Foundation

/// Pokémon GO's type chart: how much a move of one type does to a Pokémon of given types.
/// Super effective is ×1.6, not very effective ×0.625, and what the main games make immune
/// takes ×0.390625 (two resistances' worth). Both of a Pokémon's types multiply.
public enum TypeChart {
    /// What the game says over a Pokémon as a move hits it: "SUPER EFFECTIVE!" above ×1,
    /// "NOT VERY EFFECTIVE..." below, nothing at ×1 (including ×1.6 × ×0.625).
    public enum Effect: Sendable, Hashable {
        case superEffective, neutral, notVeryEffective
    }

    public static func multiplier(_ move: String, against types: [String]) -> Double {
        types.reduce(1.0) { m, t in
            if immune[move]?.contains(t) == true { return m * 0.390625 }
            if strong[move]?.contains(t) == true { return m * 1.6 }
            if weak[move]?.contains(t) == true { return m * 0.625 }
            return m
        }
    }

    public static func effect(_ move: String, against types: [String]) -> Effect {
        let m = multiplier(move, against: types)
        return m > 1.01 ? .superEffective : m < 0.99 ? .notVeryEffective : .neutral
    }

    private static let strong: [String: Set<String>] = [
        "fighting": ["normal", "rock", "steel", "ice", "dark"],
        "flying": ["fighting", "bug", "grass"],
        "poison": ["grass", "fairy"],
        "ground": ["poison", "rock", "steel", "fire", "electric"],
        "rock": ["flying", "bug", "fire", "ice"],
        "bug": ["grass", "psychic", "dark"],
        "ghost": ["ghost", "psychic"],
        "steel": ["rock", "ice", "fairy"],
        "fire": ["bug", "steel", "grass", "ice"],
        "water": ["ground", "rock", "fire"],
        "grass": ["ground", "rock", "water"],
        "electric": ["flying", "water"],
        "psychic": ["fighting", "poison"],
        "ice": ["flying", "ground", "grass", "dragon"],
        "dragon": ["dragon"],
        "dark": ["ghost", "psychic"],
        "fairy": ["fighting", "dragon", "dark"],
    ]
    private static let weak: [String: Set<String>] = [
        "normal": ["rock", "steel"],
        "fighting": ["flying", "poison", "bug", "psychic", "fairy"],
        "flying": ["rock", "steel", "electric"],
        "poison": ["poison", "ground", "rock", "ghost"],
        "ground": ["bug", "grass"],
        "rock": ["fighting", "ground", "steel"],
        "bug": ["fighting", "flying", "poison", "ghost", "steel", "fire", "fairy"],
        "ghost": ["dark"],
        "steel": ["steel", "fire", "water", "electric"],
        "fire": ["rock", "fire", "water", "dragon"],
        "water": ["water", "grass", "dragon"],
        "grass": ["flying", "poison", "bug", "steel", "fire", "grass", "dragon"],
        "electric": ["grass", "electric", "dragon"],
        "psychic": ["steel", "psychic"],
        "ice": ["steel", "fire", "water", "ice"],
        "dragon": ["steel"],
        "dark": ["fighting", "dark", "fairy"],
        "fairy": ["poison", "steel", "fire"],
    ]
    private static let immune: [String: Set<String>] = [
        "normal": ["ghost"],
        "fighting": ["ghost"],
        "poison": ["steel"],
        "ground": ["flying"],
        "ghost": ["normal"],
        "electric": ["ground"],
        "psychic": ["dark"],
        "dragon": ["fairy"],
    ]
}
