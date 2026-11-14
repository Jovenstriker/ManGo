import Foundation

/// Drives an `OpponentTracker` from screen reads, with no taps:
/// - the clock stops whenever the battle UI is gone (charged moves, faints) and restarts when it's back
/// - the opponent's charged moves subtract their cost; a move only one form can learn fixes the form
/// - a new name in the top-right is a switch, a faint replacement, or (as a 4th name) a new battle
public struct BattleAutomation: Sendable {
    public private(set) var parser: BattleScreenParser
    public let data: GameData
    /// What happened, newest last, for showing in the app.
    public private(set) var log: [String] = []
    /// Diagnostics emitted by the latest process call, independent of the bounded UI log.
    public private(set) var logThisRead: [String] = []
    public private(set) var throwsThisRead: [ChargedMoveObservation] = []
    /// An earlier charged move of theirs, recounted by what this read showed (a tie it won with
    /// yours): it replaces the observation with the same `time`.
    public private(set) var throwRevisedThisRead: ChargedMoveObservation?
    private var lastTheirThrow: ChargedMoveObservation?

    public struct ChargedMoveObservation: Sendable {
        public let time: TimeInterval
        public let speciesId: String
        public let move: Move
        public let fastMove: Move?
        public internal(set) var energyBefore: Int
        public internal(set) var energyAfter: Int
        /// The raw estimate before an observed spend forced reconciliation.
        public internal(set) var energyBeforeReconciliation: Int
        /// Modelled fast moves since this Pokémon's previous charged move, including
        /// moves before switching out. Unlike energy differences, this survives the cap.
        public internal(set) var fastMoveCount: Int?
    }

    /// The "YOU WIN!"/"YOU LOSE" screen was shown. The last battle stays on screen until
    /// the next one starts.
    public private(set) var isBattleOver = false
    /// When "YOU WIN!" / "GOOD EFFORT!" was read.
    public private(set) var battleEndedAt: TimeInterval?
    // Timing, fitted on four recorded battles against the opponent's fast move counts
    // counted by watching the recordings (see "Battle Logs/*.log"): these values get all 26
    // counts and checkpoints exactly, as do several neighbors.
    // Reads come 4 times a second, so the screen changed up to 0.25s before it's seen.

    /// The battle stops this long before your buttons are first read as gone.
    public var stopLead: TimeInterval = 0.125
    /// For your charged moves, the battle runs on while your fast move finishes and
    /// freezes this long before "Get Ready!" is read (if that's after the buttons vanish).
    public var playerFreezeBeforeCue: TimeInterval = 0.75
    /// The battle resumes this long before your buttons are read again after a charged move...
    public var resumeLead: TimeInterval = 0.25
    /// ...and this long after a faint, when the next Pokémon comes in. (Fearow after
    /// Cramorant's faint, and Ninetales after Melmetal's, both start counting about when
    /// your buttons come back.)
    public var faintResumeLead: TimeInterval = 0.25
    /// At a 0-turn switch after a charged move, when the frames show your buttons fading back in
    /// since the last read, the battle resumed this long before the first of them (012748:
    /// Stunfisk's 5 Thunder Shocks and a sneak after Weather Ball, not 4; 0.14-0.17s fit then).
    public var fadeInLead: TimeInterval = 0.15
    /// Buttons this empty look dark as they fade in, like hidden ones: no fade-in to see
    /// (221337: Nidoqueen's 7 Mud Slaps after Guzzlord blocked yours, not 6).
    static let fadeInMinimumFill = 0.15
    /// This stop's restart from the frames, if they showed it.
    private var fadeInRestart: TimeInterval?
    /// Testing: count the lead's fast moves in the opening stretch (GO to the first stop)
    /// from the drops in your HP bar instead of timing them. Off: exact for big hits (testV2's
    /// 6 Thunder Shocks, Doublade's 7 Shadow Claws), but in half-size recordings a small hit
    /// (Mud Shot on Altaria, Sand Attack) is a pixel and most are missed. To be tried on
    /// phone-recorded battles, whose bar is measured at full size.
    public var useHitCount = false
    /// Start the lead's clock later if its first hit on you ("…EFFECTIVE" over your Pokémon)
    /// shows it began later than GO + `goDelay`.
    public var useFirstHitText = true
    private var leadStartChecked = false
    /// When the lead's first fast move began, as counted.
    private var leadStartedAt: TimeInterval?
    /// This stretch's restart was seen (their move in progress hit you), not guessed from your buttons.
    private var restartSeen = false
    /// Their Pokémon in now came in by a switch (not a faint, not the lead) since play last restarted.
    private var switchedInSinceRestart = false
    /// The battle's first turn begins this long after "GO" is first read: GO stays on screen
    /// a moment before anyone can attack. (The phone-saved Doublade battle: 7 Shadow Claws,
    /// not 8.) Of the starts tried after GO on November 8, 2026, only this one fits every lead's
    /// hand count (0.1s loses 132243's, 0.3s 174243's and 144330's). With no countdown or GO at
    /// all, the lead's clock starts with your buttons instead.
    public var goDelay: TimeInterval = 0.2
    /// GO shows about 0.65s and a first read usually lags it by about 0.15s: one that caught it
    /// fading came about this much later.
    static let fadingGoLag: TimeInterval = 0.5
    /// Where the battle restarts relative to your buttons coming back, used with "a charged
    /// move starts as a fast move finishes" to correct the restart guess when the opponent
    /// throws: around them (Melmetal's straight-away Double Iron Bash restarted about when they
    /// came back, Ninetales about 0.4s after), also after they blocked yours (221337: Mimikyu's
    /// 6 Shadow Claws from 6:49.6 to its Shadow Sneak, by the user's count, not 7).
    public var restartWindow: ClosedRange<TimeInterval> = -0.5 ... 0.4
    /// Testing: start these species on a given fast move instead of PvPoke's recommended one.
    public var assumedFastMoves: [String: String] = [:]
    private var buttonsBackAt: TimeInterval?
    /// The last read before your buttons came back.
    private var readBeforeButtonsBack: TimeInterval?
    /// A hit on you was showing on the last read.
    private var hitOverYouLastRead = false
    /// The read by which their fast move in progress at your charged move had hit you this stop,
    /// whether a "Go, X!" already showed then, and whether your Pokémon went down to it after.
    private var inProgressLandedBy: TimeInterval?
    /// The read before it, which didn't show the hit yet.
    private var inProgressLandedAfter: TimeInterval = 0
    private var goShownAtHit = false
    private var inProgressRuledOut = false
    private var playerChargedThisStop = false
    /// The last stop ended with your charged move, so their fast move in progress landed as play resumed.
    private var lastResumeAfterYourChargedMove = false
    private var playerChangedSinceResume = false
    private var cadence = FastMoveCadence()
    private var recentVerifiedHP: [[Double]] = []
    private var chargedMoveThisStop = false
    /// Your buttons' fill on recent frames, the gaps between your fast moves landing in it (see
    /// `YourFastMoves`), when the buttons came back (before a correction moves the restart), and
    /// whether this stretch's restart was checked against your first fast move.
    private var fillSamples: [[Double]] = []
    private var yourGaps: [TimeInterval] = []
    private var buttonsResumedAt: TimeInterval = -.infinity
    private var restartChecked = true
    /// Your Pokémon fainted in the stop: the restart is checked once your replacement's buttons show.
    private var awaitingYourReplacement = false
    /// The opponent starts its first fast move this long after the restart your fast moves show:
    /// the old restart guess counted their reaction too. 0.3-0.45s all fit every hand count
    /// (testV2's Ninetales threw 2 Embers, not 3; Shadow Greninja sneaked at 5:41 and 9:24).
    static let opponentReaction: TimeInterval = 0.35

