// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI

/// Sign in to an AdventureLog server the way its web app does: a username and password (with a
/// two-factor code when that's on), or any provider the server offers, such as Authentik. An
/// API key still works, under "Use an API key instead".
///
/// Either way the app ends up holding an API key for this phone (see `AppModel.signIn(url:sessionToken:)`).
struct SignInView: View {
    enum Mode { case password, apiKey }

    @Environment(AppModel.self) private var model
    @State private var server = LaunchOptions.current.serverURL ?? ""
    @State private var mode: Mode = LaunchOptions.current.apiKey == nil ? .password : .apiKey
    @State private var login = ""
    @State private var password = ""
    @State private var apiKey = LaunchOptions.current.apiKey ?? ""
    @State private var code = ""
    /// A password sign-in waiting for its two-factor code.
    @State private var pendingToken: String?
    @State private var providers: [SocialProvider] = []
    @State private var webProvider: SocialProvider?
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showingKeyHelp = false
    @FocusState private var focus: Field?

    private enum Field { case server, login, password, code, key }

    private var serverURL: URL? { AdventureLogClient.normalizedServerURL(server) }
    /// The server only allows provider sign-in.
    private var providersOnly: Bool { providers.contains { $0.usageRequired == true } }

    private var canConnect: Bool {
        guard !server.trimmingCharacters(in: .whitespaces).isEmpty, !isConnecting else { return false }
        switch mode {
        case .apiKey:
            return !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .password:
            if pendingToken != nil { return !code.trimmingCharacters(in: .whitespaces).isEmpty }
            return !login.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !providersOnly
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ALSpace.space4) {
                Image("AdventureLogMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Sign in to your AdventureLog")
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
                            .onSubmit { focus = mode == .apiKey ? .key : .login }
                            .accessibilityIdentifier("signin.server")
                    }

                    switch mode {
                    case .password: passwordFields
                    case .apiKey: keyField
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(ALFont.callout)
                            .foregroundStyle(ALColor.errorText)
                            .accessibilityIdentifier("signin.error")
                    }

                    if mode == .apiKey || !providersOnly {
                        Button(action: connect) {
                            ZStack {
                                Text(connectTitle).opacity(isConnecting ? 0 : 1)
                                if isConnecting { ProgressView().tint(ALColor.onPrimary) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ALButtonStyle(.primary))
                        .opacity(canConnect || isConnecting ? 1 : 0.45)
                        .disabled(!canConnect)
                        .padding(.top, ALSpace.space2)
                        .accessibilityIdentifier("signin.connect")
                    }

                    if mode == .password, !providers.isEmpty, pendingToken == nil {
                        providerButtons
                    }

                    Button(mode == .password ? "Use an API key instead" : "Sign in with your account instead") {
                        withAnimation {
                            mode = mode == .password ? .apiKey : .password
                            errorMessage = nil
                            pendingToken = nil
                        }
                    }
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.primaryText)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(mode == .password ? "signin.useKey" : "signin.usePassword")
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
        .task(id: serverURL) { await loadProviders() }
        .sheet(item: $webProvider) { provider in
            if let url = serverURL {
                WebSignInSheet(provider: provider, server: url) { token in
                    finish(url: url, sessionToken: token)
                }
            }
        }
        .alert("API keys", isPresented: $showingKeyHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("An API key lets this app use your AdventureLog account without your password. You can revoke it in AdventureLog at any time, and it is stored only in this phone's keychain.")
        }
    }

    private var connectTitle: String {
        switch mode {
        case .apiKey: return "Connect"
        case .password: return pendingToken == nil ? "Sign in" : "Verify"
        }
    }

    @ViewBuilder private var passwordFields: some View {
        if pendingToken != nil {
            VStack(alignment: .leading, spacing: 6) {
                field("Two-factor code") {
                    TextField("Two-factor code", text: $code, prompt: Text("123456"))
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .textContentType(.oneTimeCode)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focus, equals: .code)
                        .onSubmit { connect() }
                        .accessibilityIdentifier("signin.code")
                }
                Text("Enter the code from your authenticator app, or one of your recovery codes.")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
            }
        } else if providersOnly {
            Text("This server signs in through \(ListFormatter.localizedString(byJoining: providers.map(\.name))).")
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
        } else {
            field("Username or email") {
                TextField("Username or email", text: $login, prompt: Text("Username or email"))
                    .font(ALFont.body)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .login)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier("signin.username")
            }
            field("Password") {
                SecureField("Password", text: $password, prompt: Text("Password"))
                    .font(ALFont.body)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit { connect() }
                    .accessibilityIdentifier("signin.password")
            }
        }
    }

    @ViewBuilder private var keyField: some View {
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
            HStack(alignment: .firstTextBaseline) {
                Text("Create a key in AdventureLog under Settings › API keys, then paste it here.")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
                Spacer(minLength: 0)
                Button("What's this?") { showingKeyHelp = true }
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.primaryText)
            }
        }
    }

    private var providerButtons: some View {
        VStack(spacing: ALSpace.space2) {
            if !providersOnly {
                HStack {
                    Rectangle().fill(ALColor.hairline).frame(height: 1)
                    Text("or").font(ALFont.footnote).foregroundStyle(ALColor.inkMuted)
                    Rectangle().fill(ALColor.hairline).frame(height: 1)
                }
                .accessibilityHidden(true)
            }
            ForEach(providers) { provider in
                Button {
                    errorMessage = nil
                    webProvider = provider
                } label: {
                    Label("Continue with \(provider.name)", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ALButtonStyle(providersOnly ? .primary : .secondary))
                .disabled(isConnecting || serverURL == nil)
                .accessibilityIdentifier("signin.provider.\(provider.name)")
            }
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

    // MARK: Actions

    /// Asks the server which providers it offers, a moment after the address stops changing.
    private func loadProviders() async {
        providers = []
        pendingToken = nil
        guard let url = serverURL else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        let found = (try? await AccountClient(baseURL: url).socialProviders()) ?? []
        guard !Task.isCancelled else { return }
        withAnimation { providers = found }
    }

    /// Signs in with what's filled in; shows the server's message when it says no.
    private func connect() {
        guard canConnect else { return }
        isConnecting = true
        errorMessage = nil
        focus = nil
        Task {
            defer { isConnecting = false }
            do {
                switch mode {
                case .apiKey:
                    try await model.signIn(server: server, apiKey: apiKey)
                case .password:
                    guard let url = serverURL else { throw APIError.badServerURL }
                    let account = AccountClient(baseURL: url)
                    if let token = pendingToken {
                        let signedIn = try await account.submitCode(code, sessionToken: token)
                        try await model.signIn(url: url, sessionToken: signedIn)
                    } else {
                        let method = (try? await account.config())?.authenticationMethod ?? "username_email"
                        switch try await account.logIn(login, password: password, method: method) {
                        case .signedIn(let token):
                            try await model.signIn(url: url, sessionToken: token)
                        case .needsCode(let token):
                            withAnimation { pendingToken = token }
                            code = ""
                            focus = .code
                        }
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// After a provider sign-in in the web sheet.
    private func finish(url: URL, sessionToken: String) {
        isConnecting = true
        errorMessage = nil
        Task {
            defer { isConnecting = false }
            do {
                try await model.signIn(url: url, sessionToken: sessionToken)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    SignInView().environment(AppModel.forLaunch(LaunchOptions(resetState: true)))
}
