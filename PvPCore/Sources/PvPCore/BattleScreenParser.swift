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
    /// "Attack incoming!": the opponent is throwing a charged move, before its banner.
    case attackIncoming
    /// Your Pokémon fainted ("Switch in a new Pokémon?" while the battle is stopped).
    case yourPokemonFainted
    /// You threw a charged move ("Get Ready!", or your Pokémon's "used" banner).
    case playerChargedMove
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
/// - "Go, X!" is shown for both sides' Pokémon. At the start it's always yours first, then
///   the opponent's lead: the second one names their lead even if the name box is covered
///   (by ManGo's own overlay, say) or it's the same species as yours. Mid-battle, your team
///   is learned (your first "Go", your own charged moves, "Switch in a new Pokémon?"), and a
///   "Go" for a Pokémon that isn't yours is the opponent switching; it's timed from the
///   banner, which shows up about half a second after the switch.
/// - After both leads appear there's a 3-2-1 countdown; the battle starts at a big "GO".
/// - It ends with a big "YOU WIN!" (or lose/draw); the next one starts with "Finding opponent...".
public struct BattleScreenParser: Sendable {
    /// Screen bands, normalized with a top-left origin.
    static let nameBox = (minX: 0.55, minY: 0.08, maxY: 0.2)
    /// Your Pokémon's name box, top-left.
    static let yourNameBox = (maxX: 0.45, minY: 0.08, maxY: 0.2)
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
    /// "Go, X!" names seen this battle before the opponent's lead was known.
    private var goNames: [String] = []
    /// Your Pokémon this battle, as learned from the screen.
    public private(set) var myTeam: Set<String> = []
    /// When "Go, X!" was first seen for each Pokémon, recently.
    private var recentGo: [String: TimeInterval] = [:]
    /// A mid-battle "Go" for a Pokémon not known to be yours: theirs unless the name box
    /// keeps showing their current Pokémon (then it was yours).
    private var pendingGo: (match: NameMatcher.Match, time: TimeInterval)?
    private var switchPromptAt: TimeInterval?
    /// What your name box last showed, and when.
    private var yourCurrent: (key: String, time: TimeInterval)?
    /// When the battle last started running (your buttons appeared), and whether the stop
    /// before it had a charged move in it.
    private var runningSince: TimeInterval?
    private var resumedAfterChargedMove = false
    private var bannerConsumed = false
    /// The switch happens about this long before its "Go, X!" banner shows.
    static let goBannerLead: TimeInterval = 0.5
    private var countdownSeen = false
    private var ended = false
    private var searching = false

