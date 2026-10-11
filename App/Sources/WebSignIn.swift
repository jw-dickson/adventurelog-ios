// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI
import WebKit

/// Signs in through one of the server's providers (Authentik or another OpenID Connect provider,
/// GitHub) in a web view: the same pages as the AdventureLog web app, including the provider's own
/// two-factor steps.
///
/// It runs in an in-app web view rather than Safari because the app needs the session the server
/// sets at the end, and Safari's cookies are out of its reach. The web view keeps nothing: its
/// cookies live only in memory and go with the sheet.
/// Where a web sign-in starts and which server's session it is waiting for.
struct WebSignInTarget: Identifiable, Hashable {
    let title: String
    let start: URL
    let server: URL
    var id: String { start.absoluteString }
}

struct WebSignInSheet: View {
    let target: WebSignInTarget
    let onSignedIn: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            WebSignInView(start: target.start, server: target.server, isLoading: $isLoading) { token in
                dismiss()
                onSignedIn(token)
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if isLoading { ProgressView().controlSize(.large) }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .accessibilityIdentifier("signin.web")
    }
}

/// The web view. After every page it looks for AdventureLog's session cookie and asks the server
/// whether that session is signed in; the first one that is ends the sign-in. (The cookie appears
/// as soon as the provider sign-in starts, before the person has signed in, and changes when they do.)
private struct WebSignInView: UIViewRepresentable {
    let start: URL
    let server: URL
    @Binding var isLoading: Bool
    let onSignedIn: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: start))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebSignInView
        private var checked = Set<String>()
        private var finished = false

        init(_ parent: WebSignInView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            lookForSession(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            lookForSession(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            parent.isLoading = false
            lookForSession(in: webView)
        }

        // The last redirect goes to the web app's address, which may not answer from this phone;
        // by then the session already exists.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            parent.isLoading = false
            lookForSession(in: webView)
        }

        private func lookForSession(in webView: WKWebView) {
            let host = parent.server.host()?.lowercased() ?? ""
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                // Only AdventureLog's own session cookie: one a browser would send to the server
                // anyway, never a provider's cookie that happens to share the name.
                let tokens = cookies.filter { $0.name == "sessionid" && Self.domain($0.domain, matches: host) }.map(\.value)
                guard let self else { return }
                Task { @MainActor in await self.check(tokens) }
            }
        }

        /// RFC 6265 domain matching. AdventureLog sets its cookie on the parent domain
        /// (`.example.com` for `trips.example.com`), so an exact host match would miss it.
        nonisolated static func domain(_ cookieDomain: String, matches host: String) -> Bool {
            let domain = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty, !host.isEmpty else { return false }
            return host == domain || host.hasSuffix("." + domain)
        }

        private func check(_ tokens: [String]) async {
            let account = AccountClient(baseURL: parent.server)
            for token in tokens where !finished && !checked.contains(token) {
                checked.insert(token)
                if await account.isSignedIn(sessionToken: token), !finished {
                    finished = true
                    parent.onSignedIn(token)
                    return
                }
            }
        }
    }
}
