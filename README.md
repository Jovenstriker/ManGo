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
- **Switch:** the outgoing Pokémon keeps its energy. A returning Pokémon whose fast move is
  already known starts counting again right away.

The engine is in `Sources/PvPCore` (a Swift package with no UI). `OpponentTracker` takes
timestamped events, so it doesn't care whether they come from taps or from computer vision.

## Layout

    Sources/PvPCore/      GameData (PvPoke parsing), OpponentTracker (energy engine)
    Tests/PvPCoreTests/   engine tests (swift-testing)
    App/ManGo/            SwiftUI app (manual tap mode)
    App/ManGo/Resources/  bundled PvPoke data. Refresh with scripts/update_pvpoke_data.sh

## Running it

1. Install Xcode from the Mac App Store.
2. File → New → Project → iOS App, named `ManGo`, saved in this folder. Delete the generated
   `ContentView.swift` and `ManGoApp.swift`, then drag in `App/ManGo/` (including Resources).
3. File → Add Package Dependencies → Add Local… → pick this folder → add `PvPCore` to the app target.
4. Set the deployment target to iOS 17. Run on your phone (signing with a free Apple ID works,
   but the app has to be reinstalled every 7 days).

Tests: `swift test` (or ⌘U in Xcode).

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
