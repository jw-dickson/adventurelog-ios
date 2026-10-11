// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import ALDesign

@Suite("Design tokens")
struct ALDesignTests {
    @Test func radiiMatchAdventureLog() {
        #expect(ALRadius.box == 16)
        #expect(ALRadius.btn == 8)
        #expect(ALRadius.badge == 30)
    }

    @Test func spacingIsOnAFourPointGrid() {
        for value in [ALSpace.space1, ALSpace.space2, ALSpace.space3, ALSpace.space4, ALSpace.space5, ALSpace.space6, ALSpace.space8] {
            #expect(value.truncatingRemainder(dividingBy: 4) == 0)
        }
    }

    @Test func channelsAreNormalised() {
        let c = ALRGBA(62, 107, 87, 0.5)
        #expect(abs(c.red - 62.0 / 255) < 0.000_1)
        #expect(c.alpha == 0.5)
    }
}
