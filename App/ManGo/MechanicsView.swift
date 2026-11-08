import SwiftUI

/// Explains the Pokémon GO PvP mechanics ManGo's counting is built on.
struct MechanicsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("GO Battle League looks real-time, but it runs in fixed **turns of 0.5 seconds**. Every move takes a whole number of turns, which is what makes the opponent's energy countable.")
                }

                topic("Fast moves", "bolt", [
                    "Each fast move takes **1 to 5 turns** and gives a set amount of energy when it finishes.",
                    "1 turn: Dragon Breath +4, Lick +3. 2 turns: Counter +6, Shadow Claw +8. 3 turns: Charm +8, Bubble +11. 4 turns: Volt Switch +16. 5 turns: Incinerate +20.",
                    "Its damage and energy both land at the end of its last turn, for both players at once.",
                    "Thrown back-to-back, they build energy at a steady rate: Counter gives 6 energy a second.",
                    "Energy caps at **100**.",
                ])

                topic("Charged moves", "flame", [
                    "A charged move costs a set amount of energy, e.g. Ice Punch 40, Rock Slide 45, Flamethrower 55.",
                    "It can only be thrown once your current fast move has finished, and it starts on the next turn. Tapping one mid-move queues it.",
                    "While any charged move plays out, including the shield prompt and the minigame, the battle is frozen: no turns pass.",
                    "If both sides throw on the same turn, the Pokémon with higher Attack goes first (**Charge Move Priority**, CMP). The other's charged move follows.",
                    "A charged move goes before fast-move damage on the same turn, so a Pokémon about to faint can still get its charged move off.",
                    "If the first charged move in a tie knocks the other Pokémon out, the second one never happens.",
                ])

                topic("When you throw a charged move", "arrow.triangle.branch", [
                    "A fast move the opponent already started still counts. Its energy is added once your charged move is over, and then they start fresh.",
                    "If your fast moves finish on the same turn as theirs (\"aligned\"), your charged move takes the next turn, and they start another fast move on it. That one counts too.",
                    "So the opponent gets every fast move they finished, **plus one**.",
                    "Example, your 2-turn move against their 3-turn move: after 3 of yours they get 3, and after 4 of yours they still get 3. Throwing after 1, 4, 7 or 10 fast moves gives them nothing extra.",
                    "The exception: if they throw a charged move on the same turn as you, they weren't in a fast move, so there's no extra one.",
                    "If you throw straight after their charged move, they start a fast move on your charged move's turn (a sneak), and it counts. Unless they switch out right after: then they chose the switch, not a fast move.",
                ])

                topic("Shields", "shield", [
                    "Each side has **2 shields**. A shield blocks a charged move, but the Pokémon still takes 1 damage.",
                    "Shields don't block fast moves.",
                    "Baiting: throw a cheap charged move to draw a shield, then follow with an expensive one.",
                ])

                topic("Switching", "arrow.left.arrow.right", [
                    "A switch costs **1 turn** before the new Pokémon starts its fast moves.",
                    "After any charged move, **both** sides can switch for **0 turns**, whoever threw and whether or not there was a priority tie, as long as they pick the switch as the charged move ends. A switch made once play is back costs the usual turn.",
                    "Replacing a Pokémon that fainted costs **0 turns**. But if **your** Pokémon fainted and theirs is still in, switching is their choice, and it costs them a turn, even right after their charged move.",
                    "Switches go before damage: switch on the turn a fast move lands, and the incoming Pokémon takes the hit.",
                    "After a faint, nobody attacks until the next Pokémon is out.",
                    "A Pokémon keeps its energy while it's on the bench.",
                    "After a switch, a timer has to run out before you can switch again.",
                ])

                topic("Counting fast moves", "number", [
                    "Their energy tells you when a charged move can come. Medicham needs 5 Psycho Cuts (+9 each) for Ice Punch (40), so the shield decision comes after the 5th.",
                    "That's ManGo's job: it counts their energy so you can play.",
                ])

                Section {
                    bullet("Opponent's Pokémon: the name box in the top-right, and the \"Go, X!\" message when it comes out.")
                    bullet("Their fast move starts as PvPoke's recommendation. A charged move it couldn't have afforded switches ManGo to another fast move the Pokémon learns that could have (Flygon on Mud Shot, not Dragon Tail). A repeated rhythm of damage on your HP bar can also show it.")
                    bullet("Running or frozen: charge-button labels and battle cues, with two reads to confirm missing labels. Your remaining pokéballs confirm a faint even when dimmed labels stay visible.")
                    bullet("Charged moves: \"Attack incoming!\" and the \"X used Y!\" banner for theirs, \"Get Ready!\" for yours. A cue still on screen as the banner shows (\"No Protect Shields remaining!\") isn't a second charged move: the next one's cue comes after the banner has gone.")
                    bullet("Start and end: the countdown's \"GO\" (the first turn begins a moment after it appears), and \"YOU WIN!\" / \"GOOD EFFORT!\". If lag skips the countdown, it starts when your buttons appear.")
                    bullet("Their lead starts a moment after GO, unless the first \"…EFFECTIVE\" over your Pokémon shows their first fast move landed later: some opponents start a second or so late.")
                    bullet("Switches: a new name in the top-right box. ManGo works out whether it cost a turn from whether there was a charged move or a faint in the stop, and how soon after the restart the name showed.")
                    bullet("A switch made during the stop counts from when the Pokémon it replaced left: if its name was gone before your buttons came back, the new one starts at the restart, like one that stayed in. After your charged move that's a moment before your buttons; after theirs, even one you shielded, play restarts about when your buttons come back, so it starts with them.")
                    bullet("Their energy can never rise faster than their fast move allows: one move per move's length since ManGo saw that Pokémon come in, plus one for each charged move (yours or theirs) and one the screen may have shown late, on top of what it came in with. At your charged move there's no allowance for the screen: a Pokémon that switched in a second before is only partway through its first fast move.")
                    bullet("Their charged move can only start as one of their fast moves finishes, so when it shows up late after a restart, ManGo may count one more fast move than the clock did. Not if your HP bar showed their hits in that stretch and none landed when that extra one would have. After your charged move, their move in progress lands as play resumes, so ManGo also checks a fast move earlier, where that hit would have been if play had restarted that soon.")
                    bullet("If you and they throw on the same turn (CMP), they had no fast move in progress, so no sneak. You both throw as your fast moves finish, so they'd finished a whole number: ManGo takes back the move it counted in progress at your charged move if its clock had it less than half done, and keeps it if nearer done (it had landed; the clock was a moment behind). ManGo sees a tie when both charged moves play out; if yours knocks theirs out first, theirs never shows, but its energy no longer matters.")
                    bullet("The reader aims for 4 reads per second; actual intervals vary. ManGo estimates stop and restart times between reads. A switch by your Pokémon disables corrections that assume an uninterrupted opponent rhythm.")
                    bullet("After your charged move, their fast move in progress finishes as play resumes, so when it hits you (\"NOT VERY EFFECTIVE...\" or \"SUPER EFFECTIVE!\" over your Pokémon) the battle has restarted, sometimes almost a second before your buttons can be read. Unless that hit knocks yours out: play then waits for your next Pokémon.")
                    bullet("Your own fast moves are its clock: each one fills your charged move buttons a step, which the reader sees on every frame. After a restart both sides start fast moves on the same turn, so your first one landing shows when the battle really restarted, often about 0.7s before your buttons can be read. Their fast moves count from then, less a third of a second for them to react. That's how it catches their sneak when your fast moves and theirs finish together (Mud Slap and Water Shuriken, both 3 turns).")
                    bullet("Between battles it reads every 2 seconds, and stops after 3 minutes without a new battle.")
                } header: {
                    Label("How ManGo follows the battle", systemImage: "eye")
                }

                Section {
                    bullet("If the opponent pauses between fast moves, or lag delays them, ManGo counts too many. It can't see pauses.")
                    bullet("If their fast move is unknown, the count is an estimate. A clear repeated damage rhythm can help, but moves with the same duration remain ambiguous.")
                    bullet("If they throw a charged move ManGo's count couldn't have paid for, it raises their energy to that move's cost and counts on from there. If reads stop, the energy stops counting up until they're back.")
                    bullet("Your fast moves can't show the restart when your buttons are already full, or when your fast move takes 1 turn (it lands while the buttons are still fading in). Then ManGo goes by the buttons alone.")
                    bullet("If you tie with their charged move and yours knocks them out, nothing shows they threw, so ManGo counts a fast move they didn't get. That Pokémon is out, so it doesn't matter.")
                    bullet("Nicknamed opponent Pokémon aren't recognized.")
                } header: {
                    Label("Where ManGo can be off", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle("How PvP works")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func topic(_ title: String, _ icon: String, _ points: [String]) -> some View {
        Section {
            ForEach(points, id: \.self) { bullet($0) }
        } header: {
            Label(title, systemImage: icon)
        }
    }

    private func bullet(_ text: String) -> some View {
        Text(.init(text)).font(.callout)
    }
}

#Preview {
    MechanicsView()
}
