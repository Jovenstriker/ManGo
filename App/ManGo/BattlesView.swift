import PvPCore
import SwiftUI

/// The battles you've played, newest first, each with a timeline like PvPoke's.
struct BattlesView: View {
    let history: BattleHistory
    @Environment(\.dismiss) private var dismiss
    @State private var path: [BattleSummary.ID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if history.battles.isEmpty {
                    ContentUnavailableView(
                        "No battles yet", systemImage: "list.bullet.rectangle",
                        description: Text("Battles you play with the screen reader on show up here when they end."))
                } else {
                    List {
                        ForEach(history.battles) { battle in
                            NavigationLink(value: battle.id) { BattleRow(battle: battle) }
                        }
                        .onDelete { offsets in
                            for i in offsets { history.delete(history.battles[i].id) }
                        }
                    }
                }
            }
            .navigationTitle("Battles")
            .navigationDestination(for: BattleSummary.ID.self) { id in
                if let battle = history.battles.first(where: { $0.id == id }) { BattleSummaryView(battle: battle) }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if DEBUG
        // Launch with `-showBattle` too to open the newest battle, for checking its timeline.
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-showBattle"), let first = history.battles.first { path = [first.id] }
        }
        #endif
    }
}

private struct BattleRow: View {
    let battle: BattleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("vs " + battle.opponentTeam.joined(separator: ", ")).font(.headline).lineLimit(1)
                Spacer()
                ResultBadge(result: battle.result)
            }
            Text(battle.date, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ResultBadge: View {
    let result: String?

    var body: some View {
        if let result {
            Text(result.capitalized)
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(result == "won" ? Color.green.opacity(0.2) : result == "lost" ? Color.red.opacity(0.2) : Color.gray.opacity(0.2), in: Capsule())
        }
    }
}

/// One battle: both sides on a PvPoke-style timeline, then the charged moves in order.
struct BattleSummaryView: View {
    let battle: BattleSummary
    @State private var fit = !Self.startZoomed

    #if DEBUG
    /// Launch with `-zoomTimeline` to open timelines zoomed in, for checking them.
    private static let startZoomed = ProcessInfo.processInfo.arguments.contains("-zoomTimeline")
    #else
    private static let startZoomed = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("vs " + battle.opponentTeam.joined(separator: ", ")).font(.headline)
                        Spacer()
                        ResultBadge(result: battle.result)
                    }
                    if !battle.yourTeam.isEmpty {
                        Text("Your " + battle.yourTeam.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Scale", selection: $fit) {
                        Text("Scale to fit").tag(true)
                        Text("Zoom in").tag(false)
                    }
                    .pickerStyle(.segmented)
                    BattleTimeline(battle: battle, fit: fit)
                    Text("Top: their side. Bottom: yours, your fast moves filled in from their length. Charged moves take no time in battle, so each gets its own space.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text("Actions").font(.headline).padding(.bottom, 6)
                    ForEach(Array(BattleAction.list(battle).enumerated()), id: \.offset) { i, action in
                        switch action {
                        case .charged(let move): ChargedMoveRow(number: i + 1, move: move)
                        case .marker(let marker): MarkerRow(number: i + 1, marker: marker)
                        }
                        Divider()
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Battle")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A charged move, a switch or a faint, in the order they happened.
private enum BattleAction {
    case charged(BattleSummary.ChargedMove)
    case marker(BattleSummary.Marker)

    /// A switch or faint at a stop goes after that stop's charged moves: it came after them.
    static func list(_ battle: BattleSummary) -> [BattleAction] {
        let charged = battle.chargedMoves.map { (time: $0.time, action: BattleAction.charged($0)) }
        let markers = battle.markers.map { (time: $0.time + 0.001, action: BattleAction.marker($0)) }
        return (charged + markers).enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element.action)
    }
}

/// "They: Florges → Charjabug", with the energy Florges left with and a 0-turn switch called out.
private struct MarkerRow: View {
    let number: Int
    let marker: BattleSummary.Marker

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
            Image(systemName: marker.kind == .switched ? "arrow.up.arrow.down" : "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(marker.kind == .fainted ? Color.red : Color.secondary)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(marker.side == .you ? "You" : "They"): \(title)").font(.subheadline)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if marker.kind == .switched, marker.turns == 0 {
                Text("0-turn switch").font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 6)
    }

    private var title: String {
        switch (marker.kind, marker.side) {
        case (.switched, .you): "switched"
        case (.switched, .them):
            if let out = marker.other, let into = marker.pokemon { "\(out) → \(into)" } else { "switched to \(marker.pokemon ?? "another Pokémon")" }
        case (.fainted, .you): "fainted"
        case (.fainted, .them): "\(marker.pokemon ?? "their Pokémon") fainted"
        }
    }

    private var detail: String? {
        var parts: [String] = []
        switch marker.kind {
        case .switched:
            if let out = marker.energyOut { parts.append("\(marker.other ?? "It") left with \(out) energy") }
            if let back = marker.energyIn { parts.append("\(marker.pokemon ?? "The other") came back with \(back)") }
            if marker.turns == 1 { parts.append("1-turn switch") }
        case .fainted:
            if marker.side == .them, let next = marker.other {
                parts.append(marker.energyIn.map { "\(next) came back in with \($0) energy" } ?? "\(next) came in")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ChargedMoveRow: View {
    let number: Int
    let move: BattleSummary.ChargedMove

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
            Circle().fill(TypeColors.color(move.type)).frame(width: 12, height: 12)
                .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 0.75))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(move.side == .you ? "You" : "They"): \([move.pokemon, move.name].compactMap { $0 }.joined(separator: " · "))")
                    .font(.subheadline)
                if move.side == .them, let before = move.energyBefore, let after = move.energyAfter {
                    Text("Their energy \(before) → \(after)").font(.caption).foregroundStyle(.secondary)
                } else if move.side == .you, let after = move.energyAfter {
                    Text("Their energy then \(after)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if move.shielded {
                Label("Shielded", systemImage: "shield.fill").labelStyle(.iconOnly).foregroundStyle(TypeColors.shield)
            }
        }
        .padding(.vertical, 6)
    }
}

/// The two rows, theirs on top: fast moves as blocks as long as their turns, charged moves as
/// rings building to a circle in the move's color, a pink hexagon where the other side shielded,
/// ⇅ for a switch and a red X for a faint.
struct BattleTimeline: View {
    let battle: BattleSummary
    let fit: Bool

    static let height: CGFloat = 100
    static let rows: (them: CGFloat, you: CGFloat) = (32, 78)
    /// Points per second of play when zoomed in: 7 per turn.
    static let zoomed: Double = 14

    var body: some View {
        GeometryReader { proxy in
            let layout = TimelineLayout(battle: battle, width: fit ? proxy.size.width : nil)
            ScrollView(.horizontal, showsIndicators: !fit) {
                Canvas { context, _ in layout.draw(in: &context) }
                    .frame(width: layout.width, height: Self.height)
            }
            .scrollDisabled(fit)
        }
        .frame(height: Self.height)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.6), lineWidth: 1.5))
        .accessibilityElement()
        .accessibilityLabel("Timeline of the battle: \(battle.chargedMoves.count) charged moves")
    }
}