    private var lastTime: TimeInterval = -.infinity
    private var previousReadTime: TimeInterval = -.infinity
    /// The charged move buttons are hidden, and the clock is stopped.
    private var stopped = false
    private var lastStopAt: TimeInterval = -.infinity
    private var resumedAt: TimeInterval = -.infinity
    private var freeSwitchUntil: TimeInterval = -.infinity
    private var opponentThrewThisStop = false
    /// Play ran between their charged move and now, in this stop: your fast move hit them after
    /// their banner had gone, or your next Pokémon came out.
    private var playSinceTheirChargedMove = false
    /// Their Pokémon fainted in this stop and its replacement came in.
    private var theirFaintThisStop = false
    /// ...after your last charged move: the one in now had nothing in progress at it.
    private var replacedSinceYourChargedMove = false
    /// A hit on their Pokémon was showing on the last read.
    private var hitOverThemLastRead = false
    /// Your charged move buttons as last read and since when, and when the opponent's Pokémon
    /// now in was named: a hit's text is read for type only once both have settled.
    private var yourLabels: Set<String> = []
    private var yourLabelsSince: TimeInterval = -.infinity
    private var opponentSeenAt: TimeInterval = -.infinity
    /// Since when a hit's text has shown over your Pokémon without a break, if it shows now.
    private var hitTextSince: TimeInterval?
    /// A charged move's text shows over the Pokémon it hit as play restarts (Persian's Night
    /// Slash "NOT VERY EFFECTIVE..." on your Thievul, 020853; Ursaluna's Fire Punch on your
    /// Jumpluff, 022052); a fast move started at the restart lands a turn later at the soonest.
    static let hitTextAfterRestart: TimeInterval = 0.5
    /// A line for the card about a change it would otherwise make silently, and when.
    public private(set) var cardNote: (text: String, time: TimeInterval)?
    /// Your Pokémon fainted in this stop ("Switch in a new Pokémon?").
    private var yourFaintThisStop = false
    /// Red pokéballs in their name box (Pokémon left): the latest count, when it was read,
    /// and when it last went down. A ball goes dark as the Pokémon faints, before the stop is
    /// seen and its replacement named.
    private var opponentAlive: Int?
    private var opponentAliveAt: TimeInterval = -.infinity
    private var aliveDroppedAt: TimeInterval = -.infinity
    /// A drop this long before the stop still belongs to it.
    static let faintBallLead: TimeInterval = 3
    /// Marked fainted before the pokéballs could be read: checked against the next count.
    private var unconfirmedFaint: (speciesId: String, stop: TimeInterval)?
    private var goAt: TimeInterval?
    /// The lead is known but the countdown hasn't reached GO: its clock waits.
    private var awaitingGo = false
    /// When the lead was named while waiting for GO, and when the battle seemed to resume
    /// meanwhile: the buttons show during the countdown.
    private var leadNamedAt: TimeInterval = 0
    private var resumedBeforeGo: TimeInterval?
    /// Longest the lead waits for a GO that isn't read, from when it's named.
    static let goWait: TimeInterval = 4


    /// A switch shown this soon after your buttons come back was chosen during the stop.
    static let quickSwitchWindow: TimeInterval = 0.5

    /// A switch this soon after the battle resumes counts as part of that stop.
    static let afterStopWindow: TimeInterval = 1.5

    // Your HP bar in the opening stretch: its smoothed level, the lowest it has settled at,
    // a drop waiting for a second frame, and the time and size of each hit.
    private var hpRecent: [Double] = []
    private var hpLowest: Double?
    private var hpDropSince: TimeInterval?
    private var leadHits: [(t: TimeInterval, pixels: Double)] = []
    private var openingDone = false
    /// A hit counts if your bar drops at least this many pixels and holds for two frames
    /// (a bar flickers by a pixel).
    static let hitPixels = 1.5
    /// This battle so far, for its summary, and the ones finished since the app last took them.
    private var battleRecord = BattleSummaryRecord()
    private var completedBattles: [BattleSummary] = []
    private var yourBannersNamed = 0
    private var summaryButtonLabels: Set<String> = []
    private var summaryPendingLabels: (labels: Set<String>, count: Int, at: Double, inPlay: Bool)?

    public init(data: GameData) {
        self.data = data
        parser = BattleScreenParser(data: data)
    }

    /// Forgets everything, as if the screen reader had just started. Finished battles' summaries
    /// stay until taken.
    public mutating func reset() {
        let done = completedBattles
        self = BattleAutomation(data: data)
        completedBattles = done
    }

    /// Battles that ended since the last call, for the battle history.
    public mutating func takeCompletedBattles() -> [BattleSummary] {
        defer { completedBattles = [] }
        return completedBattles
    }

    /// Ends the battle in progress for its summary, when the app starts fresh without seeing it end.
    public mutating func finishBattle(tracker: OpponentTracker) {
        finishSummary(tracker, result: nil)
    }

