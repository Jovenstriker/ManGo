import Foundation
import Testing
@testable import PvPCore

@Test func hpBarHitsAreFallsThatStayDown() {
    // A 250-pixel bar read 60 times a second: a hit at 1.0s, one drained over 0.3s from 2.0s,
    // an effect over the bar at 3.0s for 0.1s, one misread at 3.5s, a new Pokémon's bar at 4.0s,
    // and a hit on it at 4.5s.
    let samples: [[Double]] = (0..<330).map { k in
        let t = Double(k) / 60
        var pixels = 240.0
        if t >= 1.0 { pixels -= 10 }
        if t >= 2.0 { pixels -= min(10, (t - 2.0) / 0.3 * 10) }
        if t >= 3.0, t < 3.1 { pixels -= 30 }
        if abs(t - 3.5) < 0.005 { pixels = 100 }
        if t >= 4.0 { pixels = 250 }
        if t >= 4.5 { pixels -= 8 }
        return [t, pixels / 250, 250]
    }
    let hits = YourHPBar.hits(in: samples)
    #expect(hits.count == 3)
    #expect(hits.count == 3 && abs(hits[0] - 1.0) < 0.05 && abs(hits[1] - 2.05) < 0.1 && abs(hits[2] - 4.5) < 0.05)
}
