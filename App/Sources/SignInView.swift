// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI

/// Sign in to an AdventureLog server the way its web app does: a username and password (with a
/// two-factor code when that's on), or single sign-on in a web sheet: a provider the server lists,
/// such as Authentik, or the server's own pages when a sign-on proxy sits in front of it.
///
/// Either way the app ends up holding an API key it made for this phone (see
/// `AppModel.signIn(url:sessionToken:)`); there is no field for pasting one.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var server = LaunchOptions.current.serverURL ?? ""
    @State private var login = ""
    @State private var password = ""
    @State private var code = ""
    /// A password sign-in waiting for its two-factor code.
    @State private var pendingToken: String?
    @State private var providers: [SocialProvider] = []
    /// A sign-on proxy answers for the server, so only the web sheet can sign in (issue #9).
    @State private var behindSignOn = false
    @State private var web: WebSignInTarget?
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case server, login, password, code }

    private var serverURL: URL? { AdventureLogClient.normalizedServerURL(server) }
    /// Only single sign-on works: the server requires a provider, or a proxy is in front of it.
    private var signOnOnly: Bool { behindSignOn || providers.contains { $0.usageRequired == true } }

    private var canConnect: Bool {
        guard !server.trimmingCharacters(in: .whitespaces).isEmpty, !isConnecting else { return false }
        if pendingToken != nil { return !code.trimmingCharacters(in: .whitespaces).isEmpty }
        return !login.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !signOnOnly
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
                            .onSubmit { focus = signOnOnly ? nil : .login }
                            .accessibilityIdentifier("signin.server")
                    }

                    passwordFields

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(ALFont.callout)
                            .foregroundStyle(ALColor.errorText)
                            .accessibilityIdentifier("signin.error")
                    }

                    if !signOnOnly {
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

                    if pendingToken == nil {
                        signOnButtons
                    }
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
        .task { await signInWithTestKey() }
        .sheet(item: $web) { target in
            WebSignInSheet(target: target) { token in
                finish(url: target.server, sessionToken: token)
            }
        }
    }

    private var connectTitle: String { pendingToken == nil ? "Sign in" : "Verify" }

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
        } else if signOnOnly {
            Text(providers.isEmpty
                 ? "This server signs in through single sign-on."
                 : "This server signs in through \(ListFormatter.localizedString(byJoining: providers.map(\.name))).")
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
                .accessibilityIdentifier("signin.signOnOnly")
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

    /// A button per provider the server lists. When it lists none (or a sign-on proxy hides the
    /// list), one button opens the server's own pages, where its sign-on takes over like in a browser.
    private var signOnButtons: some View {
        VStack(spacing: ALSpace.space2) {
            if !signOnOnly {
                HStack {
                    Rectangle().fill(ALColor.hairline).frame(height: 1)
                    Text("or").font(ALFont.footnote).foregroundStyle(ALColor.inkMuted)
                    Rectangle().fill(ALColor.hairline).frame(height: 1)
                }
                .accessibilityHidden(true)
            }
            if providers.isEmpty {
                Button {
                    guard let url = serverURL else { return }
                    errorMessage = nil
                    web = WebSignInTarget(title: "Single sign-on", start: url, server: url)
                } label: {
                    Label("Sign in with single sign-on", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ALButtonStyle(signOnOnly ? .primary : .secondary))
                .disabled(isConnecting || serverURL == nil)
                .accessibilityIdentifier("signin.sso")
            }
            ForEach(providers) { provider in
                Button {
                    guard let url = serverURL else { return }
                    errorMessage = nil
                    web = WebSignInTarget(title: provider.name, start: provider.startURL(on: url), server: url)
                } label: {
                    Label("Continue with \(provider.name)", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ALButtonStyle(signOnOnly ? .primary : .secondary))
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
    /// A sign-on proxy's login page or any other failure means "none listed", never an error:
    /// the single sign-on button is there either way.
    private func loadProviders() async {
        providers = []
        behindSignOn = false
        pendingToken = nil
        guard let url = serverURL else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        var found: [SocialProvider] = []
        var proxied = false
        do {
            found = try await AccountClient(baseURL: url).socialProviders()
        } catch AccountError.singleSignOn {
            proxied = true
        } catch {}
        guard !Task.isCancelled else { return }
        withAnimation {
            providers = found
            behindSignOn = proxied
        }
    }

    /// Test seam: `-ALServerURL` with `-ALAPIKey` signs straight in with that key (UI tests against
    /// a disposable server). There is no way to paste a key in the app itself.
    private func signInWithTestKey() async {
        guard let key = LaunchOptions.current.apiKey, let server = LaunchOptions.current.serverURL else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await model.signIn(server: server, apiKey: key)
        } catch {
            errorMessage = error.localizedDescription
        }
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
            } catch AccountError.singleSignOn {
                withAnimation { behindSignOn = true }
                errorMessage = AccountError.singleSignOn.localizedDescription
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