/// Where everything goes. Each charged move gets `span` seconds' width of its own at its stop:
/// less when fitted to the screen, so the fast moves keep some room.
private struct TimelineLayout {
    let battle: BattleSummary
    let charged: [BattleSummary.ChargedMove]
    let pps: Double
    let span: Double
    static let inset = 14.0

    init(battle: BattleSummary, width: CGFloat?) {
        self.battle = battle
        charged = battle.chargedMoves.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        span = width == nil ? 4 : 2
        let seconds = max(1, battle.duration + span * Double(charged.count))
        pps = width.map { max(1, (Double($0) - 2 * Self.inset) / seconds) } ?? BattleTimeline.zoomed
    }

    var width: CGFloat { CGFloat((battle.duration + span * Double(charged.count)) * pps + 2 * Self.inset) }

    /// Where something starting at `t` goes: after the charged moves of a stop at `t`.
    func xStart(_ t: Double) -> Double { (t + span * Double(charged.filter { $0.time <= t + 1e-6 }.count)) * pps + Self.inset }
    /// Where something ending at `t` goes: before the charged moves of a stop at `t`.
    func xEnd(_ t: Double) -> Double { (t + span * Double(charged.filter { $0.time < t - 1e-6 }.count)) * pps + Self.inset }
    func span(_ k: Int) -> ClosedRange<Double> {
        let from = (charged[k].time + span * Double(k)) * pps + Self.inset
        return from...(from + span * pps)
    }

    func y(_ side: BattleSummary.Side) -> Double { Double(side == .them ? BattleTimeline.rows.them : BattleTimeline.rows.you) }