    public mutating func process(_ read: ScreenRead, tracker: inout OpponentTracker) {
        logThisRead = []
        throwsThisRead = []
        throwRevisedThisRead = nil
        guard read.time > lastTime else { return }
        if lastTime.isFinite, read.time - lastTime > 1, !stopped, !isBattleOver, tracker.active != nil {
            tracker.markEnergyUncertain("Screen reads delayed; timing uncertain")
        }
        previousReadTime = lastTime
        lastTime = read.time
        let t = read.time
        if read.hpTraceVerified == true {
            recentVerifiedHP += (read.hpTrace ?? []).filter { $0.count == 3 && $0[0] <= t && $0[2] > 0 }
            recentVerifiedHP.removeAll { $0[0] < t - 15 }
        }
        if !stopped, !awaitingGo, read.hpTraceVerified == true {
            for sample in read.hpTrace ?? [] where sample.count == 3 && sample[0] <= t && sample[2] > 0 {
                if let rhythm = cadence.observe(time: sample[0], pixels: sample[1] * sample[2]),
                   let move = tracker.inferFastMoveFromCadence(rhythm) {
                    note("HP damage rhythm suggests \(name(tracker.active?.speciesId)) uses \(move.name); recounted its assumed moveset")
                }
            }
        }
        // Every frame the phone attached: older builds attached frames from while this read's
        // text was being recognized too, which it had seen by the time it processed the read.
        fillSamples += (read.fillTrace ?? []).filter { $0.count == 3 }
        if let first = fillSamples.first, t - first[0] > 20 { fillSamples.removeAll { t - $0[0] > 20 } }
        if !stopped { checkRestartAgainstYourFastMoves(before: max(t, fillSamples.last?[0] ?? t), tracker: &tracker) }
        if useHitCount { countLeadHits(read, tracker: tracker) }
        if useFirstHitText, !Rules.off("hitText") { checkLeadStartFromHitText(read, tracker: &tracker) }
        // After your charged move their fast move in progress finishes as play resumes, often
        // before your buttons can be read: a fresh "…EFFECTIVE" over your Pokémon in the stop
        // shows the battle had restarted by this read. Unless it knocked yours out: then play
        // waits for your next one, and its "Go, X!" (or the switch prompt) comes after the hit
        // (221337: Clodsire after Nidoqueen's Poison Jab at 3:07.3, play back at 3:09.4).
        let hitOverYou = read.lines.contains(where: Self.isHitOnYou)
        let goShown = read.lines.contains { $0.text.lowercased().hasPrefix("go,") }
        if stopped, let hit = inProgressLandedBy, hit < t,
           (goShown && !goShownAtHit) || read.lines.contains(where: { NameMatcher.normalize($0.text).contains("switchinanewpokemon") }) {
            inProgressLandedBy = nil
            inProgressRuledOut = true
        }
        if stopped, playerChargedThisStop, !opponentThrewThisStop, !inProgressRuledOut, hitOverYou, !hitOverYouLastRead, inProgressLandedBy == nil {
            inProgressLandedBy = t
            inProgressLandedAfter = previousReadTime
            goShownAtHit = goShown
        }
        hitOverYouLastRead = hitOverYou
        // Your fast move hitting them once their banner has gone means play ran after their
        // charged move (002722: "NOT VERY EFFECTIVE..." over Greninja at 0:41.92, after Hydro Cannon).
        let hitOverThem = read.lines.contains(where: Self.isHitOnThem)
        if stopped, opponentThrewThisStop, hitOverThem, !hitOverThemLastRead,
           !read.lines.contains(where: { $0.text.contains(" used ") }) {
            playSinceTheirChargedMove = true
        }
        hitOverThemLastRead = hitOverThem
        if let n = read.opponentAlive {
            if let before = opponentAlive, n < before { aliveDroppedAt = t }
            opponentAlive = n
            opponentAliveAt = t
            if let f = unconfirmedFaint, !stopped {
                unconfirmedFaint = nil
                if aliveDroppedAt < f.stop - Self.faintBallLead {
                    tracker.markNotFainted(f.speciesId)
                    note("\(name(f.speciesId)) switched out, not fainted: \(n) pokéballs still red")
                    if let i = battleRecord.markers.lastIndex(where: { $0.marker.kind == .fainted && $0.marker.pokemon == name(f.speciesId) }) {
                        battleRecord.markers[i].marker.kind = .switched
                        battleRecord.markers[i].marker.pokemon = name(tracker.active?.speciesId)
                    }
                }
            }
        }
        if awaitingGo, let go = goAt, t >= go {
            // GO itself wasn't read, but the countdown said when it would be.
            awaitingGo = false
            tracker.resume(at: go)
            tracker.setEnergy(0, at: go)
            leadStartedAt = go
        }
        if awaitingGo, goAt == nil, t >= leadNamedAt + Self.goWait {
            // No countdown at all: go by the buttons.
            awaitingGo = false
            tracker.resume(at: resumedBeforeGo ?? t)
        }
        for event in parser.process(read) {
            switch event {
            case .searching:
                newBattle(&tracker)

            case .battleEnded:
                // The results screen keeps showing it, also after the count is cleared.
                guard !isBattleOver, tracker.active != nil else { continue }
                isBattleOver = true
                battleEndedAt = t
                tracker.pause(at: t)
                note("Battle over")
                finishSummary(tracker, result: parser.lastResult)

            case .countdown(let goIn):
                if goAt == nil { goAt = t + goIn + (Rules.off("goDelay") ? 0 : goDelay) }

            case .battleStarted:
                // Turn 0, `goDelay` after GO shows. The lead was probably read during the countdown:
                // its clock restarts then (on the first read after, if that's later than now).
                // A first read of GO usually comes within a read of it appearing; one that caught it
                // growing as it fades came most of its 0.65s on screen later (152828: up from 0:43.9,
                // first read at 0:44.56; 4 Mud Slaps from Marowak by 0:50.7, not 3).
                let late = !Rules.off("fadingGo") && parser.goReadFading ? Self.fadingGoLag : 0
                if late > 0 { note("GO was first read as it faded: the battle started \(String(format: "%.2f", late))s earlier") }
                let start = t + (Rules.off("goDelay") ? 0 : goDelay) - late
                goAt = start
                buttonsResumedAt = start
                if battleRecord.start == nil { battleRecord.start = tracker.battleClock(at: start) }
                if awaitingGo, start <= t {
                    awaitingGo = false
                    tracker.resume(at: t)
                }
                if !awaitingGo, tracker.team.count == 1, tracker.active?.fastMove != nil {
                    tracker.setEnergy(0, at: start)
                    leadStartedAt = start
                }

            case .stopped:
                // Either side's charged move or a faint: no turns pass from here.
                stopped = true
                opponentThrewThisStop = false
                yourFaintThisStop = false
                theirFaintThisStop = false
                replacedSinceYourChargedMove = false
                chargedMoveThisStop = false
                inProgressLandedBy = nil
                inProgressRuledOut = false
                let observation = parser.stopObservation ?? (first: t, previous: previousReadTime)
                checkRestartAgainstYourFastMoves(before: observation.first, tracker: &tracker)
                let stop = max(observation.first - stopLead, observation.previous, resumedAt)
                learnYourFastMove(between: buttonsResumedAt, and: observation.first)
                restartChecked = true
                awaitingYourReplacement = false
                lastStopAt = stop
                tracker.pause(at: stop)
                if goAt != nil { settleLeadFromHits(at: t, tracker: &tracker) }
                // Your fast moves landing this stretch tell their length better than your buttons.
                if parser.yourButtonLabels == summaryButtonLabels, let turns = YourFastMoves.turns(fromGaps: yourGaps),
                   let last = battleRecord.yourMoves.indices.last {
                    battleRecord.yourMoves[last].turns = turns
                }

            case .shielded:
                if let i = battleRecord.charged.lastIndex(where: { $0.stop == battleRecord.stops.count }) {
                    battleRecord.charged[i].move.shielded = true
                }

            case .resumed(let free):
                stopped = false
                playerChangedSinceResume = false
                cadence = FastMoveCadence()
                let lead = chargedMoveThisStop ? resumeLead : faintResumeLead
                let readResume = max(t - lead, lastStopAt)
                var resume = readResume
                fadeInRestart = nil
                // A 0-turn switch as a charged move ends: their name box no longer shows the one
                // that was in by the read before your buttons came back. Its camera holds your
                // buttons back, so the frames they fade in on date the restart, not their read
                // (012748: Stunfisk for Ninetales after its Weather Ball, 5 Thunder Shocks and a
                // sneak by your Blaze Kick; 020105: Cramorant for Diggersby after its Scorching
                // Sands, 2 Pecks and a sneak by your Icy Wind; both by the user's count). Not when
                // theirs stayed in (010901: Ninetales after your charged move). Nor, as yet, for one
                // sent in for theirs that fainted: it changed nothing at a 0.15s lead, and the lead
                // that gave 005818's Altaria its 20 (0.4s) broke 233921 and 005151.
                let zeroTurnSwitch = parser.currentOpponentShownAt.map { $0 < previousReadTime } ?? false
                if !Rules.off("fadeIn"), chargedMoveThisStop, zeroTurnSwitch || Rules.off("fadeInOnlySwitch"), let fade = buttonsFadeIn(at: t) {
                    note("Your buttons began fading in at \(clockString(fade)): the battle resumed \(clockString(fade - fadeInLead))")
                    resume = max(fade - fadeInLead, lastStopAt)
                    fadeInRestart = resume
                }
                restartSeen = false
                switchedInSinceRestart = false
                // Their fast move in progress at your charged move hit you before your buttons
                // came back, so play had restarted by then (155712: Azumarill's Bubble showed over
                // your Altaria at 2:10.64, your buttons at 2:11.44; your 3 Dragon Breaths fit
                // after it, and so did one Bubble and the one it sneaked on your next charged move).
                if !Rules.off("inProgressHit"), !yourFaintThisStop, let hit = inProgressLandedBy, hit < resume, hit > lastStopAt {
                    // One sent in for theirs that fainted in this stop had no fast move in progress:
                    // the hit was its first, a whole fast move after play resumed (155536: Altaria for
                    // the fainted Florges, its Dragon Breath over your Mimikyu by 2:56.60).
                    if replacedSinceYourChargedMove, !Rules.off("replacementHit"), let fast = tracker.active?.fastMove {
                        // It landed between the read before and this one: halfway, like a stop.
                        let landed = inProgressLandedAfter > lastStopAt ? (inProgressLandedAfter + hit) / 2 : hit
                        let first = max(landed - Double(fast.turns) * turnDuration, lastStopAt)
                        note("\(name(tracker.active?.speciesId))'s first fast move hit you at \(clockString(hit)), before your buttons came back: the battle had restarted at \(clockString(first))")
                        resume = first
                    } else {
                        note("Their fast move in progress hit you at \(clockString(hit)), before your buttons came back: the battle had restarted")
                        resume = hit
                    }
                    restartSeen = true
                }
                resumedAt = resume
                // Your buttons only show your fast moves once they're back (they fade in at first).
                buttonsResumedAt = max(t - lead, lastStopAt)
                // When your Pokémon fainted, not until your replacement's buttons show its fast move.
                restartChecked = awaitingGo || yourFaintThisStop
                awaitingYourReplacement = !awaitingGo && yourFaintThisStop
                buttonsBackAt = t
                readBeforeButtonsBack = previousReadTime
                lastResumeAfterYourChargedMove = playerChargedThisStop && !opponentThrewThisStop
                playerChargedThisStop = false
                // Timed from your buttons' read (or a hit), not their fade-in: it was fitted so.
                if free { freeSwitchUntil = (restartSeen ? resume : readResume) + Self.afterStopWindow }
                if !awaitingGo {
                    // Where the stop sits on the clock of play, now it can't move any more.
                    let at = tracker.battleClock(at: resume)
                    if battleRecord.start == nil { battleRecord.start = at } else { battleRecord.stops.append(at) }
                }
                // The buttons show during the countdown: the lead's clock waits for GO.
                if awaitingGo { resumedBeforeGo = resume } else { tracker.resume(at: resume) }

            case .opponentChargedMove(let moveName):
                // Unmatched is usually a half-read banner; the next read has the whole name.
                guard let (speciesId, move) = resolve(chargedMove: moveName, tracker: tracker) else { continue }
                if speciesId != tracker.active?.speciesId {
                    tracker.changeForm(to: speciesId)
                    note("Form: \(data.species[speciesId]?.speciesName ?? speciesId)")
                }
                if !Rules.off("sameTurn") { sameTurnAsYours(&tracker) }
                let short = tracker.snapshot(at: t).energy
                if !Rules.off("restore"), tracker.restoreInProgress(ifShortOf: move.energy, at: t) {
                    note("\(name(tracker.active?.speciesId)) couldn't afford \(move.name) without its fast move in progress: it threw after yours, not on the same turn (\(short) → \(tracker.snapshot(at: t).energy))")
                }
                // A throw the assumed fast move couldn't have afforded, but another fast move it
                // learns could, means it's that one: Flygon threw Twister and Sand Tomb on Mud
                // Shot, not PvPoke's Dragon Tail (155712, 174243).
                if !Rules.off("reconsider"), let change = tracker.reconsiderFastMove(throwing: move.energy, at: lastStopAt) {
                    note("\(name(tracker.active?.speciesId)) uses \(change.to.name), not \(change.from.name): \(move.name) needs \(move.energy) energy")
                }
                alignToOpponentChargedMove(&tracker)
                tracker.restrictForms(learning: move.moveId)
                let raw = tracker.snapshot(at: t).energy
                if tracker.reconcileObservedSpend(move.energy, at: t) > 0 {
                    note("Timing uncertain: \(name(tracker.active?.speciesId)) spent \(move.energy) on \(move.name), but the clock counted \(raw); resynchronized to the observed minimum")
                }
                let before = tracker.snapshot(at: t).energy
                tracker.opponentThrewChargedMove(move.moveId, at: t)
                if let pokemon = tracker.active {
                    let previousEnd = pokemon.chargedMovesThrown.dropLast().last?.afterStretch ?? 0
                    let count = pokemon.fastMove.map { fast in
                        pokemon.history.dropFirst(previousEnd).reduce(0) { total, stretch in
                            total + Int((stretch.length / (Double(fast.turns) * turnDuration) + 1e-9).rounded(.down))
                                + (stretch.interrupted ? 1 : 0)
                        }
                    }
                    let observation = ChargedMoveObservation(
                        time: t, speciesId: pokemon.speciesId, move: move, fastMove: pokemon.fastMove,
                        energyBefore: before, energyAfter: tracker.snapshot(at: t).energy,
                        energyBeforeReconciliation: raw, fastMoveCount: count)
                    throwsThisRead.append(observation)
                    lastTheirThrow = observation
                }
                opponentThrewThisStop = true
                playSinceTheirChargedMove = false
                chargedMoveThisStop = true
                note("\(name(tracker.active?.speciesId)) used \(move.name) (\(before) → \(tracker.snapshot(at: t).energy))")
                if battleRecord.start != nil {
                    battleRecord.charged.append((battleRecord.stops.count, .init(
                        side: .them, time: 0, name: move.name, type: move.type, pokemon: name(tracker.active?.speciesId),
                        shielded: false, energyBefore: before, energyAfter: tracker.snapshot(at: t).energy)))
                }

            case .attackIncoming:
                // Corrects the count as the battle freezes, not only once the banner names the move.
                if !Rules.off("sameTurn") { sameTurnAsYours(&tracker) }
                alignToOpponentChargedMove(&tracker)

            case .yourPokemonFainted:
                yourFaintThisStop = true
                // Yours can't throw once fainted: a charged move after this is your next Pokémon's.
                playSinceTheirChargedMove = true
                if battleRecord.start != nil {
                    battleRecord.markers.append((battleRecord.stops.count, .init(side: .you, time: 0, kind: .fainted)))
                }
                if !Rules.off("yourFaintTurn") { tracker.opponentsNextSwitchCostsATurn() }
                guard !opponentThrewThisStop, !playerChargedThisStop else { continue }
                let before = tracker.snapshot(at: t).energy
                tracker.yourPokemonFainted()
                note("Your Pokémon fainted: \(name(tracker.active?.speciesId)) \(before) → \(tracker.snapshot(at: t).energy) (the fast move that knocked it out landed)")

            case .playerChangedPokemon:
                // A switch/faint transition can interrupt the opponent's rhythm even
                // while OCR still sees the dimmed buttons. It cannot justify adding a
                // fast move by assuming the whole stretch was uninterrupted.
                // Not for a switch that shows as your buttons come back: made during the stop, it
                // doesn't break their rhythm from the restart (221337: your Clodsire after the
                // 6:09 charged move; Mimikyu's 7 Shadow Claws before Shadow Sneak).
                let atRestart = !Rules.off("switchAtRestart") && !stopped && buttonsBackAt.map { t - $0 < 0.6 } == true
                if !atRestart { playerChangedSinceResume = true }
                playSinceTheirChargedMove = true
                cadence = FastMoveCadence()
                yourGaps = []
                // A switch, not the Pokémon you sent in after yours fainted.
                if battleRecord.start != nil, !yourFaintThisStop {
                    battleRecord.markers.append((stopped ? battleRecord.stops.count : nil,
                                                 .init(side: .you, time: tracker.battleClock(at: t), kind: .switched)))
                }
                restartChecked = !awaitingYourReplacement
                awaitingYourReplacement = false

            case .playerChargedMove:
                // Their fast move in progress pays out; they start fresh after your move.
                let before = playerFreezeBeforeCue
                if !Rules.off("runOn"), t - before > lastStopAt, t - lastStopAt < 2.5, tracker.isPaused {
                    // The battle ran on while your fast move finished: move the freeze later.
                    tracker.resume(at: lastStopAt)
                    lastStopAt = t - before
                    tracker.pause(at: lastStopAt)
                }
                // The first charged move after a faint, before ManGo saw play resume: you can only
                // throw once it has, so yours took its first turn and they started a fast move on
                // it, a sneak (010753: Nidoqueen in for the fainted Forretress at 2:27.1, your
                // charged move straight away at 2:29.8; the user saw it sneak a Mud Slap).
                let afterFaint = !Rules.off("sneakAfterFaint") && !chargedMoveThisStop && (theirFaintThisStop || yourFaintThisStop)
                chargedMoveThisStop = true
                playerChargedThisStop = true
                replacedSinceYourChargedMove = false
                let energyBefore = tracker.snapshot(at: t).energy
                // Straight after theirs with no play between (no hit on them, your buttons never
                // back), both of you threw on the same turn and theirs won the tie: they weren't in
                // a fast move, so no sneak (233921: Stunfisk's Discharge, then your Energy Ball at
                // 1:22.2; 5 Thunder Shocks before its Mud Bomb, not 6).
                let tieTheyWon = opponentThrewThisStop && !playSinceTheirChargedMove && !Rules.off("cmpAfterTheirs")
                if tieTheyWon {
                    note("Your charged move came straight after theirs with no play between: a CMP tie \(name(tracker.active?.speciesId)) won, no sneak")
                    // The clock's move in progress at theirs counts when its finished ones couldn't
                    // pay for their charged move: then the clock was behind (233921's Stunfisk,
                    // 232707's Forretress, 211526's Quagsire). Or when it came in by a switch since
                    // play last restarted: a switch is only dated to within a read or so, and its
                    // hits on your bar come before the clock has them (211824: Melmetal's Double
                    // Iron Bash on 5 Thunder Shocks, the 5th 87% done; 221608: Ninetales's Weather
                    // Ball on 5 Embers, the 5th 70% done, by the user's counts). Otherwise nothing
                    // says it was behind, however done it had the next (211824: Hydreigon's Brutal
                    // Swing on 14 Dragon Breaths from GO, the 15th 99% done).
                    let clockShort = Rules.off("tieNeedsUnderpay")
                        || (switchedInSinceRestart && !Rules.off("tieAfterSwitch"))
                        || lastTheirThrow.map { $0.speciesId == tracker.active?.speciesId && $0.energyBeforeReconciliation < $0.move.energy } == true
                    let added = clockShort ? tracker.theyWonSameTurnTie() : 0
                    if added > 0, var revised = lastTheirThrow, revised.speciesId == tracker.active?.speciesId {
                        note("\(name(tracker.active?.speciesId)) threw as a fast move finished: the one the clock had over half done counts (\(revised.energyAfter) → \(tracker.snapshot(at: t).energy))")
                        revised.fastMoveCount = revised.fastMoveCount.map { $0 + 1 }
                        revised.energyBeforeReconciliation += revised.fastMove?.energyGain ?? 0
                        revised.energyBefore = max(revised.energyBefore, min(100, revised.energyBeforeReconciliation))
                        revised.energyAfter = tracker.snapshot(at: t).energy
                        throwRevisedThisRead = revised
                        lastTheirThrow = revised
                        if let k = battleRecord.charged.lastIndex(where: { $0.move.side == .them }) {
                            battleRecord.charged[k].move.energyBefore = revised.energyBefore
                            battleRecord.charged[k].move.energyAfter = revised.energyAfter
                        }
                    }
                }
                tracker.playerThrewChargedMove(at: t, afterTheirChargedMove: (opponentThrewThisStop && !tieTheyWon) || afterFaint)
                if tracker.active != nil {
                    note("You threw a charged move: \(name(tracker.active?.speciesId)) \(energyBefore) → \(tracker.snapshot(at: t).energy) (its fast move in progress counts)")
                }
                if battleRecord.start != nil {
                    battleRecord.charged.append((battleRecord.stops.count, .init(
                        side: .you, time: 0, shielded: false, energyBefore: energyBefore, energyAfter: tracker.snapshot(at: t).energy)))
                }

            case .opponentAppeared(let match, let since):
                appear(match, at: since, now: t, tracker: &tracker)
            }
        }
        checkHitType(read, tracker: &tracker)
        nameYourChargedMove()
        noteYourFastMove(tracker)
    }

