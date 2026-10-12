// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI

/// Replan today (Design/review-1, 08): how far behind you are, a revised rest-of-today, and
/// Apply changes / Not now. Booked items are listed first and never move.
struct ReplanSheet: View {
    let tripID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// How late the person says they are, when the phone isn't recording.
    @State private var reported: Int?
    /// Claude's proposal from the last ask (Stage 5b), shown instead of the phone's while it passes the check.
    @State private var claude: Replan.Proposal?
    @State private var askText = ""
    @State private var asking = false
    @State private var askProblem: String?

    static let lateChoices = [15, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            Group {
                if let situation = model.replanSituation(tripID: tripID, reportedDelay: reported) {
                    content(situation)
                } else {
                    ContentUnavailableView("Nothing left to replan", systemImage: "checkmark.circle",
                                           description: Text("There's nothing timed left today."))
                        .accessibilityIdentifier("replan.empty")
                }
            }
            .background(ALColor.surface100)
            .navigationTitle("Replan today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("replan.close")
                }
            }
        }
        .onChange(of: reported) { claude = nil }
        .accessibilityIdentifier("replan.sheet")
    }

    @ViewBuilder
    private func content(_ situation: Replan.Situation) -> some View {
        let phone = ReplanPlanner.propose(situation)
        let tripDays = model.tripDays(tripID)
        // Claude's plan, while it still passes against the latest situation.
        let fromClaude = claude.flatMap { ReplanCheck.problems($0, situation: situation, tripDays: tripDays).isEmpty ? $0 : nil }
        let proposal = fromClaude ?? phone
        let problems = ReplanCheck.problems(proposal, situation: situation, tripDays: tripDays)
        ScrollView {
            VStack(alignment: .leading, spacing: ALSpace.space4) {
                Text(proposal.headline)
                    .font(ALFont.title1)
                    .foregroundStyle(ALColor.ink)
                    .accessibilityIdentifier("replan.headline")
                if situation.position == nil {
                    lateness
                } else {
                    Label("From where you are now", systemImage: "location.fill")
                        .font(ALFont.footnote)
                        .foregroundStyle(ALColor.inkMuted)
                }
                if fromClaude != nil {
                    HStack {
                        Label("Suggested by Claude", systemImage: "sparkles")
                            .font(ALFont.footnote)
                            .foregroundStyle(ALColor.secondaryText)
                        Spacer()
                        Button("Use the phone's plan") { claude = nil }
                            .buttonStyle(ALButtonStyle(.plain, small: true))
                            .accessibilityIdentifier("replan.usePhone")
                    }
                }
                if !proposal.summary.isEmpty {
                    Text(proposal.summary)
                        .font(ALFont.body)
                        .foregroundStyle(ALColor.inkMuted)
                        .accessibilityIdentifier("replan.summary")
                }
                if let problem = problems.first {
                    Label(problem.message, systemImage: "exclamationmark.triangle")
                        .font(ALFont.footnote)
                        .foregroundStyle(ALColor.errorText)
                }
                let lines = ReplanText.lines(proposal, situation: situation)
                if !lines.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(lines) { line in
                            ReplanLineRow(line: line)
                            if line.id != lines.last?.id { Divider().overlay(ALColor.hairline) }
                        }
                    }
                    .overlay(alignment: .top) { Divider().overlay(ALColor.hairline) }
                }
                HStack(spacing: ALSpace.space3) {
                    Button("Apply changes") {
                        model.applyReplan(proposal, tripID: tripID)
                        dismiss()
                    }
                    .buttonStyle(ALButtonStyle(.primary))
                    .frame(maxWidth: .infinity)
                    .disabled(!proposal.changesSomething || !problems.isEmpty)
                    .accessibilityIdentifier("replan.apply")
                    Button("Not now") { dismiss() }
                        .buttonStyle(ALButtonStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("replan.notNow")
                }
                .padding(.top, ALSpace.space2)
                Text("Applying saves the new times on this phone and sends them when it's online. Skipped places stay in the trip.")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
                if model.companionCanReplan {
                    askBox(situation: situation, current: phone)
                        .padding(.top, ALSpace.space4)
                }
            }
            .padding(ALSpace.space4)
        }
    }

    /// "Ask for a different plan…": through the companion to Claude (Stage 5b).
    private func askBox(situation: Replan.Situation, current: Replan.Proposal) -> some View {
        VStack(alignment: .leading, spacing: ALSpace.space2) {
            HStack(spacing: ALSpace.space2) {
                Image(systemName: "wand.and.stars").foregroundStyle(ALColor.inkMuted)
                TextField("Ask for a different plan…", text: $askText, axis: .vertical)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit { send(situation: situation, current: current) }
                    .disabled(asking)
                    .accessibilityIdentifier("replan.ask")
                if asking {
                    ProgressView()
                } else if !askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Send", systemImage: "arrow.up.circle.fill") { send(situation: situation, current: current) }
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .accessibilityIdentifier("replan.ask.send")
                }
            }
            .padding(.horizontal, ALSpace.space4)
            .padding(.vertical, ALSpace.space3)
            .background(ALColor.surface200, in: Capsule())
            if let askProblem {
                Label(askProblem, systemImage: "exclamationmark.triangle")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.errorText)
            }
            Text("Sends the rest of today's plan and your words to Claude through your companion.")
                .font(ALFont.caption)
                .foregroundStyle(ALColor.inkMuted)
        }
    }

    private func send(situation: Replan.Situation, current: Replan.Proposal) {
        let text = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        asking = true
        askProblem = nil
        Task {
            defer { asking = false }
            do {
                let proposal = try await model.askReplan(text, situation: situation, current: current, tripID: tripID)
                if let problem = ReplanCheck.problems(proposal, situation: situation, tripDays: model.tripDays(tripID)).first {
                    askProblem = "Claude's plan didn't fit: " + problem.message
                } else {
                    claude = proposal
                    askText = ""
                }
            } catch {
                askProblem = AppModel.describe(error)
            }
        }
    }

    /// Not recording, so the phone can't tell: the person says how late they are.
    private var lateness: some View {
        VStack(alignment: .leading, spacing: ALSpace.space2) {
            Text("How late are you?")
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ALSpace.space2) {
                    ForEach(Self.lateChoices, id: \.self) { minutes in
                        let selected = reported == minutes
                        Button(ItemSummary.durationText(minutes: minutes)) { reported = minutes }
                            .buttonStyle(ALButtonStyle(selected ? .primary : .secondary, small: true))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("replan.late.\(minutes)")
                    }
                }
            }
        }
    }
}

