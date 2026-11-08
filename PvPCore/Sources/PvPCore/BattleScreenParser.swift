import Foundation

/// Something that happened on the battle screen.
public enum BattleEvent: Equatable, Sendable {
    /// The charged move buttons disappeared: a charged move is coming, or a faint. The
    /// battle itself may run a moment longer, while a queued charged move waits for the
    /// thrower's fast move to finish.
    case stopped
    /// The battle UI is back. `freeSwitch`: their switch right after takes 0 turns. That's
    /// after a faint, or when the stop's last charged move was theirs; after yours (even
    /// one they threw before), it costs them a turn.
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
    /// Your charged-move labels changed: your active Pokémon changed.
    case playerChangedPokemon
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
    private var playerAlive: Int?
    private var pendingPlayerAlive: (value: Int, count: Int, first: TimeInterval, previous: TimeInterval)?
    private var replacementPendingAt: TimeInterval?
    private var replacementGoAt: TimeInterval?
    /// Your active Pokémon's charged moves, from its buttons (normalized names).
    public private(set) var yourButtonLabels: Set<String> = []
    private var pendingButtonLabels: (labels: Set<String>, count: Int)?
    private var running: Bool?
    private var missingButtons: (first: TimeInterval, previous: TimeInterval)?
    private var lastScreenTime: TimeInterval?
    /// Bounds of the first missing-button observation, retained while confirming a stop.
    public private(set) var stopObservation: (first: TimeInterval, previous: TimeInterval)?
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
    /// When their name box last showed their current Pokémon.
    private var opponentShownAt: TimeInterval?
    /// When their name box last showed the Pokémon the latest `opponentAppeared` replaced (nil
    /// if it was never read): gone before the battle restarted, they switched during the stop.
    public private(set) var replacedLastShownAt: TimeInterval?
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
    /// Whose charged move came last in this stop (nil: none). A switch right after it is
    /// free only for the side that threw it.
    private var lastThrowWasTheirs: Bool?
    private var bannersSeen: Set<String> = []
    /// A charged move's cue was on the last read.
    private var cueOnLastRead = false
    /// How the last battle ended: "won", "lost" or "draw".
    public private(set) var lastResult: String?
    /// Your charged moves' banners ("Blaziken used Blaze Kick!") so far, and the latest one.
    public private(set) var yourBannerCount = 0
    public private(set) var yourLastBanner: (user: String?, move: String)?

    public init(data: GameData) {
        matcher = NameMatcher(data: data)
        chargedMoveNames = Set(data.moves.values.filter { !$0.isFast && $0.energy > 0 }.map { NameMatcher.normalize($0.name) })
    }

