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

`swift test` now checks all 24 saved recordings, including the ones with known inaccuracies.
A successful behavioral replay is not proof of accurate energy. The accuracy tests deliberately
fail when the model contradicts the evidence; do not change labels to match model output or
mark these failures as expected. POMDP is separate and is not involved in these checks.

There are **36 exact hand counts across 9 recordings** in
`PvPCore/Tests/PvPCoreTests/Fixtures/hand-counts.json`. Each count is the opponent's fast moves
since that Pokémon's previous charged move (or its first appearance), including moves before
switching out. Entries follow opponent charged moves in recording order. `null` means unknown,
not zero. Partial lists do not label the rest of a battle. `countTargets` identifies the Pokémon
and charged move so a missed or misattributed throw cannot silently shift the labels.

| Recording | Opponent's team | Hand counts |
|---|---|---|
| gbl-battle-2026-10-20 (without ManGo) | Stunfisk, Cramorant, Fearow | 6, 7, 1, 5, 5, 5, 6 |
| gbl-battle-2026-10-20-mango (TestWithMangoV1) | Marowak, Sableye (Shadow), Talonflame | 5, 4, 5, 5, 7, 3, 4 |
| testV2 | Melmetal, Ninetales (Shadow), Altaria | 6, 6, 0, 6, 2, unknown, unknown |
| testV3 (Fantasy Cup) | Mimikyu, Turtonator, Granbull | 5, 0, 7 |
| v7 | Azumarill, Empoleon, Magnezone | unknown, 4, 9, 1 |
| v8 | Azumarill, Lucario, Mawile | 8, 1, 6, 5, 4 |
| v11 | Altaria, Mimikyu, Empoleon | 13, 7, unknown, 5, 5 |
| battle-2026-10-23-132243 | Doublade, Togetic, Stunfisk | 7 |
| battle-2026-10-24-220440 | Stunfisk (Galarian), Forretress, Melmetal | 5 |

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

42 of 43 exact hand counts match, and every energy checkpoint. On November 6, 2026 you counted four
switch-ins made during a stop: Mightyena (3 Sucker Punches and a sneak, 125109) and Nidoqueen (6 Mud
Slaps and a sneak, 221337) after your charged moves start at the restart; Charjabug (002722) and
Togetic (171905) after theirs start with your buttons. v7's Azumarill was labelled 9 Bubbles; you recounted it on
November 4, 2026 as 10, as ManGo counts (its card showed 100 at the Ice Beam, and 9 would be 99).
Shadow Greninja's three sneaks in 221337 (5:41, 9:24, and 2 Water Shurikens before its switch at
9:45) are counted from your fast moves. 155712's Azumarill (5 Bubbles: your 3 Dragon Breaths, then
one finished and one sneaked at 2:13) and Corviknight (9 Sand Attacks between its Paybacks) are
counted from their fast move in progress at your charged move hitting you, which shows when play
restarted: up to 0.8s before your buttons came back. Known limits: testV2's Ninetales paused a turn
between Embers (6 by hand, 7 by ManGo, which can't see breaks), and 155536's Altaria had at least
50 for its fifth Sky Attack where ManGo counts 44. Minimum-energy reconciliation keeps the second
visible as a raw prediction failure.

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
