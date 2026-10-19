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

## Reading the opponent's name

`Extension/ManGoBroadcast` is a ReplayKit Broadcast Upload Extension ("ManGo Screen Reader").
While it's recording, it reads the top-right of the screen twice a second with Vision and passes
the text to the app through the App Group `group.com.jovenstriker.mango`. The app matches the text
against the top 500 names, allowing for small OCR errors. Once a name has been read twice in a row,
it becomes the active opponent:

- a name already on their team counts as a switch, or as the replacement after a faint
- a new name is added to their team
- a 4th new name starts a new battle

The screen shows only the base name, so the app picks the highest-ranked form (e.g. Shadow
Ninetales). Use **Form** to correct it. Nicknamed Pokémon won't match.

Start it with the record button in the app, or from Control Center (long-press Screen Recording →
ManGo Screen Reader). **⋯ → Test with screenshot** runs the reader on a saved battle screenshot.

## Overlay on top of Pokémon GO

The card at the top of the app is a Picture-in-Picture "video" (`App/ManGo/PictureInPicture.swift`),
redrawn 4 times a second. Swipe home with ManGo open and it pops out over Pokémon GO; you can also
use **Pop out overlay**. While it's up, ManGo keeps running in the background, so screen reads keep
arriving. You can't tap through a PiP window, so a newly detected Pokémon starts counting with
PvPoke's recommended fast move. PiP needs a real iPhone; the simulator doesn't support it.

Debug builds take a `-demoBattle` launch argument that starts mid-battle against Medicham.

## Computer vision: next steps

| Event | Signal on screen |
|---|---|
| `identifyFastMove` | First fast move animation or damage tick |
| `opponentThrewChargedMove` | Charged move banner. Read the move name from the banner text |
| `pause` / `resume` | Cinematic starts and ends (screen layout changes) |

