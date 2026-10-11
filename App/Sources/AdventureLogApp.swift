// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import ALDesign
import ALStore
import SwiftUI
import UserNotifications

@main
struct AdventureLogApp: App {
    @State private var model = AppModel.forLaunch()
    private let colorScheme = LaunchOptions.current.colorScheme

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(ALColor.primary)
                .preferredColorScheme(colorScheme)
        }
        .backgroundTask(.appRefresh(AppModel.refreshTaskID)) { [model] in
            await model.backgroundRefresh()
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

/// The signed-in app: Today, Trip and Map. Log arrives in Stage 3.
struct MainView: View {
    enum AppTab: Hashable { case today, trip, map }

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.today

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            Tab("Today", systemImage: "sun.max", value: AppTab.today) {
                TodayView()
            }
            Tab("Trip", systemImage: "map", value: AppTab.trip) {
                TripsView()
            }
            Tab("Map", systemImage: "mappin.and.ellipse", value: AppTab.map) {
                TripMapTab()
            }
        }
        .task { await model.loadTrips() }
        .task {
            // Pick up changes made on other phones while the app is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await model.refreshOpenTrip()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: AppModel.scheduleBackgroundRefresh()
            default: break
            }
        }
        .alert("Couldn't sign out", isPresented: $model.showingSignOutError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.signOutError ?? "")
        }
    }
}
