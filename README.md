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
    App/ManGo/            SwiftUI app (manual tap mode); Xcode picks up new files automatically
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

## Computer vision plan

The goal is to replace taps with events from a ReplayKit Broadcast Upload Extension, which has
a memory limit of about 50 MB:

| Event | Signal on screen |
|---|---|
| `setActive` | Opponent's name, read with Apple's Vision text recognition (top-right) |
| `identifyFastMove` | First fast move animation or damage tick. The move's turn length and damage can tell candidate moves apart |
| `opponentThrewChargedMove` | Charged move banner or shield prompt. Read the move name from the banner text |
| `pause` / `resume` | Cinematic starts and ends (screen layout changes) |

The extension and the app share events through an App Group. A Picture-in-Picture window can
show the readout on top of the game.