    /// Their fast moves' hits on you, read for type: the game says "SUPER EFFECTIVE!" or "NOT
    /// VERY EFFECTIVE..." over your Pokémon as each lands (nothing when it's neutral). Against
    /// your Pokémon's types, that rules out each of their fast moves of the wrong type, and any
    /// form left with none. "SUPER EFFECTIVE!" on your Fearow (Normal/Flying) fits no Ninetales
    /// move but Alolan Ninetales's Powder Snow, not PvPoke's top Ninetales on Ember (011620: 6
    /// Powder Snows before Weather Ball, 48, not 54). Only a text it says counts: a hit it says
    /// nothing over may just not have been read.
    ///
    /// The text must first show after the restart, your switch and theirs. It stays up a while
    /// and hits keep it up: Altaria's Dragon Breath's "NOT VERY EFFECTIVE..." on your Mimikyu was
    /// still showing 2s after Florges came in (155536), and Fairy Wind is neutral on Mimikyu.
    private mutating func checkHitType(_ read: ScreenRead, tracker: inout OpponentTracker) {
        let t = read.time
        if parser.yourButtonLabels != yourLabels { yourLabels = parser.yourButtonLabels; yourLabelsSince = t }
        let said = read.lines.filter(Self.isHitOnYou).map { NameMatcher.normalize($0.text) }
        // A charged move's text starts mid-screen and follows your Pokémon left as the camera
        // comes back (Dunsparce's Rock Slide on your Jumpluff, 124534): it's the same text there.
        // Not one over them (`isHitOnThem`), which your hits keep up.
        let showing = read.lines.contains {
            NameMatcher.normalize($0.text).contains("effective") && !Self.isHitOnThem($0) && (0.12...0.7).contains($0.box.midY)
        }
        hitTextSince = showing ? hitTextSince ?? t : nil
        guard !Rules.off("hitType"), !stopped, !awaitingGo, !isBattleOver, let active = tracker.active,
              let since = hitTextSince, since > max(resumedAt + Self.hitTextAfterRestart, yourLabelsSince, opponentSeenAt) else { return }
        let notVery = said.contains { $0.contains("not") || $0.contains("very") }
        let superEffective = said.contains { $0.contains("uper") }
        guard notVery != superEffective, let you = yourActivePokemon else { return }
        let effect: TypeChart.Effect = superEffective ? .superEffective : .notVeryEffective
        let forms = active.possibleSpeciesIds.contains(active.speciesId) ? active.possibleSpeciesIds : [active.speciesId]
        let wrong = Set(forms.flatMap { data.fastMoves(for: $0) }
            .filter { TypeChart.effect($0.type, against: you.types) != effect }.map(\.moveId))
        guard !wrong.isSubset(of: active.ruledOutFastMoves) else { return }
        let ruledOut = active.ruledOutFastMoves.union(wrong)
        func allowed(_ id: String) -> [Move] { data.fastMoves(for: id).filter { !ruledOut.contains($0.moveId) } }
        let fitting = forms.filter { !allowed($0).isEmpty }
        // Nothing it could be fits: a misread, or a type ManGo has wrong. Leave it.
        guard let first = fitting.first else { return }
        tracker.ruleOutFastMoves(wrong)
        let form = fitting.contains(active.speciesId) ? active.speciesId : first
        let moves = allowed(form)
        let move = data.recommendedMoves(for: form).fast.flatMap { moves.contains($0) ? $0 : nil } ?? moves[0]
        if form == active.speciesId, active.fastMove == move { tracker.setPossibleForms(fitting); return }
        let before = tracker.snapshot(at: t).energy
        if form != active.speciesId { tracker.changeForm(to: form) }
        tracker.setPossibleForms(fitting)
        tracker.switchFastMove(to: move)
        let kind = effect == .superEffective ? "super effective" : "not very effective"
        note("Their hit on your \(you.name) was \(kind): \(name(active.speciesId)) on \(active.fastMove?.name ?? "?") wouldn't be; it's \(name(form)) on \(move.name) (\(before) → \(tracker.snapshot(at: t).energy))")
    }

