import SwiftUI

/// Explains the Pokémon GO PvP mechanics ManGo's counting is built on.
struct MechanicsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("GO Battle League looks real-time, but it runs in fixed **turns of 0.5 seconds**. Everything ManGo counts follows from that.")
                }

                topic("Fast moves", "bolt", [
                    "Each fast move takes a set number of turns and gives a set amount of energy. Counter: 2 turns, +6. Mud Slap: 3 turns, +10. Dragon Breath: 1 turn, +4.",
                    "Fast moves go back-to-back, so energy builds at a steady rate: Counter gives 6 energy every second.",
                    "Energy caps at 100.",
                ])

                topic("Charged moves", "flame", [
                    "A charged move needs a set amount of energy, e.g. Ice Punch 40, Rock Slide 45, Flamethrower 55. Throwing it spends that energy.",
                    "A charged move can only start once the current fast move's animation has finished. Tapping one mid-move queues it.",
                    "While either side's charged move plays out, including the shield prompt and minigame, the battle is frozen and no turns pass.",
                    "If both sides throw on the same turn, the Pokémon with higher Attack goes first (Charge Move Priority, CMP).",
                ])

                topic("When you throw a charged move", "arrow.triangle.branch", [
                    "The opponent keeps the energy from a fast move they'd already started. Your charged move interrupts it, but it still lands (unless your charged move knocks them out), and they start fresh afterwards.",
                    "If your fast moves end on the same turn as theirs (they're \"aligned\"), your charged move takes the next turn, and they start a new fast move on it. It counts too.",
                    "Example against a 3-turn move: two 2-turn moves then a charged move give them the same as one, since their 2nd move is in progress either way. Three 2-turn moves line up with two 3-turn ones and hand them a third.",
                ])

                topic("Shields", "shield", [
                    "Each side has 2 shields. A shield blocks a charged move's damage, but the Pokémon still takes 1 damage.",
                    "Shields don't block fast moves.",
                    "Baiting: throw a cheap charged move to draw a shield, then follow with an expensive one.",
                ])

                topic("Switching", "arrow.left.arrow.right", [
                    "A switch takes 1 turn before the new Pokémon starts its fast moves.",
                    "It takes 0 turns right after the switching side threw a charged move, and after a faint.",
                    "After a faint, both sides stop attacking until the next Pokémon comes out.",
                    "A switched-out Pokémon keeps its energy for when it comes back.",
                    "After a switch there's a switch timer before you can switch again.",
                ])

                topic("Counting fast moves", "number", [
                    "Knowing their energy tells you when a charged move is coming. If Medicham needs 5 Psycho Cuts for Ice Punch, a shield decision comes after the 5th, not before.",
                    "That's ManGo's job: it counts their energy so you don't have to.",
                ])

                Section {
                    bullet("Opponent's name, from the box in the top-right.")
                    bullet("Their fast move: assumed to be PvPoke's recommended one, thrown nonstop.")
                    bullet("Energy goes up as each fast move starts, while they can't afford a charged move yet, so the number shows what they'll have once it lands. Once they can, it goes up as each move lands: they might throw instead, and the number never has to go back down.")
                    bullet("Battle running or frozen: your charged move buttons at the bottom are on screen while it runs.")
                    bullet("Their charged moves: the \"X used Y!\" banner. Yours: \"Get Ready!\" or your Pokémon's banner.")
                    bullet("Start and end: the countdown's \"GO\", and \"YOU WIN!\" / \"GOOD EFFORT!\".")
                    bullet("The screen is read 4 times a second, so ManGo back-dates when the battle stopped and restarted, and uses \"a charged move starts as a fast move finishes\" to correct its guess when they throw.")
                } header: {
                    Label("How ManGo follows the battle", systemImage: "eye")
                }

                Section {
                    bullet("If the opponent pauses between fast moves, ManGo counts one too many. It can't see pauses.")
                    bullet("If they use a fast move other than PvPoke's recommended one, the count runs at the wrong rate.")
                    bullet("Right after a charged move it can be off by one fast move when your buttons come back unusually early or late.")
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
