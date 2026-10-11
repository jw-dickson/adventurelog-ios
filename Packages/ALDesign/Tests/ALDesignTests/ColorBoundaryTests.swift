// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Testing
@testable import ALDesign

@Suite("Color channel boundaries")
struct ColorBoundaryTests {
    @Test(arguments: [(0, 128, 255), (255, 0, 128), (128, 255, 0)])
    func channelsAreNormalisedIndependently(_ red: Int, _ green: Int, _ blue: Int) {
        let color = ALRGBA(red, green, blue)
        #expect(abs(color.red - Double(red) / 255) < 0.000_001)
        #expect(abs(color.green - Double(green) / 255) < 0.000_001)
        #expect(abs(color.blue - Double(blue) / 255) < 0.000_001)
        #expect(color.alpha == 1)
    }

    @Test(arguments: [0.0, 0.25, 1.0])
    func alphaIsPreservedWithoutRGBScaling(_ alpha: Double) {
        let color = ALRGBA(255, 255, 255, alpha)
        #expect(color.alpha == alpha)
        #expect(color.red == 1)
        #expect(color.green == 1)
        #expect(color.blue == 1)
    }
}