    /// Your Pokémon now, from its two charged move buttons: the one you've been seen with (by
    /// name) that has both, or else the ranked ones that do, if they share their types.
    private var yourActivePokemon: (name: String, types: [String])? {
        let labels = parser.yourButtonLabels
        guard labels.count == 2 else { return nil }
        // Each label is any charged move by that name (PvPoke has a DRILL_PECK_PLUS too).
        let named = Dictionary(grouping: data.moves.values.filter { !$0.isFast && $0.energy > 0 }) { NameMatcher.normalize($0.name) }
        let options = labels.map { Set(named[$0]?.map(\.moveId) ?? []) }
        guard options.allSatisfy({ !$0.isEmpty }) else { return nil }
        let all = data.species.values.filter { s in !s.types.isEmpty && options.allSatisfy { !$0.isDisjoint(with: s.chargedMoves) } }
        let seen = all.filter { parser.myTeam.contains(NameMatcher.baseKey($0.speciesName)) }
        let candidates = seen.isEmpty ? all.filter { $0.rank != nil } : seen
        guard let best = candidates.min(by: { ($0.rank ?? .max) < ($1.rank ?? .max) }),
              candidates.allSatisfy({ Set($0.types) == Set(best.types) }) else { return nil }
        // The base name: "Blaziken" for Shadow Blaziken too, which the buttons can't tell apart.
        let base = best.speciesName.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? best.speciesName
        return (base, best.types)
    }

    // MARK: Helpers

    /// Your fast move's length: from the gaps between your fast moves landing so far, or else
    /// PvPoke's fast move for your Pokémon, known from its two charged move buttons (Poison Fang
    /// and Earth Power: Nidoqueen, Mud Slap), if every ranked Pokémon with both agrees. A single
    /// gap counts when it fits that.
    private var yourFastMove: TimeInterval? {
        let prior = yourFastMoveFromButtons
        if let turns = YourFastMoves.turns(fromGaps: yourGaps) { return Double(turns) * turnDuration }
        if let gap = yourGaps.last, let prior, abs(gap - prior) <= 0.15 { return prior }
        return prior
    }

    private var yourFastMoveFromButtons: TimeInterval? {
        let labels = parser.yourButtonLabels
        guard labels.count == 2 else { return nil }
        let moveIds = data.moves.values.filter { !$0.isFast && labels.contains(NameMatcher.normalize($0.name)) }.map(\.moveId)
        guard Set(moveIds.map { NameMatcher.normalize(data.moves[$0]!.name) }) == labels else { return nil }
        let turns = Set(data.species.values.filter { $0.rank != nil && moveIds.allSatisfy($0.chargedMoves.contains) }
            .compactMap { data.recommendedMoves(for: $0.speciesId).fast?.turns })
        guard turns.count == 1, let t = turns.first else { return nil }
        return Double(t) * turnDuration
    }

    // MARK: Battle summary

    /// PvPoke's fast move for your Pokémon, from its two charged move buttons: the best-ranked
    /// Pokémon with both (Aura Sphere and Blaze Kick: Shadow Blaziken's Ember, not Lucario's
    /// Force Palm). A guess for drawing your side; your fast moves landing correct its length.
    private func fastMove(forButtons labels: Set<String>) -> (turns: Int, type: String?)? {
        guard labels.count == 2 else { return nil }
        let moveIds = data.moves.values.filter { !$0.isFast && $0.energy > 0 && labels.contains(NameMatcher.normalize($0.name)) }.map(\.moveId)
        guard Set(moveIds.compactMap { data.moves[$0].map { NameMatcher.normalize($0.name) } }) == labels else { return nil }
        let top = data.species.values
            .filter { $0.rank != nil && moveIds.allSatisfy($0.chargedMoves.contains) }
            .sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
            .lazy.compactMap { self.data.recommendedMoves(for: $0.speciesId).fast }.first
        return top.map { ($0.turns, $0.type) }
    }

    /// The charged moves on your buttons, as the summary last read them.
    private var yourButtonMoves: [String] {
        let labels = summaryButtonLabels.isEmpty ? parser.yourButtonLabels : summaryButtonLabels
        return data.moves.values.filter { !$0.isFast && $0.energy > 0 && labels.contains(NameMatcher.normalize($0.name)) }.map(\.moveId)
    }

    /// Your banner ("Blaziken used Blaze Kick!") names your charged move: the one on your buttons
    /// nearest what was read.
    private mutating func nameYourChargedMove() {
        guard parser.yourBannerCount > yourBannersNamed, let banner = parser.yourLastBanner else { return }
        yourBannersNamed = parser.yourBannerCount
        guard battleRecord.start != nil else { return }
        if let user = banner.user?.trimmingCharacters(in: .whitespaces), !user.isEmpty, !battleRecord.yourTeam.contains(user) {
            battleRecord.yourTeam.append(user)
        }
        guard let i = battleRecord.charged.lastIndex(where: { $0.move.side == .you }), battleRecord.charged[i].move.name == nil else { return }
        let read = NameMatcher.normalize(banner.move)
        let move = yourButtonMoves.compactMap { data.moves[$0] }
            .min { NameMatcher.editDistance(NameMatcher.normalize($0.name), read, limit: 6) < NameMatcher.editDistance(NameMatcher.normalize($1.name), read, limit: 6) }
        battleRecord.charged[i].move.name = move?.name ?? banner.move
        battleRecord.charged[i].move.type = move?.type
        battleRecord.charged[i].move.pokemon = banner.user
    }

