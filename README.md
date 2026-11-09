# ManGo

An iOS tracker for the opponent's energy in Pokémon GO Great League, using PvPoke's game data
and Great League rankings.

## How it tracks energy

PvP runs in 0.5s turns. ManGo assumes the opponent throws PvPoke's recommended fast move
back-to-back, so their energy comes from the clock:

    energy = min(100, banked + floor(battle time since first seen / move length) × energy gain)

- **Charged move thrown:** subtract its cost and restart the fast move chain. The battle clock
  pauses during the cinematic.
- **Your charged move:** pause the clock. Their fast move freezes mid-animation and continues
  when the battle resumes.
- **Switch:** the outgoing Pokémon keeps its energy. The incoming Pokémon's fast moves start
  1 turn later, or 0 turns if they switch as a charged move ends (either side's). One that
  replaced a Pokémon already gone before your buttons came back starts at the restart: after
  your charged move a moment before your buttons, after theirs with them.
  A Pokémon whose fast move is already known (seen before, or it has only one) starts
  counting on its own.
- **Faint:** both sides stop attacking until the next Pokémon comes out. If theirs fainted,
  their replacement starts with no switch turn.
- **Pokémon list:** only PvPoke's top 500 in Great League, sorted by rank.

Your own fast moves are the battle's clock. Each one fills your charged move buttons a step,
which the broadcast extension measures on every frame (`fillTrace`, see `YourFastMoves`). After a
restart both sides start fast moves on the same turn, so your first one lands exactly one of your
fast moves after it: usually about 0.7s before your buttons are readable (they fade in). Their fast
moves are then counted from that restart, less 0.35s for them to react (0.3-0.45s all fit every hand
count). Your fast move's length comes from the gaps between your steps, or PvPoke's fast move for
the Pokémon your two charged move buttons identify. It can't see the restart when your buttons are
full or your fast move takes 1 turn. The 13 older recordings' fill traces were measured from their
videos (`screen-log <video> --fill <fixture>`), which is noisier than the phone's own.

A clear repeated rhythm of damage on a verified player HP bar can change the fast-move
hypothesis. So can a charged move the assumed fast move couldn't have afforded: ManGo switches
to another fast move the Pokémon learns that could have (Flygon threw on Mud Shot, not PvPoke's
Dragon Tail). A base name retains its possible forms until a distinguishing charged move reveals
the form.

A charged move that costs more than the estimate proves synchronization was lost. The engine
records an explicit minimum-energy constraint, subtracts the full cost, and counts on from there.
It does not invent an exact number of missed fast moves. Reports retain the raw estimate so this
reconciliation cannot hide prediction failures. If reads stop arriving, the energy stops counting up.
The card shows one number with no uncertainty marks, as you asked.

The engine is in `PvPCore/` (a Swift package with no UI). `OpponentTracker` takes
timestamped events, so it doesn't care whether they come from taps or from computer vision.

## Layout

    ManGo.xcodeproj       the iOS app project (open this)
    App/ManGo/            SwiftUI app (display only); Xcode picks up new files automatically
    App/ManGo/Resources/  bundled PvPoke data. Refresh with scripts/update_pvpoke_data.sh
    PvPCore/              Swift package: GameData (PvPoke parsing), OpponentTracker (energy engine)

## Running it on your iPhone

1. Open `ManGo.xcodeproj` in Xcode.
2. Click the **ManGo** target → **Signing & Capabilities** → set **Team** to your Apple ID's
   Personal Team (add your Apple ID under Xcode → Settings → Accounts first). If the bundle ID
   `com.jovenstriker.mango` is taken, change it to anything unique.
3. Plug in your iPhone, tap **Trust**, and turn on **Settings → Privacy & Security → Developer Mode**.
4. Pick your iPhone at the top of the Xcode window and press **▶**.
5. On first launch, trust the app under **Settings → General → VPN & Device Management**.

With a free Apple ID the app stops working after 7 days; press ▶ again to reinstall.

Tests: `cd PvPCore && swift test --scratch-path ~/Library/Caches/ManGo-PvPCore`. The build folder
has to live outside Documents, because iCloud's file metadata makes code signing fail there.

## Reading the battle screen

`Extension/ManGoBroadcast` is a ReplayKit Broadcast Upload Extension ("ManGo Screen Reader").
While it's recording, it aims to read text 4 times a second with Vision and passes it to
the app through the App Group `group.com.jovenstriker.mango`. `BattleScreenParser` and
`BattleAutomation` (in `PvPCore`) turn the reads into tracker events. These rules come from a
recorded Great League battle:

| On screen | Meaning |
|---|---|
| Your charged move buttons at the bottom ("FLAMETHROWER") | Two missing reads confirm a stop; explicit battle cues can stop immediately. One missed OCR result is not a pause |
| Your top-left pokéballs lose a red ball | Your Pokémon fainted. Dimmed charge labels do not restart counting until replacement evidence appears |
| Name in the top-right box ("CP 1498 Stunfisk") | The opponent's active Pokémon: a switch, a faint replacement, or a new battle |
| "Stunfisk used Discharge!" banner | The opponent's charged move: subtract its cost. A move only one form learns fixes the form |
| "Attack incoming!" / "Get Ready!" | Whose charged move it is, when the banner alone can't tell (mirror matches) |

`PvPCore/Tests/PvPCoreTests/Fixtures/gbl-battle-2026-10-20.json` is that battle's screen text.
The replay test checks every pause, charged move and faint. To analyze a new recording:

    cd PvPCore && swift run --scratch-path ~/Library/Caches/ManGo-PvPCore screen-log <video.mp4>

### Recording battles (debug builds)

Debug builds (pressing ▶ in Xcode) save each battle on the phone: a half-size video, with
ManGo's card in it, plus every read the screen reader made, timed to that video. Release builds
don't. Only the newest 3 battles are kept, in Files → On My iPhone → ManGo. With the phone plugged
in, `scripts/pull_battles.sh` copies them into `Test Videos/` and turns each one's reads into a
fixture, so the battle replays exactly as the card counted it. ManGo then deletes the pulled
battles from the phone the next time it's opened.

### Battle reports

Each recorded battle has a report in `Battle Logs/<video>.log`. It covers how
ManGo counts and the timing settings, then each opponent charged move with the energy math
(`54 = 0 left before + 6 × 9 (Thunder Shock)`), ManGo's fast move count next to the count from
watching the recording, and a timeline of everything the screen reader saw and did. Hand counts and
notes live in `PvPCore/Tests/PvPCoreTests/Fixtures/hand-counts.json`. Regenerate the reports with
`scripts/battle_reports.sh` after changing either. The videos themselves aren't committed.

To add a battle: put the video in `Test Videos/`, run `screen-log <video> 0.25 --json` to get its
screen text, trim it into a fixture like the others, add its hand counts, and add it to the script.

The screen only shows the base name, so the app picks the highest-ranked form until a move reveals
it. Nicknamed Pokémon won't match. The app has no manual controls: start the reader with the record
button, and everything else comes from the screen.

## Accuracy evidence and validation

`swift test` now checks all 34 saved recordings, including the ones with known inaccuracies.
Only recordings whose video is still in `Test Videos/` are kept (the first battle, recorded
without ManGo on October 20, 2026, was dropped with its video on November 9).
A successful behavioral replay is not proof of accurate energy. The accuracy tests deliberately
fail when the model contradicts the evidence; do not change labels to match model output or
mark these failures as expected. POMDP is separate and is not involved in these checks.

There are **86 exact hand counts across 27 recordings** in
`PvPCore/Tests/PvPCoreTests/Fixtures/hand-counts.json`. Each count is the opponent's fast moves
since that Pokémon's previous charged move (or its first appearance), including moves before
switching out. Entries follow opponent charged moves in recording order. `null` means unknown,
not zero. Partial lists do not label the rest of a battle. `countTargets` identifies the Pokémon
and charged move so a missed or misattributed throw cannot silently shift the labels.

| Recording | Opponent's team | Hand counts |
|---|---|---|
| gbl-battle-2026-10-20-mango (TestWithMangoV1) | Marowak, Sableye (Shadow), Talonflame | 5, 4, 5, 5, 7, 3, 4 |
| testV2 | Melmetal, Ninetales (Shadow), Altaria | 6, 6, 0, 6, 2, unknown, unknown |
| testV3 (Fantasy Cup) | Mimikyu, Turtonator, Granbull | 5, 0, 7 |
| v7 | Azumarill, Empoleon, Magnezone | unknown, 4, 10, 1 |
| v8 | Azumarill, Lucario, Mawile | 8, 1, 6, 5, 4 |
| v9 | Turtonator, Mimikyu, Forretress (Shadow) | unknown × 3, 6 |
| v11 | Altaria, Mimikyu, Empoleon | 13, 7, unknown, 5, 5 |
| battle-2026-10-23-132243 | Doublade, Togetic, Stunfisk | 7 |
| battle-2026-10-24-171449 | Corviknight, Azumarill, Turtonator | unknown × 4, 4, unknown |
| battle-2026-10-24-172648 | Hydreigon (Shadow), Stunfisk (Galarian), Melmetal | unknown × 3, 10 |
| battle-2026-10-24-220440 | Stunfisk (Galarian), Forretress, Melmetal | 5, 7, 3 |
| battle-2026-10-23-155712 | Flygon, Corviknight, Azumarill | unknown, unknown, unknown, 5 |
| battle-2026-10-28-002722 | Greninja (Shadow), Florges, Charjabug | unknown × 4, 3, unknown × 2 |
| battle-2026-11-04-155536 | Altaria, Florges, Melmetal | 17, unknown × 5 |
| battle-2026-10-28-221337 (three battles) | Scizor, Guzzlord, Nidoqueen; Greninja (Shadow), Forretress (Shadow), Mimikyu; Forretress, Greninja, Nidoqueen | throw 5: 7; throws 11, 16, 18: 3 each; throws 12, 13: 7, 6; throw 17: 5 |
| battle-2026-11-04-233009 | Morpeko (Full Belly), Jirachi, Azumarill | unknown, 5, unknown × 4 |
| battle-2026-11-08-142007 | Florges, Mimikyu, Sableye (Shadow) | 5, 10, 4, 8, 3, 6 |
| battle-2026-11-08-144330 | Cramorant, Melmetal, Clodsire | 5, 8, 2, 10, 1 |
| battle-2026-11-08-152828 | Marowak, Furret, Talonflame | unknown, 8, unknown × 3 |
| battle-2026-11-08-212316 | Ninetales (Alolan), Quagsire (Shadow), Jumpluff | unknown, 6, 6, unknown, 3 |
| battle-2026-11-08-220414 | Forretress (Shadow), Carbink, Marowak | 24, 7, 5 |
| battle-2026-11-08-223847 | Stunfisk, Annihilape, Fearow | 6, 5 |
| battle-2026-11-08-233921 | Wigglytuff, Stunfisk, Quagsire (Shadow) | 6, 5, 5, 8, 1, 6 |
| battle-2026-11-09-005151 | Diggersby, Fearow, Jumpluff | 5, 5, 5, 5, 5, 9, 4 |
| battle-2026-11-09-010443 | Clodsire, Altaria, Mimikyu | 11, 4 |
| battle-2026-11-09-010753 | Empoleon, Nidoqueen, Forretress (Shadow) | 6, 4, 3 |
| battle-2026-11-09-013324 | Pangoro, Dunsparce, Azumarill | 7, 8, 6 |

Altaria's Dragon Breath counts in testV2 were not counted by eye. Empoleon's first v7 throw
has no count label, but its observed fast move was Waterfall, not the assumed Metal Sound.
The observed moveset is checked separately.

Energy evidence is stored separately from move counts:

- Exact checkpoints: Turtonator 80 and Mimikyu 54 in `battle-2026-10-23-140441`;
  Florges 45 after its fifth Fairy Wind in `battle-2026-10-23-135548`; Stunfisk 70, 71
  and 45 in the corresponding existing replay scenarios. Checkpoint timestamps use the
  existing tests' observation times, which may be later than the visible action.
- Lower bounds: Corviknight's Payback requires at least 60 and Azumarill's Ice Beam at least
  55 in `battle-2026-10-23-155712`. The model's 56 and 44 are incorrect estimates, not labels.
- Lower bounds: Shadow Greninja's throws 11, 16, 18 and 19 in `battle-2026-10-28-221337`
  require at least 40, 35, 40 and 40 energy. The model's 30, 28, 28 and 28 are incorrect
  estimates, not exact energy observations or fast-move counts.

Every detected opponent throw must have enough energy to pay its cost. If the raw clock
estimate is short, reconciliation uses the observed spend as a minimum.
The reports separately fail validation on raw undercounts; making a spend affordable after seeing
it is not evidence that the prediction was accurate. Overestimates can also satisfy affordability. Unlabelled recordings are
checked for affordability, not claimed to be fully hand-verified.

Run `scripts/battle_reports.sh` to regenerate **all** reports. It continues after failures,
prints each result, and exits nonzero if any recording fails validation. `MANGO_BUILD_DIR`
and `MANGO_OUTPUT_DIR` override the build directory (default `/tmp/ManGo-PvPCore`) and output
directory (default `Battle Logs`). Reports use per-read structured observations rather than
the bounded UI log, and count modelled moves from history instead of dividing capped energy.
A report's PASS means only that its available evidence agrees; it is not a full-battle accuracy claim.

The user-supplied rules dated November 4, 2026 guide these mechanics; see
[the tracking contract](docs/tracking-rules.md). In particular, a faint freezes both sides,
a voluntary switch preserves energy, and a switch interrupts assumptions about uninterrupted
rhythm. Pending fast moves credited at your charged move forecast energy after that cinematic.

83 of 86 exact hand counts match, and every energy checkpoint. The third miss, from November 9, 2026: in 013324 Pangoro threw 1 Karate Chop as the lead before switching, not 2, so it began about 1.3s after GO; nothing on screen showed the late start, so ManGo counts 9 before its Rock Slide, not 8. In 221337 you counted Mimikyu's (November 9,
2026): it came in for Greninja as you threw at 6:09, still on its switch turn (Greninja named at
6:08.05), so no Shadow Claw in progress; 7 by its Shadow Sneak in a tie with your Clodsire, then 6 by
the next. So a switch made in play costs its turn even when its name shows in the stop, a charged move
ends a switch turn, your switch as your buttons come back doesn't stop the line-up rule, and there is
no longer a wider line-up window after they block yours (Fearow's, the recording dropped). In 233921 (November 8, 2026) Stunfisk's
Discharge and your Energy Ball were a CMP tie it won: your charged move followed with no play between
(your buttons never came back; in 002722, where Greninja did sneak one after its Hydro Cannon, your
fast move hit it first). So no sneak, and the Thunder Shock the clock had 71% done counts: 5 and 5,
as you counted, not 4 and 6. The lead starts 0.2s after GO is
first read, the only start after the countdown that fits every lead's count; when that first read
caught GO already growing as it fades, it came late and the start is 0.5s earlier. Your HP bar
doesn't date the lead: in 223847 (November 8, 2026) Stunfisk threw 6 Thunder Shocks, not 7. Dated from
its first hit it got 7, since it waited about a second after its sixth before Mud Bomb. A Pokémon switching out in play has
thrown a whole number of fast moves (the switch waits for the one in progress, like a charged move):
your counts on November 9, 2026 put Marowak, Florges, Quagsire, Turtonator, Hydreigon and Altaria at
their time on the field over their fast move, to the nearest, except a lead leaving the opening
(v7's Azumarill, 1). The line-up rule (their charged move
starts as a fast move finishes, so a late-shown restart may hide one more) no longer adds a fast move
when ManGo saw play restart, from their move in progress hitting you: Quagsire's 6 in 212316,
Galarian Stunfisk's 5 after its hit at 0:52.65 in 220440, and Altaria's 2 after its hit at 1:18.92
in 155536, all counted by you. In 152828 (November 8, 2026) Marowak
threw 4 Mud Slaps as the lead (GO was up from 0:43.9 but first read, fading, at 0:44.56), and Furret
stayed on Sucker Punch. On November 8, 2026 you confirmed 144330:
after a CMP tie ManGo keeps the fast move it counted in progress when its clock had it more than half
done (Melmetal's second Thunder Shock, 98%), since both sides throw as their fast moves finish. You
also confirmed all six in 142007; Mimikyu's 3 Shadow Claws before Shadow Sneak needed the HP-bar check to look a fast move
earlier after your charged move, where its move in progress would have hit you had play restarted
sooner. On November 6, 2026 you counted four
switch-ins made during a stop: Mightyena (3 Sucker Punches and a sneak, 125109) and Nidoqueen (6 Mud
Slaps and a sneak, 221337) after your charged moves start at the restart; Charjabug (002722) and
Togetic (171905) after theirs start with your buttons. v7's Azumarill was labelled 9 Bubbles; you recounted it on
November 4, 2026 as 10, as ManGo counts (its card showed 100 at the Ice Beam, and 9 would be 99).
Shadow Greninja's three sneaks in 221337 (5:41, 9:24, and 2 Water Shurikens before its switch at
9:45) are counted from your fast moves. 155712's Azumarill (5 Bubbles: your 3 Dragon Breaths, then
one finished and one sneaked at 2:13) and Corviknight (9 Sand Attacks between its Paybacks) are
counted from their fast move in progress at your charged move hitting you, which shows when play
restarted: up to 0.8s before your buttons came back. Known limits: testV2's Ninetales paused a turn
between Embers (6 by hand, 7 by ManGo, which can't see breaks); 155536's Altaria had at least 50 for
its fifth Sky Attack where ManGo counts 44; and 152828's Furret threw 8 Sucker Punches before its
second Swift where ManGo counts 7 (you think the game lagged; nothing in the recording shows it), so
its third Swift comes up short. Minimum-energy reconciliation keeps those visible as raw prediction
failures.

v7 was enriched with verified HP pixels and your pokéball counts from its original video;
its OCR lines, timestamps, and hand-count labels were preserved. To reproduce pixel enrichment:

    cd PvPCore
    swift run screen-log "../Test Videos/v7.mov" --hp-all Tests/PvPCoreTests/Fixtures/gbl-battle-2026-10-20-v7.json > /tmp/v7-with-verified-hp.json

The verified sampler checks the player's rectangular HP-bar outline and follows its horizontal
movement; it does not treat arbitrary colored sprite pixels as HP. Ambiguous or missing damage
rhythms leave the fast move assumed.

## Overlay on top of Pokémon GO

The card at the top of the app is a Picture-in-Picture "video" (`App/ManGo/PictureInPicture.swift`),
redrawn 4 times a second. Swipe home with ManGo open and it pops out over Pokémon GO; you can also
use **Pop out overlay**. While it's up, ManGo keeps running in the background, so screen reads keep
arriving. You can't tap through a PiP window, so a newly detected Pokémon starts counting with
PvPoke's recommended fast move. PiP needs a real iPhone; the simulator doesn't support it.

Debug builds take a `-demoBattle` launch argument that starts mid-battle against Medicham.
