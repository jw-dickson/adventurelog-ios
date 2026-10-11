// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import ALDesign
import SwiftUI

/// Connect to an AdventureLog server with an API key.
///
/// Pre-design: layout and copy follow the design system's tokens and voice, and will be revised
/// after design review 1.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var server = LaunchOptions.current.serverURL ?? ""
    @State private var apiKey = LaunchOptions.current.apiKey ?? ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case server, key }

    private var canConnect: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: ALSpace.space2) {
                        Image("AdventureLogMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                        Text("Connect to your AdventureLog")
                            .font(ALFont.title2)
                            .foregroundStyle(ALColor.ink)
                        Text("Your trips stay on your server. The app keeps a copy so you can use it offline.")
                            .font(ALFont.subheadline)
                            .foregroundStyle(ALColor.inkMuted)
                    }
                    .padding(.vertical, ALSpace.space2)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Server address", text: $server, prompt: Text("adventurelog.example.com"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .server)
                        .onSubmit { focus = .key }
                        .accessibilityIdentifier("signin.server")
                    SecureField("API key", text: $apiKey, prompt: Text("al_…"))
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .key)
                        .onSubmit { connect() }
                        .accessibilityIdentifier("signin.apikey")
                } footer: {
                    Text("Create an API key in AdventureLog's settings, then paste it here. Use the address you open AdventureLog at in a browser.")
                        .font(ALFont.footnote)
                        .foregroundStyle(ALColor.inkMuted)
                }
                .listRowBackground(ALColor.surface200)

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(ALFont.callout)
                            .foregroundStyle(ALColor.errorText)
                            .accessibilityIdentifier("signin.error")
                    }
                    .listRowBackground(ALColor.surface200)
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView().tint(ALColor.onPrimary)
                            } else {
                                Text("Connect").font(ALFont.headline)
                            }
                            Spacer()
                        }
                        .frame(height: 44)
                    }
                    .foregroundStyle(ALColor.onPrimary)
                    .listRowBackground(canConnect ? ALColor.primary : ALColor.primary.opacity(0.4))
                    .disabled(!canConnect)
                    .accessibilityIdentifier("signin.connect")
                }
            }
            .scrollContentBackground(.hidden)
            .background(ALColor.surface100)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Starts sign-in when both fields are filled and no connection is pending; displays caught errors.
    private func connect() {
        guard canConnect else { return }
        isConnecting = true
        errorMessage = nil
        Task {
            defer { isConnecting = false }
            do {
                try await model.signIn(server: server, apiKey: apiKey)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    SignInView().environment(AppModel.forLaunch(LaunchOptions(resetState: true)))
}
