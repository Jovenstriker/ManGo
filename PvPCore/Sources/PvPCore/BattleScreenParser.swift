import Foundation

/// Something that happened on the battle screen.
public enum BattleEvent: Equatable, Sendable {
    /// The charged move buttons disappeared: a charged move is coming, or a faint. The
    /// battle itself may run a moment longer, while a queued charged move waits for the
    /// thrower's fast move to finish.
    case stopped
    /// The battle UI is back. `freeSwitch` is true unless the stop was only your own
    /// charged move: right after the opponent's charged move or a faint, their switch
    /// takes 0 turns.
    case resumed(freeSwitch: Bool)
    /// The opponent's Pokémon, read from the name box in the top-right. `since` is when
    /// the name was first read, before it was confirmed by the following reads.
    case opponentAppeared(NameMatcher.Match, since: TimeInterval)
    /// The opponent threw a charged move, read from the "X used Y!" banner.
    case opponentChargedMove(moveName: String)
    /// You threw a charged move ("Get Ready!", or your Pokémon's "used" banner).
    case playerChargedMove
    /// The opponent's charged move is starting ("Attack incoming!").
    case opponentChargeStarted
    /// The countdown's "GO": turn 0 of the battle.
    case battleStarted
    /// The countdown's "2": "GO" should follow in about this long. A fallback if GO is missed.
    case countdown(goExpectedIn: TimeInterval)
    /// "YOU WIN!" / "YOU LOSE" / a draw.
    case battleEnded
    /// "Finding opponent…": matchmaking for the next battle.
    case searching
    /// "BLOCKED!": a charged move was shielded.
    case shielded
}

/// Turns screen reads of a Pokémon GO battle into `BattleEvent`s.
///
/// Worked out from a real battle recording:
/// - Your charged move buttons ("FLAMETHROWER", "SKY ATTACK") sit at the bottom of the
///   screen exactly while the battle is running. They vanish the moment either side's
///   charged move starts, or a Pokémon faints, and return when the battle resumes.
/// - The opponent's Pokémon is named in the top-right box ("CP 1498 Stunfisk").
/// - Charged moves end with a banner, "Stunfisk used Discharge!". Opponent charged
///   moves start with "Attack incoming!"; yours with "Get Ready!".
/// - "Go, X!" is shown for both sides' switches, so it's not used.
/// - After both leads appear there's a 3-2-1 countdown; the battle starts at a big "GO".
/// - It ends with a big "YOU WIN!" (or lose/draw); the next one starts with "Finding opponent...".
public struct BattleScreenParser: Sendable {
    /// Screen bands, normalized with a top-left origin.
    static let nameBox = (minX: 0.55, minY: 0.08, maxY: 0.2)
    static let bannerBand = (minY: 0.15, maxY: 0.5)
    static let buttonBand = (minY: 0.8, maxY: 1.0)

    public let matcher: NameMatcher
    private let chargedMoveNames: Set<String>
    /// Reads in a row a name must appear in before it counts.
    public var requiredReads = 2

    public private(set) var opponentKey: String?
    private var pending: (key: String, count: Int, since: TimeInterval)?
    private var running: Bool?
    private var started = false
    private var countdownSeen = false
    private var ended = false
    private var searching = false

    // Within the current stop.
    private var sawAttackIncoming = false
    private var sawGetReady = false
    private var opponentThrew = false
    private var playerThrew = false
    private var opponentCharging = false
    private var bannersSeen: Set<String> = []

    public init(data: GameData) {
        matcher = NameMatcher(data: data)
        chargedMoveNames = Set(data.moves.values.filter { !$0.isFast && $0.energy > 0 }.map { NameMatcher.normalize($0.name) })
    }

