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
                ])

                topic("Shields", "shield", [
                    "Each side has **2 shields**. A shield blocks a charged move, but the Pokémon still takes 1 damage.",
                    "Shields don't block fast moves.",
                    "Baiting: throw a cheap charged move to draw a shield, then follow with an expensive one.",
                ])

                topic("Switching", "arrow.left.arrow.right", [
                    "A switch costs **1 turn** before the new Pokémon starts its fast moves.",
                    "It costs **0 turns** for the side whose charged move came last in the stop, if they pick the switch as the charged moves end. A switch made once play is back costs the usual turn.",
                    "If your charged move came after theirs, their switch costs a turn, even though they threw in that stop.",
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
                    bullet("Their fast move: PvPoke's recommended one, thrown nonstop. A charged move it couldn't have afforded switches ManGo to another fast move the Pokémon learns.")
                    bullet("Running or frozen: your charged move buttons are on screen while the battle runs.")
                    bullet("Charged moves: \"Attack incoming!\" and the \"X used Y!\" banner for theirs, \"Get Ready!\" for yours.")
                    bullet("Start and end: the countdown's \"GO\" (the first turn begins a moment after it appears), and \"YOU WIN!\" / \"GOOD EFFORT!\". If lag skips the countdown, it starts when your buttons appear.")
                    bullet("Switches: a new name in the top-right box. ManGo works out whether it cost a turn from who threw last in the stop, whether your Pokémon fainted, and how soon after the restart the name showed.")
                    bullet("The screen is read 4 times a second, so ManGo back-dates when the battle stopped and restarted. Their charged moves always start as a fast move finishes, which it uses to correct its timing.")
                    bullet("Between battles it reads every 2 seconds, and stops after 3 minutes without a new battle.")
                } header: {
                    Label("How ManGo follows the battle", systemImage: "eye")
                }

                Section {
                    bullet("If the opponent pauses between fast moves, or lag delays them, ManGo counts too many. It can't see pauses.")
                    bullet("If they use a fast move other than PvPoke's recommended one, the count runs at the wrong rate until a charged move gives it away.")
                    bullet("Right after a charged move it can be off by one fast move if your buttons come back unusually early or late.")
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