    // Within the current stop.
    private var sawAttackIncoming = false
    private var announcedAttackIncoming = false
    private var announcedFaint = false
    private var sawGetReady = false
    private var opponentThrew = false
    private var playerThrew = false
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
            runningSince = isRunning ? read.time : nil
            if isRunning {
                resumedAfterChargedMove = running == false && (sawAttackIncoming || sawGetReady || bannerConsumed || opponentThrew || playerThrew)
                if running == false {
                    events.append(.resumed(freeSwitch: opponentThrew || !sawGetReady))
                }
                sawAttackIncoming = false
                announcedAttackIncoming = false
                announcedFaint = false
                sawGetReady = false
                opponentThrew = false
                playerThrew = false
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
        let cueNow = lines.contains { line in
            let key = NameMatcher.normalize(line.text)
            return key.contains("attackincoming") || key.contains("protectshield") || key.contains("getready")
        }
        if cueNow, bannerConsumed, running == false {
            // A new charged move in the same stop (back-to-back, possibly the same move again).
            bannerConsumed = false
            bannersSeen = []
            sawAttackIncoming = false
            announcedAttackIncoming = false
            sawGetReady = false
            playerThrew = false
        }
        for line in lines {
            let key = NameMatcher.normalize(line.text)
            if key.contains("attackincoming") || key.contains("protectshield") { sawAttackIncoming = true }
            if key.contains("getready") { sawGetReady = true }
            if key.contains("switchinanewpokemon") {
                switchPromptAt = read.time
                if running == false, !announcedFaint {
                    announcedFaint = true
                    events.append(.yourPokemonFainted)
                }
            }
        }
        if sawAttackIncoming, !sawGetReady, running == false, !announcedAttackIncoming {
            announcedAttackIncoming = true
            events.append(.attackIncoming)
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
            if let userMatch = banner.user.flatMap({ matcher.match($0) }) {
                let user = userMatch.key
                if user == opponentKey {
                    // In a mirror match the name can't tell sides apart; use the cue that started the stop.
                    byOpponent = !(sawGetReady && !sawAttackIncoming)
                } else if !myTeam.contains(user), sawAttackIncoming, !sawGetReady {
                    // Their charged move, from a Pokémon whose switch-in was missed (name box covered).
                    byOpponent = true
                    opponentKey = user
                    pending = nil
                    events.append(.opponentAppeared(userMatch, since: read.time))
                } else {
                    byOpponent = false
                }
                if !byOpponent { myTeam.insert(user) }
            } else {
                // Banner read without its name: decide only if exactly one side's cue was seen.
                guard sawAttackIncoming != sawGetReady else { continue }
                byOpponent = sawAttackIncoming
            }
            bannersSeen.insert(moveKey)
            bannerConsumed = true
            if byOpponent {
                opponentThrew = true
                events.append(.opponentChargedMove(moveName: banner.move))
            } else if !playerThrew, running == false {
                playerThrew = true
                events.append(.playerChargedMove)
            }
        }

        // Your Pokémon, from your name box: tells your "Go, X!" from theirs.
        let yourLines = lines.filter {
            $0.box.maxX <= 0.5 && $0.box.minX < Self.yourNameBox.maxX
                && (Self.yourNameBox.minY...Self.yourNameBox.maxY).contains($0.box.midY) && !Self.isOverlayText($0.text)
        }
        if let mine = yourLines.compactMap({ matcher.match($0.text) }).min(by: { $0.distance < $1.distance }), mine.distance == 0 {
            yourCurrent = (mine.key, read.time)
            myTeam.insert(mine.key)
        }

        // "Go, X!" messages: at the start yours then theirs; mid-battle a switch.
        for line in lines where (Self.bannerBand.minY...Self.bannerBand.maxY).contains(line.box.midY) {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard text.lowercased().hasPrefix("go,"),
                  let match = matcher.match(String(text.dropFirst(3))) else { continue }
            if let seen = recentGo[match.key], read.time - seen < 3 {} else { recentGo[match.key] = read.time }
            if opponentKey == nil {
                if goNames.last != match.key { goNames.append(match.key) }
                if goNames.count == 1 { myTeam.insert(match.key) }
                if goNames.count == 2 {
                    opponentKey = match.key
                    pending = nil
                    events.append(.opponentAppeared(match, since: read.time))
                }
            } else if match.key != opponentKey, pendingGo?.match.key != match.key,
                      !(yourCurrent?.key == match.key && read.time - yourCurrent!.time < 1.5) {
                // A species you have too is theirs only while your box shows something else.
                let yourBoxShowsAnother = yourCurrent.map { $0.key != match.key && read.time - $0.time < 1.0 } ?? false
                if myTeam.contains(match.key) {
                    if yourBoxShowsAnother { pendingGo = (match, recentGo[match.key] ?? read.time) }
                } else if let prompt = switchPromptAt, read.time - prompt < 20 {
                    myTeam.insert(match.key)  // your replacement after your Pokémon fainted
                    switchPromptAt = nil
                } else {
                    pendingGo = (match, recentGo[match.key] ?? read.time)
                }
            }
        }

        // The opponent's Pokémon.
        let nameLines = lines.filter {
            $0.box.minX >= Self.nameBox.minX && (Self.nameBox.minY...Self.nameBox.maxY).contains($0.box.midY)
                && !Self.isOverlayText($0.text)
        }
        let shown = nameLines.compactMap({ matcher.match($0.text) }).min(by: { $0.distance < $1.distance })
        if let match = shown {
            let same = pending?.key == match.key
            let count = same ? pending!.count + 1 : 1
            var since = same ? pending!.since : read.time
            pending = (match.key, count, since)
            if count >= requiredReads, match.key != opponentKey {
                // A "Go, X!" for it just before marks when a switch made mid-battle happened
                // (not one made during a stop, like straight after their charged move).
                if let go = recentGo[match.key], since - go < 3, !(resumedAfterChargedMove && runningSince.map { go - $0 < 1.5 } ?? false) {
                    since = min(since, go - Self.goBannerLead)
                }
                opponentKey = match.key
                if pendingGo?.match.key == match.key { pendingGo = nil }
                events.append(.opponentAppeared(match, since: since))
            }
        } else {
            pending = nil
        }

        // A mid-battle "Go" not yet known to be yours, resolved after 0.75s: yours if your
        // name box shows it; theirs if your box shows something else, or (your box covered)
        // if their box doesn't still show their current Pokémon.
        if let go = pendingGo, yourCurrent?.key == go.match.key, read.time - yourCurrent!.time < 1.5 {
            pendingGo = nil
        }
        if let go = pendingGo, read.time - go.time >= 0.75 {
            pendingGo = nil
            let yourBoxReadable = yourCurrent.map { read.time - $0.time < 1.0 } ?? false
            if !yourBoxReadable, let shown, shown.key == opponentKey {
                myTeam.insert(go.match.key)
            } else if go.match.key != opponentKey {
                opponentKey = go.match.key
                pending = nil
                let midBattle = !(resumedAfterChargedMove && runningSince.map { go.time - $0 < 1.5 } ?? false)
                events.append(.opponentAppeared(go.match, since: midBattle ? go.time - Self.goBannerLead : go.time))
            }
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
        goNames = []
        myTeam = []
        yourCurrent = nil
        recentGo = [:]
        pendingGo = nil
        switchPromptAt = nil
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