    /// Your buttons changed (your lead's, then each switch), read the same on two reads in a row:
    /// your fast move from the first of them. A switch made in play takes a turn; one made in a
    /// stop shows as the buttons come back, and a Pokémon sent in after yours fainted takes none.
    private mutating func noteYourFastMove(_ tracker: OpponentTracker) {
        guard let start = battleRecord.start else { return }
        let labels = parser.buttonLabelsThisRead
        guard labels.count == 2 else { return }  // a label missed on this read
        guard labels != summaryButtonLabels else { summaryPendingLabels = nil; return }
        if summaryPendingLabels?.labels != labels {
            let atRestart = buttonsBackAt.map { lastTime - $0 < 0.6 } ?? true
            summaryPendingLabels = (labels, 0, tracker.battleClock(at: lastTime), !atRestart && !stopped && !yourFaintThisStop)
        }
        summaryPendingLabels!.count += 1
        guard let pending = summaryPendingLabels, pending.count >= 2, let move = fastMove(forButtons: labels) else { return }
        let first = battleRecord.yourMoves.isEmpty
        summaryButtonLabels = labels
        summaryPendingLabels = nil
        battleRecord.yourMoves.append((from: first ? start : pending.at, turns: move.turns, type: move.type, switchTurn: !first && pending.inPlay))
        note("Your buttons: \(labels.sorted().joined(separator: ", ")); your fast move takes \(move.turns) turn\(move.turns == 1 ? "" : "s")")
    }

    private mutating func finishSummary(_ tracker: OpponentTracker, result: String?) {
        if let summary = battleRecord.summary(tracker: tracker, endedAt: tracker.battleClock(at: lastTime), result: result) {
            completedBattles.append(summary)
        }
        battleRecord = BattleSummaryRecord()
        summaryButtonLabels = []
        summaryPendingLabels = nil
    }

    /// Where your buttons began fading back in: walking back from the read that names them, the
    /// first of the frames showing any fill. Only between the last read and this one, from an
    /// empty frame (fill flickers while they're hidden), and not for nearly empty buttons.
    private func buttonsFadeIn(at t: TimeInterval) -> TimeInterval? {
        let frames = fillSamples.filter { $0[0] <= t && $0[0] >= max(lastStopAt, previousReadTime) }
        func filled(_ f: [Double]) -> Bool { max(f[1], f[2]) > 0.02 }
        guard let last = frames.last, max(last[1], last[2]) > Self.fadeInMinimumFill else { return nil }
        var i = frames.count - 1
        while i > 0, filled(frames[i - 1]) { i -= 1 }
        return i > 0 ? frames[i][0] : nil
    }

    private func yourLandings(from start: TimeInterval, to end: TimeInterval) -> [TimeInterval] {
        YourFastMoves.landings(in: fillSamples.filter { $0[0] >= start && $0[0] <= end })
    }

    /// The gaps between your fast moves landing in a stretch of play tell your fast move's length.
    private mutating func learnYourFastMove(between start: TimeInterval, and end: TimeInterval) {
        guard !Rules.off("yourClock"), end > start else { return }
        let landings = yourLandings(from: start, to: end)
        yourGaps += zip(landings.dropFirst(), landings).map { $0 - $1 }
        if yourGaps.count > 12 { yourGaps.removeFirst(yourGaps.count - 12) }
    }

    /// After a restart both sides can start a fast move on the same turn, so your first one lands
    /// exactly one of your fast moves after it. Landing sooner than ManGo's restart allows means
    /// the battle restarted earlier than the buttons showed (they fade in), and so did their fast
    /// moves, less `opponentReaction`. Only ever earlier: a later first landing may be a second one,
    /// the first hidden while the buttons faded in.
    private mutating func checkRestartAgainstYourFastMoves(before end: TimeInterval, tracker: inout OpponentTracker) {
        guard !restartChecked, !stopped, !Rules.off("yourClock") else { return }
        guard let move = yourFastMove else { restartChecked = true; return }
        guard let first = yourLandings(from: buttonsResumedAt, to: end).first else {
            if end > buttonsResumedAt + 2 * move + 0.5 { restartChecked = true }  // full buttons don't fill
            return
        }
        restartChecked = true
        let restart = max(first - move + Self.opponentReaction, lastStopAt)
        let earlier = resumedAt - restart
        guard earlier > 0.05, tracker.restartedEarlier(by: earlier, resumedAt: resumedAt) else { return }
        note(String(format: "Your fast move landed %.2fs after ManGo's restart: their fast moves restarted %.2fs earlier", first - resumedAt, earlier))
        resumedAt = restart
    }

    /// "NOT VERY EFFECTIVE..." or "SUPER EFFECTIVE!" over your Pokémon shows their fast move
    /// landing (not a neutral one): the first after GO came between the last read and this
    /// one, so their lead began one fast move before. Opponents start at different times:
    /// Galarian Stunfisk began about 1s after GO (its first Mud Shot on your Altaria between
    /// 25.96s and 26.24s), so 5 Mud Shots by its Rock Slide, not 6. Only ever starts the lead
    /// later, and only if the text comes within two of its fast moves of GO.
    private mutating func checkLeadStartFromHitText(_ read: ScreenRead, tracker: inout OpponentTracker) {
        guard !leadStartChecked, let go = goAt, !awaitingGo else { return }
        guard tracker.team.count == 1, lastStopAt < go, !stopped, let fast = tracker.active?.fastMove else {
            if stopped || tracker.team.count > 1 { leadStartChecked = true }
            return
        }
        let move = Double(fast.turns) * turnDuration
        guard read.time < go + 2 * move else { leadStartChecked = true; return }
        guard read.lines.contains(where: Self.isHitOnYou) else { return }
        leadStartChecked = true
        let start = previousReadTime - move
        guard start > go else { return }
        tracker.setEnergy(0, at: start)
        leadStartedAt = start
        let shown = go - goDelay  // when GO appeared
        note(String(format: "First hit on you %.2f-%.2fs after GO: \(name(tracker.active?.speciesId)) started %.2fs after GO, not %.2fs", previousReadTime - shown, read.time - shown, start - shown, goDelay))
    }

    /// "NOT VERY EFFECTIVE..." or "SUPER EFFECTIVE!" over your Pokémon: their move hit you.
    private static func isHitOnYou(_ line: RecognizedText) -> Bool {
        NameMatcher.normalize(line.text).contains("effective") && line.box.midX < 0.45 && (0.12...0.7).contains(line.box.midY)
    }

    /// "NOT VERY EFFECTIVE..." or "SUPER EFFECTIVE!" over their Pokémon: your move hit them. A
    /// charged move's shows about mid-screen (0.50-0.54 across), so only well to the right.
    private static func isHitOnThem(_ line: RecognizedText) -> Bool {
        NameMatcher.normalize(line.text).contains("effective") && line.box.midX > 0.6 && (0.12...0.7).contains(line.box.midY)
    }

    /// The opponent's fast moves landing on your HP bar in the opening stretch, GO to the
    /// first stop: each drop (held for two frames) is one. Their energy at the stop is then
    /// counted, not timed: the lead's start and the stop are each only seen to within a
    /// fraction of a second (testV2's Melmetal started right at GO and its Double Iron Bash
    /// showed 0.8s late; the drops are exactly its 6 Thunder Shocks).
    private mutating func countLeadHits(_ read: ScreenRead, tracker: OpponentTracker) {
        guard let go = goAt, !openingDone, !awaitingGo else { return }
        for sample in read.hpTrace ?? [] where sample.count == 3 {
            let (t, fill, width) = (sample[0], sample[1], sample[2] > 0 ? sample[2] : 1)
            guard t > go - 0.3 else { continue }
            hpRecent.append(fill * width)
            if hpRecent.count > 3 { hpRecent.removeFirst() }
            let level = hpRecent.sorted()[hpRecent.count / 2]  // median of 3: no one-frame flicker
            guard let lowest = hpLowest else { hpLowest = level; continue }
            if lowest - level >= Self.hitPixels {
                guard let since = hpDropSince else { hpDropSince = t; continue }
                leadHits.append((since, lowest - level))
                hpLowest = level
                hpDropSince = nil
            } else {
                hpDropSince = nil
                // The bar settling back up after a glint isn't a heal; a higher level only
                // counts before the first hit (while the bar is still appearing).
                if leadHits.isEmpty { hpLowest = max(lowest, level) }
            }
        }
    }

