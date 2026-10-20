import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PvPCore

private func makeData() -> GameData {
    func species(_ id: String, _ name: String, rank: Int) -> Species {
        var s = Species(speciesId: id, speciesName: name, fastMoves: [], chargedMoves: [])
        s.rank = rank
        return s
    }
    return GameData(
        species: [
            species("azumarill", "Azumarill", rank: 12),
            species("ninetales_alolan", "Ninetales (Alolan)", rank: 40),
            species("ninetales_shadow", "Ninetales (Shadow)", rank: 3),
            species("mr_mime_galarian", "Mr. Mime (Galarian)", rank: 200),
            species("medicham", "Medicham", rank: 55),
        ],
        moves: []
    )
}

@Test func matchesBaseNameAcrossForms() throws {
    let m = NameMatcher(data: makeData())
    let match = try #require(m.match("NINETALES"))
    #expect(match.distance == 0)
    #expect(match.candidates.map(\.speciesId) == ["ninetales_shadow", "ninetales_alolan"])
    #expect(m.match("Mr. Mime")?.candidates.first?.speciesId == "mr_mime_galarian")
}

@Test func toleratesSmallOCRErrors() {
    let m = NameMatcher(data: makeData())
    #expect(m.match("Azumari1l")?.key == "azumarill")  // "1" for "l": dropped digit, 1 edit
    #expect(m.match("Medichan")?.key == "medicham")
    #expect(m.match("CP 1498") == nil)
    #expect(m.match("Shield") == nil)
}

/// Renders a fake battle screen: your Pokémon's name top-left, the opponent's top-right.
private func renderBattleScreen(player: String, opponent: String) throws -> CGImage {
    let w = 1170, h = 2532
    let ctx = try #require(CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    func draw(_ text: String, x: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs))
        ctx.textPosition = CGPoint(x: x, y: CGFloat(h) - 330)  // CG origin is bottom-left
        CTLineDraw(line, ctx)
    }
    draw(player, x: 70)
    draw(opponent, x: 700)
    return try #require(ctx.makeImage())
}

@Test func readsBothNameBoxesWithPositions() throws {
    let image = try renderBattleScreen(player: "Medicham", opponent: "Azumarill")
    let lines = try ScreenTextReader.recognize(in: image)
    // The opponent's name is in the top-right, yours in the top-left.
    let azu = try #require(lines.first { $0.text == "Azumarill" })
    #expect(azu.box.minX > 0.5 && azu.box.minY < 0.2)
    let med = try #require(lines.first { $0.text == "Medicham" })
    #expect(med.box.maxX < 0.5 && med.box.minY < 0.2)
    #expect(NameMatcher(data: makeData()).match(azu.text)?.key == "azumarill")
}
