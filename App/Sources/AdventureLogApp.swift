// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import ALDesign
import ALStore
import SwiftUI

@main
struct AdventureLogApp: App {
    @State private var model = AppModel.forLaunch()
    private let colorScheme = LaunchOptions.current.colorScheme

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(ALColor.primary)
                .preferredColorScheme(colorScheme)
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
            MainView()
        }
    }
}

/// The signed-in app. Stage 1 has the Trip and Map tabs; Today arrives in Stage 2 and Log in Stage 3.
struct MainView: View {
    enum AppTab: Hashable { case trip, map }

    @Environment(AppModel.self) private var model
    @State private var tab = AppTab.trip

    var body: some View {
        TabView(selection: $tab) {
            Tab("Trip", systemImage: "map", value: AppTab.trip) {
                TripsView()
            }
            Tab("Map", systemImage: "mappin.and.ellipse", value: AppTab.map) {
                TripMapTab()
            }
        }
        .task { await model.loadTrips() }
    }
}