    func draw(in context: inout GraphicsContext) {
        for side in [BattleSummary.Side.them, .you] {
            var line = Path()
            line.move(to: CGPoint(x: Self.inset * 0.5, y: y(side)))
            line.addLine(to: CGPoint(x: Double(width) - Self.inset * 0.5, y: y(side)))
            context.stroke(line, with: .color(.primary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        let unit = min(1, pps / BattleTimeline.zoomed)  // shapes shrink a little when fitted
        for f in battle.fastMoves {
            let x0 = xStart(f.start) + 0.6
            let x1 = max(x0 + 1.5, xEnd(f.end) - 0.6)
            let h = 12 * max(0.75, unit)
            let block = Path(roundedRect: CGRect(x: x0, y: y(f.side) - h / 2, width: x1 - x0, height: h), cornerRadius: 1.5)
            context.fill(block, with: .color(TypeColors.color(f.type)))
            context.stroke(block, with: .color(.black.opacity(0.55)), lineWidth: 0.7)
        }
        // A charged move's space sets its size: a trail of rings growing toward its circle.
        let room = span * pps
        let big = min(10, max(3.5, room * 0.2))
        let rings = room > 40 ? 7 : room > 20 ? 4 : 2
        for (k, move) in charged.enumerated() {
            let range = span(k)
            let center = range.upperBound - big - 1
            let color = TypeColors.color(move.type)
            for i in 0..<rings {
                let f = Double(i) / Double(rings)
                let r = big * (0.3 + 0.6 * f)
                let left = range.lowerBound + 2 + big * 0.3
                let x = left + f * max(0, center - big * 0.6 - left)
                context.stroke(Path(ellipseIn: CGRect(x: x - r, y: y(move.side) - r, width: 2 * r, height: 2 * r)), with: .color(color), lineWidth: big > 6 ? 1.6 : 1)
            }
            let circle = Path(ellipseIn: CGRect(x: center - big, y: y(move.side) - big, width: 2 * big, height: 2 * big))
            context.fill(circle, with: .color(color))
            context.stroke(circle, with: .color(.black), lineWidth: big > 6 ? 1.8 : 1.2)
            if move.shielded {
                let hex = hexagon(center: CGPoint(x: center, y: y(move.side == .them ? .you : .them)), radius: big * 0.9)
                context.fill(hex, with: .color(TypeColors.shield))
                context.stroke(hex, with: .color(TypeColors.shield.opacity(0.6)), lineWidth: 3)
                context.stroke(hex, with: .color(.black.opacity(0.35)), lineWidth: 0.8)
            }
        }
        let mark = min(6, max(3.5, room * 0.22))
        for m in battle.markers {
            let x = xStart(m.time) + mark
            switch m.kind {
            case .switched:
                let c = CGPoint(x: x, y: y(m.side) - 21)
                context.stroke(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .color(.primary.opacity(0.7)), lineWidth: 1)
                context.draw(Text("⇅").font(.system(size: 11, weight: .bold)).foregroundStyle(.primary), at: c)
            case .fainted:
                var cross = Path()
                cross.move(to: CGPoint(x: x - mark, y: y(m.side) - mark)); cross.addLine(to: CGPoint(x: x + mark, y: y(m.side) + mark))
                cross.move(to: CGPoint(x: x + mark, y: y(m.side) - mark)); cross.addLine(to: CGPoint(x: x - mark, y: y(m.side) + mark))
                context.stroke(cross, with: .color(.red), style: StrokeStyle(lineWidth: mark > 4.5 ? 3 : 2, lineCap: .round))
            }
        }
    }

    private func hexagon(center: CGPoint, radius: Double) -> Path {
        var p = Path()
        for i in 0..<6 {
            let a = Double(i) * .pi / 3
            let pt = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Pokémon type colors, as PvPoke and most battle tools draw them.
enum TypeColors {
    static let shield = Color(hex: 0xE0389B)

    static func color(_ type: String?) -> Color {
        guard let type, let hex = hexes[type] else { return Color.gray }
        return Color(hex: hex)
    }

    private static let hexes: [String: UInt32] = [
        "normal": 0xA8A77A, "fire": 0xEE8130, "water": 0x6390F0, "electric": 0xF7D02C, "grass": 0x7AC74C,
        "ice": 0x96D9D6, "fighting": 0xC22E28, "poison": 0xA33EA1, "ground": 0xE2BF65, "flying": 0xA98FF3,
        "psychic": 0xF95587, "bug": 0xA6B91A, "rock": 0xB6A136, "ghost": 0x735797, "dragon": 0x6F35FC,
        "dark": 0x705746, "steel": 0xB7B7CE, "fairy": 0xD685AD,
    ]
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