/// One line of a proposal: a mark, the item, and what happens to it.
private struct ReplanLineRow: View {
    let line: ReplanText.Line

    var body: some View {
        HStack(alignment: .top, spacing: ALSpace.space3) {
            mark
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(ALFont.headline)
                    .foregroundStyle(ALColor.ink)
                Text(line.detail)
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, ALSpace.space3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("replan.line.\(line.title)")
    }

    @ViewBuilder
    private var mark: some View {
        switch line.mark {
        case .locked:
            Image(systemName: "lock.fill")
                .imageScale(.small)
                .foregroundStyle(ALColor.onAccent)
                .frame(width: 28, height: 28)
                .background(ALColor.accent, in: Circle())
                .accessibilityLabel("Booked")
        case .moved:
            Image(systemName: "arrow.right").foregroundStyle(ALColor.secondaryText).accessibilityLabel("Moved")
        case .shortened:
            Image(systemName: "minus").foregroundStyle(ALColor.warningText).accessibilityLabel("Shorter")
        case .left:
            Image(systemName: "forward").foregroundStyle(ALColor.inkMuted).accessibilityLabel("Left out")
        case .added:
            Image(systemName: "plus").foregroundStyle(ALColor.successText).accessibilityLabel("New")
        }
    }
}

/// On Today while recording, when you're 30 minutes or more behind.
struct ReplanNudge: View {
    let tripID: String
    let open: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if let behind = model.replanNudge(tripID: tripID) {
            Button(action: open) {
                HStack(spacing: ALSpace.space3) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(ALColor.warningText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You're \(ItemSummary.durationText(minutes: behind)) behind")
                            .font(ALFont.headline)
                            .foregroundStyle(ALColor.ink)
                        Text("Replan the rest of today")
                            .font(ALFont.subheadline)
                            .foregroundStyle(ALColor.inkMuted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(ALColor.inkMuted)
                }
                .alCard(padding: ALSpace.space4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today.replanNudge")
        }
    }
}
