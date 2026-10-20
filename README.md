# ManGo

An iOS tracker for the opponent's energy in Pokémon GO Great League, using PvPoke's game data
and Great League rankings.

## How it tracks energy

PvP runs in 0.5s turns. Once you've seen the opponent's fast move, assume they throw it
back-to-back, so energy comes from the clock alone:

    energy = min(100, banked + floor(battle time since first seen / move length) × energy gain)

- **Charged move thrown:** subtract its cost and restart the fast move chain. The battle clock
  pauses during the cinematic.
- **Your charged move:** pause the clock. Their fast move freezes mid-animation and continues
  when the battle resumes.
- **Switch:** the outgoing Pokémon keeps its energy. The incoming Pokémon's fast moves start
  1 turn later, or 0 turns if the opponent switches right after throwing a charged move.
  A Pokémon whose fast move is already known (seen before, or it has only one) starts
  counting on its own.
- **Faint:** both sides stop attacking until the next Pokémon comes out. If theirs fainted,
  their replacement starts with no switch turn.
- **Pokémon list:** only PvPoke's top 500 in Great League, sorted by rank.

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
While it's recording, it reads all the text on screen 4 times a second with Vision and passes it to
the app through the App Group `group.com.jovenstriker.mango`. `BattleScreenParser` and
`BattleAutomation` (in `PvPCore`) turn the reads into tracker events. These rules come from a
recorded Great League battle:

| On screen | Meaning |
|---|---|
| Your charged move buttons at the bottom ("FLAMETHROWER") | The battle is running. When they disappear (either side's charged move, a faint), the clock stops |
| Name in the top-right box ("CP 1498 Stunfisk") | The opponent's active Pokémon: a switch, a faint replacement, or a new battle |
| "Stunfisk used Discharge!" banner | The opponent's charged move: subtract its cost. A move only one form learns fixes the form |
| "Attack incoming!" / "Get Ready!" | Whose charged move it is, when the banner alone can't tell (mirror matches) |

`PvPCore/Tests/PvPCoreTests/Fixtures/gbl-battle-2026-10-20.json` is that battle's screen text.
The replay test checks every pause, charged move and faint. To analyze a new recording:

    cd PvPCore && swift run --scratch-path ~/Library/Caches/ManGo-PvPCore screen-log <video.mp4>

### Battle reports

Each recorded battle has a report next to its video, `Test Videos/<video>.log`. It covers how
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

## Overlay on top of Pokémon GO

The card at the top of the app is a Picture-in-Picture "video" (`App/ManGo/PictureInPicture.swift`),
redrawn 4 times a second. Swipe home with ManGo open and it pops out over Pokémon GO; you can also
use **Pop out overlay**. While it's up, ManGo keeps running in the background, so screen reads keep
arriving. You can't tap through a PiP window, so a newly detected Pokémon starts counting with
PvPoke's recommended fast move. PiP needs a real iPhone; the simulator doesn't support it.

Debug builds take a `-demoBattle` launch argument that starts mid-battle against Medicham.
