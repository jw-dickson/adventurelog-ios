// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import ALDesign
import ALStore
import SwiftUI

@main
struct AdventureLogApp: App {
    @State private var model = AppModel.forLaunch()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(ALColor.primary)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .signedOut:
            SignInView()
        case .signedIn:
            TripsView()
        }
    }
}