    /// At the first stop: the lead's energy from its hits, if they were clear. Their
    /// rhythm runs from the last hit, so a fast move in progress still counts if you throw.
    private mutating func settleLeadFromHits(at stop: TimeInterval, tracker: inout OpponentTracker) {
        guard useHitCount, !openingDone else { return }
        openingDone = true
        let hits = leadHits.filter { $0.t <= stop + 0.1 }
        guard let last = hits.last, tracker.team.count == 1, let fast = tracker.active?.fastMove,
              let go = goAt, hits.first!.t > go else { return }
        let before = tracker.snapshot(at: stop).energy
        // No move finished after the last hit, however late the stop was seen: the clock
        // restarts within one move of the stop, so one in progress still counts if you threw.
        let move = Double(fast.turns) * turnDuration
        tracker.setEnergy(hits.count * fast.energyGain, at: max(last.t, lastStopAt - 0.9 * move))
        note("\(hits.count) hits on your HP bar: \(name(tracker.active?.speciesId)) had \(before) by the clock, \(tracker.snapshot(at: stop).energy) by its hits")
    }

    /// Their charged move started as a fast move finished: the stretch since the battle
    /// restarted holds a whole number of fast moves.
    private mutating func alignToOpponentChargedMove(_ tracker: inout OpponentTracker) {
        guard !Rules.off("align"), !playerChangedSinceResume else { return }
        // It corrects a restart time guessed from your buttons. One seen directly (their move in
        // progress hitting you as play resumed) needs no correcting (212316: Quagsire's at 1:17.02;
        // 4 Mud Shots and a sneak at your 1:08 charged move, then 1, then Aqua Tail: 6, not 7).
        if restartSeen, !Rules.off("alignTrustsHit") {
            note("\(name(tracker.active?.speciesId))'s restart was seen, when its fast move in progress hit you: no fast move added")
            return
        }
        let window = restartWindow
        // The fast move it would add must have hit you: their first would have landed one stretch
        // of finished fast moves before the stop. Your HP bar steady then means it didn't. After
        // your charged move their move in progress lands as play resumes, so a hit then proves
        // nothing; but that earlier restart would have put it a fast move before, and your bar
        // steady there means play hadn't resumed (142007: Mimikyu's Shadow Claw in progress at
        // your Energy Ball hit at 1:41.35, your bar held from 1:40.4: 3 more and Shadow Sneak).
        if !Rules.off("hpVetoAlign"), let fast = tracker.active?.fastMove, lastStopAt > resumedAt {
            let move = Double(fast.turns) * turnDuration
            let finished = ((lastStopAt - resumedAt) / move + 1e-9).rounded(.down)
            let wouldHaveLanded = lastStopAt - finished * move
            let inProgressAt = wouldHaveLanded - move
            if yourHPShowsHits(between: resumedAt, and: lastStopAt) {
                if yourHPShowsNoHit(around: wouldHaveLanded) {
                    note("Your HP bar shows no hit at \(clockString(wouldHaveLanded)): \(name(tracker.active?.speciesId)) didn't finish one more fast move")
                    return
                }
                if !Rules.off("hpVetoInProgress"), lastResumeAfterYourChargedMove, yourHPShowsNoHit(around: inProgressAt) {
                    note("Your HP bar shows no hit at \(clockString(inProgressAt)), where its fast move in progress at your charged move would have landed: \(name(tracker.active?.speciesId)) didn't finish one more fast move")
                    return
                }
            }
        }
        if let back = buttonsBackAt, lastStopAt > resumedAt,
           tracker.alignToChargedMove(stretchStart: resumedAt, stop: lastStopAt,
                                      restartWindow: (back + window.lowerBound)...(back + window.upperBound)) {
            note("\(name(tracker.active?.speciesId)) had finished one more fast move: the battle restarted before your buttons came back")
        }
    }

    private func clockString(_ t: TimeInterval) -> String { String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }

    /// Your HP bar shown steady (and not hidden) from just before `t` to half a second after: no
    /// fast move of theirs landed then. (233009: Morpeko's would-be Thunder Shock at 1:03.3 left
    /// your bar at 60; its hits came at 1:04.1 and 1:05.0, so 5 before Psychic Fangs, not 6.)
    private func yourHPShowsNoHit(around t: TimeInterval) -> Bool {
        let seen = recentVerifiedHP.filter { $0[0] >= t - 0.15 && $0[0] <= t + 0.5 && $0[1] * $0[2] > 0.5 }
        guard seen.count >= 3, let width = seen.first?[2] else { return false }
        let pixels = seen.map { $0[1] * $0[2] }
        return pixels.max()! - pixels.min()! < max(1.5, 0.0035 * width)
    }

    /// Their fast moves visibly hit you in this stretch (your bar fell), so a hit would have shown:
    /// a light one, like Dragon Breath, may not move the bar at all.
    private func yourHPShowsHits(between start: TimeInterval, and end: TimeInterval) -> Bool {
        let seen = recentVerifiedHP.filter { $0[0] >= start && $0[0] <= end && $0[1] * $0[2] > 0.5 }
        guard seen.count >= 6, let width = seen.first?[2] else { return false }
        let pixels = seen.map { $0[1] * $0[2] }
        let held = (2..<pixels.count).map { [pixels[$0 - 2], pixels[$0 - 1], pixels[$0]].sorted()[1] }
        return held.first! - held.min()! >= max(1.5, 0.0035 * width)
    }

    /// Their charged move came in the same stop as yours, with no restart between: you
    /// both threw on the same turn, so they had no fast move in progress to count.
    private mutating func sameTurnAsYours(_ tracker: inout OpponentTracker) {
        guard playerChargedThisStop, !opponentThrewThisStop else { return }
        let before = tracker.snapshot(at: lastTime).energy
        let kept = tracker.opponentThrewOnSameTurn()
        let after = tracker.snapshot(at: lastTime).energy
        if kept {
            note("\(name(tracker.active?.speciesId)) threw on the same turn as you, as its fast move finished: it keeps that one (\(after))")
        } else if after != before {
            note("\(name(tracker.active?.speciesId)) threw on the same turn as you: no fast move in progress (\(before) → \(after))")
            // The card showed the sneak since your charged move; say why it's gone.
            cardNote = ("−\(before - after) taken back: you won CMP", lastTime)
        }
    }

    private mutating func newBattle(_ tracker: inout OpponentTracker) {
        finishSummary(tracker, result: nil)  // one whose results screen wasn't seen
        isBattleOver = false
        battleEndedAt = nil
        goAt = nil
        awaitingGo = false
        stopped = false
        playerChargedThisStop = false
        lastResumeAfterYourChargedMove = false
        playerChangedSinceResume = false
        cadence = FastMoveCadence()
        recentVerifiedHP = []
        fillSamples = []
        yourGaps = []
        buttonsResumedAt = -.infinity
        restartChecked = true
        awaitingYourReplacement = false
        chargedMoveThisStop = false
        opponentThrewThisStop = false
        yourFaintThisStop = false
        leadNamedAt = 0
        resumedBeforeGo = nil
        lastStopAt = -.infinity
        buttonsBackAt = nil
        readBeforeButtonsBack = nil
        hitOverYouLastRead = false
        yourLabels = []
        yourLabelsSince = -.infinity
        opponentSeenAt = -.infinity
        hitTextSince = nil
        cardNote = nil
        inProgressLandedBy = nil
        goShownAtHit = false
        inProgressRuledOut = false
        resumedAt = -.infinity
        fadeInRestart = nil
        freeSwitchUntil = -.infinity
        switchedInSinceRestart = false
        leadStartChecked = false
        leadStartedAt = nil
        restartSeen = false
        opponentAlive = nil
        opponentAliveAt = -.infinity
        hpRecent = []
        hpLowest = nil
        hpDropSince = nil
        leadHits = []
        openingDone = false
        aliveDroppedAt = -.infinity
        unconfirmedFaint = nil
        guard !tracker.team.isEmpty else { return }
        tracker = OpponentTracker(data: data)
        log = []
        note("New battle")
    }

