// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import ALDesign
import SwiftUI

/// Connect to an AdventureLog server with an API key (Design/review-1, 01).
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var server = LaunchOptions.current.serverURL ?? ""
    @State private var apiKey = LaunchOptions.current.apiKey ?? ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showingKeyHelp = false
    @FocusState private var focus: Field?

    private enum Field { case server, key }

    private var canConnect: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !isConnecting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ALSpace.space4) {
                Image("AdventureLogMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Connect to your AdventureLog")
                    .font(ALFont.title1)
                    .foregroundStyle(ALColor.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Your trips stay on your server. The app keeps a copy so you can use it offline.")
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)

                VStack(alignment: .leading, spacing: 18) {
                    field("Server address") {
                        TextField("Server address", text: $server, prompt: Text("adventurelog.example.com"))
                            .font(ALFont.body)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focus, equals: .server)
                            .onSubmit { focus = .key }
                            .accessibilityIdentifier("signin.server")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        field("API key") {
                            SecureField("API key", text: $apiKey, prompt: Text("al_…"))
                                .font(.system(.subheadline, design: .monospaced, weight: .medium))
                                .textContentType(.password)
                                .submitLabel(.go)
                                .focused($focus, equals: .key)
                                .onSubmit { connect() }
                                .accessibilityIdentifier("signin.apikey")
                        }
                        Text("Create a key in AdventureLog under Settings › API keys, then paste it here.")
                            .font(ALFont.footnote)
                            .foregroundStyle(ALColor.inkMuted)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(ALFont.callout)
                            .foregroundStyle(ALColor.errorText)
                            .accessibilityIdentifier("signin.error")
                    }

                    Button(action: connect) {
                        ZStack {
                            Text("Connect").opacity(isConnecting ? 0 : 1)
                            if isConnecting { ProgressView().tint(ALColor.onPrimary) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ALButtonStyle(.primary))
                    .opacity(canConnect || isConnecting ? 1 : 0.45)
                    .disabled(!canConnect)
                    .padding(.top, ALSpace.space2)
                    .accessibilityIdentifier("signin.connect")

                    Button("What's an API key?") { showingKeyHelp = true }
                        .font(ALFont.subheadline)
                        .foregroundStyle(ALColor.primaryText)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, ALSpace.space3)

                Text("Works with AdventureLog 0.13 or later.")
                    .font(.caption)
                    .foregroundStyle(ALColor.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, ALSpace.space8)
            }
            .padding(.horizontal, ALSpace.space4)
            .padding(.top, 48)
            .padding(.bottom, ALSpace.space6)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ALColor.surface100)
        .alert("API keys", isPresented: $showingKeyHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("An API key lets this app use your AdventureLog account without your password. You can revoke it in AdventureLog at any time, and it is stored only in this phone's keychain.")
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(ALColor.ink)
                .accessibilityHidden(true)
            content()
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(ALColor.surface200, in: RoundedRectangle(cornerRadius: ALRadius.btn, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ALRadius.btn, style: .continuous).strokeBorder(ALColor.hairline))
        }
    }

    /// Starts sign-in when both fields are filled and no connection is pending; displays caught errors.
    private func connect() {
        guard canConnect else { return }
        isConnecting = true
        errorMessage = nil
        focus = nil
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
