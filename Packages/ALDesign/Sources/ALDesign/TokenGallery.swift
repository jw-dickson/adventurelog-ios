// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import SwiftUI

/// A debug screen that renders the generated tokens, for checking Tokens.swift against the
/// design system's previews in both appearances. Reached from the app's debug menu.
public struct TokenGallery: View {
    private let colors: [(String, Color)] = [
        ("surface-100", ALColor.surface100), ("surface-200", ALColor.surface200), ("surface-300", ALColor.surface300),
        ("ink", ALColor.ink), ("ink-muted", ALColor.inkMuted),
        ("primary", ALColor.primary), ("secondary", ALColor.secondary), ("accent", ALColor.accent),
        ("success", ALColor.success), ("warning", ALColor.warning), ("error", ALColor.error),
        ("live-bg", ALColor.liveBg),
    ]

    private let styles: [(String, Font)] = [
        ("large-title", ALFont.largeTitle), ("title-1", ALFont.title1), ("title-2", ALFont.title2),
        ("title-3", ALFont.title3), ("headline", ALFont.headline), ("body", ALFont.body),
        ("callout", ALFont.callout), ("subheadline", ALFont.subheadline), ("footnote", ALFont.footnote),
        ("caption", ALFont.caption), ("reference", ALFont.reference),
    ]

    public init() {}

    public var body: some View {
        List {
            Section("Colour") {
                ForEach(colors, id: \.0) { name, color in
                    HStack(spacing: ALSpace.space3) {
                        RoundedRectangle(cornerRadius: ALRadius.sm)
                            .fill(color)
                            .frame(width: 44, height: 28)
                            .overlay(RoundedRectangle(cornerRadius: ALRadius.sm).stroke(ALColor.hairline))
                        Text(name).font(ALFont.subheadline).foregroundStyle(ALColor.ink)
                    }
                }
            }
            Section("Type") {
                ForEach(styles, id: \.0) { name, font in
                    Text(name).font(font).foregroundStyle(ALColor.ink)
                }
            }
            Section("Text on fills") {
                Text("Accept plan")
                    .font(ALFont.headline)
                    .foregroundStyle(ALColor.onPrimary)
                    .padding(.horizontal, ALSpace.space4)
                    .frame(height: 44)
                    .background(ALColor.primary, in: RoundedRectangle(cornerRadius: ALRadius.btn))
                Text("Booked")
                    .font(ALFont.caption)
                    .foregroundStyle(ALColor.onAccent)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(ALColor.accent, in: Capsule())
            }
        }
        .scrollContentBackground(.hidden)
        .background(ALColor.surface100)
        .navigationTitle("Design tokens")
    }
}

#Preview("Light") {
    NavigationStack { TokenGallery() }
}

#Preview("Dark") {
    NavigationStack { TokenGallery() }.preferredColorScheme(.dark)
}