    private mutating func appear(_ match: NameMatcher.Match, at since: TimeInterval, now t: TimeInterval, tracker: inout OpponentTracker) {
        guard let best = match.candidates.first else { return }
        if isBattleOver { newBattle(&tracker) }
        var seen = tracker.team.first { p in match.candidates.contains { $0.speciesId == p.speciesId } }
        if let seen, seen.speciesId == tracker.active?.speciesId { return }
        if seen == nil, tracker.team.count >= 3 {
            newBattle(&tracker)  // a 4th Pokémon: a new battle we missed the start of
            seen = nil
        }
        var time = max(since, resumedAt)  // never before the latest resume
        // A switch made during a stop starts as the Pokémon it replaced leaves. Gone from their
        // name box before the last read before your buttons came back, it left during the stop,
        // a 0-turn switch: the new one starts at the restart, as the old one would have. After
        // your charged move that's before your buttons (Mightyena for Charjabug as your Blaze Kick
        // ended, 125109: Charjabug gone from 1:32.7, buttons back at 1:33.6, so 3 Sucker Punches
        // and one sneaked on your next one, not 2; Nidoqueen for Guzzlord after it blocked your
        // Stone Edge, 221337: 6 Mud Slaps and a sneak). After theirs, even one you shielded, play
        // restarts around your buttons, so it starts with them, below (Charjabug for Florges
        // after its Chilling Water, 002722; Togetic for Melmetal after its Double Iron Bash,
        // 171905). Still there on that read (Turtonator, then Mimikyu with your buttons) or never
        // read, it was leaving as play resumed: the new one starts with your buttons.
        let leftDuringStop = !Rules.off("leftDuringStop") && !opponentThrewThisStop
            && parser.replacedLastShownAt.map { last in readBeforeButtonsBack.map { last < $0 } ?? false } == true
        // Switched in during the stop straight after their charged move (a free switch):
        // it starts as the battle restarts, when your buttons come back (Granbull after
        // Turtonator's Dragon Claws: 7 Charms before Crunch; Cramorant after Stunfisk's
        // Discharge: 5 Pecks before Dive), not when its "Go" or name shows. If your charged
        // move came after theirs, the switch is still timed from the restart but costs a
        // turn (the parser's `freeSwitch`): Turtonator after Mimikyu blocked yours had 3
        // Incinerates plus the one in progress, and Mimikyu left with no extra Shadow Claw.
        // The frames' restart, when they dated it (012748: Stunfisk for Ninetales after Weather Ball).
        if !Rules.off("freeSwitchBackdate"), opponentThrewThisStop, let back = buttonsBackAt, back >= resumedAt, t - back < Self.afterStopWindow {
            time = max(resumedAt, min(time, fadeInRestart ?? back))
        }
        if tracker.active == nil {
            // The lead: counting starts at "GO" (or when the countdown says it will be).
            // Its name can appear before or after GO, so without either, use the name.
            time = goAt ?? since
        }

        let speciesId = seen?.speciesId ?? best.speciesId
        // PvPoke's recommended fast move, or for a Pokémon it doesn't rank, its first one.
        let assumed = assumedFastMoves[speciesId]
            ?? data.species[speciesId]?.recommendedMoveset.first ?? data.species[speciesId]?.fastMoves.first
        let duringStop = stopped || t - resumedAt < Self.afterStopWindow
        var theirsFainted = tracker.active != nil && duringStop && !opponentThrewThisStop
        // Their pokéballs settle it when they're readable: a ball gone dark around the stop is
        // a faint; none, with the balls read since, a switch (Corviknight for Turtonator 0.26s
        // after your charged move: still 3 red, so it stays on the bench with its energy).
        let ballFaint = aliveDroppedAt > lastStopAt - Self.faintBallLead
        if !Rules.off("balls"), tracker.active != nil, duringStop, ballFaint || opponentAliveAt > lastStopAt {
            theirsFainted = ballFaint
        }
        // A switch that shows as the battle restarts after a charged move (anyone's, tie or
        // not) was chosen as it ended: it's free and starts at the restart (Sableye after
        // Marowak's Rock Slide and yours, 0.25s after the buttons). One that shows later was
        // made in play and costs a turn (Turtonator, 1.1s after: 3 Incinerates plus the one
        // in progress, not 4 plus one).
        let quick = !Rules.off("quickSwitch") && chargedMoveThisStop && buttonsBackAt.map { since - $0 < Self.quickSwitchWindow } == true
        if quick, let back = buttonsBackAt { time = leftDuringStop ? resumedAt : max(resumedAt, min(time, back)) }
        if theirsFainted {
            // A new Pokémon right after a stop with no charged move from them: theirs fainted.
            // The clock stays as the screen says: if the battle is still stopped, the new
            // Pokémon's first fast move starts when it resumes, so it comes in at 0.
            note("\(name(tracker.active?.speciesId)) fainted or switched out")
            if let id = tracker.active?.speciesId, !ballFaint, opponentAlive != nil {
                unconfirmedFaint = (id, lastStopAt)
            }
            tracker.markActiveFainted(at: time)
            if stopped { theirFaintThisStop = true; replacedSinceYourChargedMove = true }
        }
        // A name change during a stop is a faint replacement or a switch right after their
        // charged move: both take 0 turns, as does a quick switch (above).
        // Switching out right after the stop: they chose the switch, not a fast move, on the
        // turn your charged move took, so a sneak counted then didn't happen.
        if duringStop, !theirsFainted { tracker.switchingOutAfterStop() }
        // Named only once stopped, but switched before the stop began: made in play, so it costs
        // a turn (221337: Mimikyu for Greninja after 6:08.05, your charged move frozen at 6:08.37;
        // still on its switch turn, so no Shadow Claw in progress, as the user counted).
        let madeInPlay = !Rules.off("switchBeforeStop") && stopped && !theirsFainted && !opponentThrewThisStop && since < lastStopAt
        var free = (stopped && !madeInPlay) || time < freeSwitchUntil || quick
        // After your Pokémon fainted, their switch (theirs still in) is a choice and costs a
        // turn, even straight after their charged move: Mimikyu for Turtonator after its
        // Dragon Claw knocked yours out, 2 Shadow Claws by your next throw, not 3.
        if !Rules.off("yourFaintTurn"), yourFaintThisStop, !theirsFainted { free = false }
        let isLead = tracker.active == nil
        if battleRecord.start != nil, let old = tracker.active {
            // A faint goes on the stop it happened in (still stopped, or the one just ended).
            let stop = stopped ? battleRecord.stops.count : duringStop ? battleRecord.stops.count - 1 : nil
            battleRecord.markers.append(theirsFainted
                ? (stop, .init(side: .them, time: tracker.battleClock(at: time), kind: .fainted, pokemon: name(old.speciesId)))
                : (stopped ? battleRecord.stops.count : nil, .init(side: .them, time: tracker.battleClock(at: time), kind: .switched, pokemon: name(speciesId))))
        }
        cadence = FastMoveCadence()
        // A lead leaving before the first stop: its clock only has GO to go on.
        let leadInOpening = tracker.team.count == 1 && goAt.map { lastStopAt < $0 } == true
        tracker.setActive(speciesId: speciesId, at: time, assumeFastMove: assumed, freeSwitch: free,
                          seenAt: isLead ? nil : leftDuringStop ? time : since, outgoingWaitsForFastMove: !leadInOpening)
        opponentSeenAt = t
        cardNote = nil
        if seen == nil { tracker.setPossibleForms(match.candidates.map(\.speciesId)) }
        switchedInSinceRestart = !isLead && !theirsFainted && !stopped
        // Name confirmation arrives after the switch. Replay the verified samples
        // belonging to the incoming Pokémon instead of discarding its first hit.
        if !stopped {
            for sample in recentVerifiedHP where sample[0] >= time {
                if let rhythm = cadence.observe(time: sample[0], pixels: sample[1] * sample[2]),
                   let move = tracker.inferFastMoveFromCadence(rhythm) {
                    note("HP damage rhythm suggests \(name(speciesId)) uses \(move.name); recounted its assumed moveset")
                }
            }
        }
        if isLead, goAt == nil {
            // Named before the countdown's GO (from "Go, X!"): nothing happens until then.
            tracker.pause(at: time)
            awaitingGo = true
            leadNamedAt = time
            resumedBeforeGo = nil
        }
        note("Opponent: \(name(speciesId))")
    }

    /// Finds the charged move by name for the active Pokémon, or for another form with the
    /// same on-screen name (e.g. Discharge means Stunfisk, not Galarian Stunfisk).
    private func resolve(chargedMove name: String, tracker: OpponentTracker) -> (String, Move)? {
        guard let active = tracker.active?.speciesId, let s = data.species[active] else { return nil }
        // The banner says "Weather Ball"; PvPoke calls it "Weather Ball (Fire)".
        let key = NameMatcher.normalize(name)
        func moveKey(_ m: Move) -> String {
            NameMatcher.normalize(m.name.split(separator: "(").first.map(String.init) ?? m.name)
        }
        let base = s.speciesName.split(separator: "(").first.map(String.init) ?? s.speciesName
        let forms = [active] + (parser.matcher.match(base)?.candidates.map(\.speciesId).filter { $0 != active } ?? [])
        for id in forms {
            let moves = data.chargedMoves(for: id)
            if let move = moves.first(where: { moveKey($0) == key })
                ?? moves.first(where: { NameMatcher.editDistance(moveKey($0), key, limit: 2) <= 2 }) {
                return (id, move)
            }
        }
        return nil
    }

    private func name(_ speciesId: String?) -> String {
        speciesId.flatMap { data.species[$0]?.speciesName } ?? "?"
    }

    private mutating func note(_ s: String) {
        logThisRead.append(s)
        log.append(s)
        if log.count > 50 { log.removeFirst() }
    }
}