    public mutating func process(_ read: ScreenRead) -> [BattleEvent] {
        var events: [BattleEvent] = []
        guard read.textReadSucceeded != false else { return events }
        let previousTime = lastScreenTime ?? read.time
        lastScreenTime = read.time
        let lines = read.lines

        // Start and end of a battle: big text in the middle of the screen. "GOOD EFFORT!" is two
        // rows, read as two lines ("GOOD", "EFFORT!"), and "YOU WIN!" sometimes splits too.
        let bigText = lines.filter { (0.35...0.65).contains($0.box.midY) && $0.box.height > 0.04 }
            .sorted { (($0.box.minY / 0.03).rounded(), $0.box.minX) < (($1.box.minY / 0.03).rounded(), $1.box.minX) }
            .map { NameMatcher.normalize($0.text) }.joined()
        if ["youwin", "goodeffort", "youlose", "youlost"].contains(where: bigText.contains) {
            if !ended {
                lastResult = bigText.contains("youwin") ? "won" : "lost"
                events.append(.battleEnded)
            }
            ended = true
            endOfBattle()
            return events
        }
        for line in lines where (0.35...0.65).contains(line.box.midY) {
            let key = NameMatcher.normalize(line.text)
            if key.contains("findingopponent") {
                if !searching { events.append(.searching) }
                searching = true
                endOfBattle()
                return events
            }
            if line.box.height > 0.04, key == "draw" {
                if !ended {
                    lastResult = "draw"
                    events.append(.battleEnded)
                }
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
        let labels = Set(lines.filter {
            $0.box.midY >= Self.buttonBand.minY && Self.isButtonLabel($0.text)
                && chargedMoveNames.contains(NameMatcher.normalize($0.text))
        }.map { NameMatcher.normalize($0.text) })
        // Your pokéballs, top left. ManGo's card often sits over them, and its text averages to
        // the gray of fainted balls: none left would end every battle as the card appears. So a
        // faint is one ball going dark, never all of them (the results screen ends the battle).
        if let alive = read.playerAlive, alive > 0 {
            if let before = playerAlive, alive == before - 1 {
                if pendingPlayerAlive?.value == alive { pendingPlayerAlive!.count += 1 }
                else { pendingPlayerAlive = (alive, 1, read.time, previousTime) }
                if let pending = pendingPlayerAlive, pending.count >= requiredReads {
                    pendingPlayerAlive = nil
                    playerAlive = alive
                    replacementPendingAt = pending.first
                    replacementGoAt = nil
                    if running == true {
                        stopObservation = (pending.first, pending.previous)
                        events.append(.stopped)
                    }
                    running = false
                    announcedFaint = true
                    events.append(.yourPokemonFainted)
                }
            } else {
                pendingPlayerAlive = nil
                if playerAlive == nil { playerAlive = alive }
            }
        }
        var isRunning = !labels.isEmpty
        if let faint = replacementPendingAt {
            let goVisible = lines.contains { $0.text.lowercased().hasPrefix("go,") }
            if goVisible, replacementGoAt == nil { replacementGoAt = read.time }
            let newBar = read.hpTraceVerified == true && (read.hpTrace ?? []).contains {
                $0.count == 3 && $0[0] >= faint + 0.25 && $0[0] <= read.time && $0[1] * $0[2] >= 3
            }
            let changed = !labels.isEmpty && !labels.isSubset(of: yourButtonLabels)
            let goFinished = replacementGoAt.map { !goVisible && read.time - $0 >= 0.5 } ?? false
            if isRunning && changed && (newBar || goFinished) {
                replacementPendingAt = nil
                replacementGoAt = nil
            } else { isRunning = false }
        }
        let explicitStop = lines.contains {
            let key = NameMatcher.normalize($0.text)
            return key.contains("attackincoming") || key.contains("protectshield")
                || key.contains("getready") || key.contains("switchinanewpokemon")
        }
        if !isRunning, running == true {
            if missingButtons == nil { missingButtons = (read.time, previousTime) }
            // One failed recognition of the labels must not stop the battle clock.
            // Explicit charged-move/faint cues are strong enough to act immediately.
            if !explicitStop, missingButtons?.first == read.time { isRunning = true }
        } else if isRunning {
            missingButtons = nil
        }
        if isRunning != running {
            runningSince = isRunning ? read.time : nil
            if isRunning {
                resumedAfterChargedMove = running == false && (sawAttackIncoming || sawGetReady || bannerConsumed || opponentThrew || playerThrew)
                if running == false {
                    events.append(.resumed(freeSwitch: lastThrowWasTheirs ?? true))
                }
                sawAttackIncoming = false
                announcedAttackIncoming = false
                announcedFaint = false
                sawGetReady = false
                opponentThrew = false
                playerThrew = false
                lastThrowWasTheirs = nil
                bannersSeen = []
            } else if running == true {
                stopObservation = missingButtons ?? (read.time, previousTime)
                missingButtons = nil
                events.append(.stopped)
            }
            running = isRunning
        }

        if replacementPendingAt == nil, !labels.isEmpty {
            if yourButtonLabels.isEmpty { yourButtonLabels = labels }
            else if !labels.isSubset(of: yourButtonLabels) {
                let count = pendingButtonLabels?.labels == labels ? pendingButtonLabels!.count + 1 : 1
                pendingButtonLabels = (labels, count)
                if count >= requiredReads {
                    yourButtonLabels = labels
                    pendingButtonLabels = nil
                    events.append(.playerChangedPokemon)
                }
            } else { pendingButtonLabels = nil }
        }

        // Charged move cues and banners.
        if running == false, lines.contains(where: { NameMatcher.normalize($0.text).hasPrefix("blocked") }) {
            events.append(.shielded)
        }
        let cueNow = lines.contains { line in
            let key = NameMatcher.normalize(line.text)
            return key.contains("attackincoming") || key.contains("protectshield") || key.contains("getready")
        }
        // A cue still up from this charged move isn't a new one: "No Protect Shields remaining!"
        // stays up as its banner shows (Mightyena's one Poison Fang, 125109 at 1:59.2). The next
        // charged move's cue comes after this one's banner has gone.
        let bannerUp = lines.contains {
            (Self.bannerBand.minY...Self.bannerBand.maxY).contains($0.box.midY) && !$0.text.contains("→")
                && Self.parseBanner($0.text) != nil
        }
        let newCue = cueNow && !cueOnLastRead && !bannerUp
        cueOnLastRead = cueNow
        if newCue, bannerConsumed, running == false {
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
            lastThrowWasTheirs = false
            events.append(.playerChargedMove)
        }
        for line in lines where (Self.bannerBand.minY...Self.bannerBand.maxY).contains(line.box.midY) {
            // ManGo's own app shows its last event ("Greninja (Shadow) used Hydro Cannon (28 → 0)"):
            // read with ManGo in front, it isn't the game's banner. (OCR can add a stray "•" to a
            // real banner, "Stunfisk used Earthquakel •", so only the arrow rules it out.)
            guard !line.text.contains("→"), let banner = Self.parseBanner(line.text) else { continue }
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
                    replaced(by: user, at: nil)
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
            if !byOpponent {
                yourBannerCount += 1
                yourLastBanner = (banner.user, banner.move)
            }
            if byOpponent {
                opponentThrew = true
                lastThrowWasTheirs = true
                events.append(.opponentChargedMove(moveName: banner.move))
            } else if !playerThrew, running == false {
                playerThrew = true
                lastThrowWasTheirs = false
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
                    replaced(by: match.key, at: nil)
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
            if match.key == opponentKey { opponentShownAt = read.time }
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
                replaced(by: match.key, at: read.time)
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
                replaced(by: go.match.key, at: nil)
                pending = nil
                let midBattle = !(resumedAfterChargedMove && runningSince.map { go.time - $0 < 1.5 } ?? false)
                events.append(.opponentAppeared(go.match, since: midBattle ? go.time - Self.goBannerLead : go.time))
            }
        }
        return events
    }

    /// Their Pokémon is now `key` (shown in their name box at `shownAt`, if it was).
    private mutating func replaced(by key: String, at shownAt: TimeInterval?) {
        replacedLastShownAt = opponentKey == nil ? nil : opponentShownAt
        opponentShownAt = shownAt
        opponentKey = key
    }

    /// Between battles: forget the opponent so the next battle's lead is reported even if
    /// it's the same species.
    private mutating func endOfBattle() {
        opponentKey = nil
        opponentShownAt = nil
        replacedLastShownAt = nil
        pending = nil
        running = nil
        missingButtons = nil
        stopObservation = nil
        lastScreenTime = nil
        started = false
        goNames = []
        myTeam = []
        yourCurrent = nil
        recentGo = [:]
        pendingGo = nil
        switchPromptAt = nil
        countdownSeen = false
        playerAlive = nil
        pendingPlayerAlive = nil
        replacementPendingAt = nil
        replacementGoAt = nil
        yourButtonLabels = []
        pendingButtonLabels = nil
        runningSince = nil
        resumedAfterChargedMove = false
        bannerConsumed = false
        sawAttackIncoming = false
        announcedAttackIncoming = false
        announcedFaint = false
        sawGetReady = false
        opponentThrew = false
        playerThrew = false
        lastThrowWasTheirs = nil
        bannersSeen = []
    }

    static func isButtonLabel(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t == t.uppercased() && !t.contains(where: \.isNumber) && !t.contains("•") && !t.contains("·")
    }

    /// Text from ManGo's own overlay card: "vs Sableye (Shadow)", "Bench: …", "★ Foul Play · 40",
    /// or its app's event log: "Greninja (Shadow) used Hydro Cannon (28 → 0)".
    static func isOverlayText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("vs ") || t.hasPrefix("bench") || t.contains("•") || t.contains("·") || t.contains("★")
            || t.contains("→") || t == "paused" || t == "ready" || t == "battle over"
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