    public mutating func process(_ read: ScreenRead) -> [BattleEvent] {
        var events: [BattleEvent] = []
        let lines = read.lines

        // Start and end of a battle: big text in the middle of the screen.
        for line in lines where (0.35...0.65).contains(line.box.midY) {
            let key = NameMatcher.normalize(line.text)
            if key.contains("findingopponent") {
                if !searching { events.append(.searching) }
                searching = true
                endOfBattle()
                return events
            }
            // Win: "YOU WIN!". Loss: "GOOD EFFORT!".
            if line.box.height > 0.04, key.contains("youwin") || key.contains("goodeffort") || key.contains("youlose")
                || key.contains("youlost") || key == "draw" {
                if !ended { events.append(.battleEnded) }
                ended = true
                endOfBattle()
                return events
            }
            // The stylized "GO" often reads as "CO". The countdown's "2" comes ~1.6s before it.
            if line.box.height > 0.08, key == "go" || key == "co", !started {
                started = true
                events.append(.battleStarted)
            }
            if line.box.height > 0.12, line.text.trimmingCharacters(in: .whitespaces) == "2", !started, !countdownSeen {
                countdownSeen = true
                events.append(.countdown(goExpectedIn: 1.6))
            }
        }
        searching = false
        ended = false

        // Running or stopped, from the charged move buttons.
        // The game's buttons are ALL CAPS with no numbers ("SHADOW SNEAK"); ManGo's own
        // overlay card, which the screen recording also sees, says "Drain Punch • 40".
        let isRunning = lines.contains { line in
            line.box.midY >= Self.buttonBand.minY && Self.isButtonLabel(line.text)
                && chargedMoveNames.contains(NameMatcher.normalize(line.text))
        }
        if isRunning != running {
            if isRunning {
                if running == false {
                    events.append(.resumed(freeSwitch: opponentThrew || !sawGetReady))
                }
                sawAttackIncoming = false
                sawGetReady = false
                opponentThrew = false
                playerThrew = false
                opponentCharging = false
                bannersSeen = []
            } else if running == true {
                events.append(.stopped)
            }
            running = isRunning
        }

        // Charged move cues and banners.
        if running == false, lines.contains(where: { NameMatcher.normalize($0.text).hasPrefix("blocked") }) {
            events.append(.shielded)
        }
        for line in lines {
            let key = NameMatcher.normalize(line.text)
            if key.contains("attackincoming") || key.contains("protectshield") { sawAttackIncoming = true }
            if key.contains("getready") { sawGetReady = true }
        }
        if sawAttackIncoming, running == false, !opponentCharging {
            opponentCharging = true
            events.append(.opponentChargeStarted)
        }
        if sawGetReady, running == false, !playerThrew {
            playerThrew = true
            events.append(.playerChargedMove)
        }
        for line in lines where (Self.bannerBand.minY...Self.bannerBand.maxY).contains(line.box.midY) {
            guard let banner = Self.parseBanner(line.text) else { continue }
            let moveKey = NameMatcher.normalize(banner.move)
            // The banner stays up for ~2s and OCR varies ("Discharge!", "Dischargel"): count it once.
            let seen = bannersSeen.contains { NameMatcher.editDistance($0, moveKey, limit: 2) <= 2 }
            guard moveKey.count >= 3, !seen else { continue }
            let byOpponent: Bool
            if let user = banner.user.flatMap({ matcher.match($0)?.key }) {
                // In a mirror match the name can't tell sides apart; use the cue that started the stop.
                byOpponent = user == opponentKey && !(sawGetReady && !sawAttackIncoming)
            } else {
                // Banner read without its name: decide only if exactly one side's cue was seen.
                guard sawAttackIncoming != sawGetReady else { continue }
                byOpponent = sawAttackIncoming
            }
            bannersSeen.insert(moveKey)
            if byOpponent {
                opponentThrew = true
                events.append(.opponentChargedMove(moveName: banner.move))
            } else if !playerThrew, running == false {
                playerThrew = true
                events.append(.playerChargedMove)
            }
        }

        // The opponent's Pokémon.
        let nameLines = lines.filter {
            $0.box.minX >= Self.nameBox.minX && (Self.nameBox.minY...Self.nameBox.maxY).contains($0.box.midY)
                && !Self.isOverlayText($0.text)
        }
        if let match = nameLines.compactMap({ matcher.match($0.text) }).min(by: { $0.distance < $1.distance }) {
            let same = pending?.key == match.key
            let count = same ? pending!.count + 1 : 1
            let since = same ? pending!.since : read.time
            pending = (match.key, count, since)
            if count >= requiredReads, match.key != opponentKey {
                opponentKey = match.key
                events.append(.opponentAppeared(match, since: since))
            }
        } else {
            pending = nil
        }
        return events
    }

    /// Between battles: forget the opponent so the next battle's lead is reported even if
    /// it's the same species.
    private mutating func endOfBattle() {
        opponentKey = nil
        pending = nil
        running = nil
        started = false
        countdownSeen = false
    }

    static func isButtonLabel(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t == t.uppercased() && !t.contains(where: \.isNumber) && !t.contains("•") && !t.contains("·")
    }

    /// Text from ManGo's own overlay card: "vs Sableye (Shadow)", "Bench: …", "★ Foul Play · 40".
    static func isOverlayText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("vs ") || t.hasPrefix("bench") || t.contains("•") || t.contains("·") || t.contains("★")
            || t == "paused" || t == "ready" || t == "battle over"
    }

    public mutating func reset() {
        self = BattleScreenParser(matcher: matcher, chargedMoveNames: chargedMoveNames, requiredReads: requiredReads)
    }

    private init(matcher: NameMatcher, chargedMoveNames: Set<String>, requiredReads: Int) {
        self.matcher = matcher
        self.chargedMoveNames = chargedMoveNames
        self.requiredReads = requiredReads
    }

    /// "Stunfisk used Discharge!" -> ("Stunfisk", "Discharge"). OCR sometimes drops the
    /// space ("Stunfiskused") or the name ("used Discharge!").
    static func parseBanner(_ text: String) -> (user: String?, move: String)? {
        let text = text.folding(options: .diacriticInsensitive, locale: nil)  // "úsed"
        guard let range = text.range(of: "used", options: .caseInsensitive) else { return nil }
        let user = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        let move = text[range.upperBound...].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters).union(.symbols))
        guard !move.isEmpty else { return nil }
        return (user.isEmpty ? nil : user, move)
    }
}
