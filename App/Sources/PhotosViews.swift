// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI

// Photos to the trip (Stage 6b). The companion finds the trip's raw photos in Immich, writes the
// stop each was taken at into its Lightroom sidecar and links a few to each place. The phone turns
// it on or off for a trip, sets the camera's clock offset, shows what was matched each day, and
// asks for a day to be undone. Nothing here touches a photo itself.

extension AppModel {
    // Each call notes the session and companion it asked; a reply that comes back after
    // sign-out or a new companion address is dropped rather than shown for the wrong account.

    func loadTripPhotos(_ tripID: String) async {
        guard let service = photoService, let key = photoSourceKey else { return }
        do {
            let photos = try await service.photos(tripID: tripID)
            guard photoSourceKey == key else { return }
            tripPhotos[tripID] = photos
            tripPhotosProblem[tripID] = nil
        } catch {
            guard photoSourceKey == key else { return }
            tripPhotosProblem[tripID] = Self.photoProblem(error)
        }
    }

    /// Shown at once, sent after; put back if the companion refuses.
    func setTripPhotos(_ tripID: String, enabled: Bool, cameraOffsetMinutes: Int) async {
        guard let service = photoService, let key = photoSourceKey else { return }
        let before = tripPhotos[tripID]
        var shown = before ?? TripPhotos(enabled: enabled)
        shown.enabled = enabled
        shown.cameraOffsetMinutes = cameraOffsetMinutes
        tripPhotos[tripID] = shown
        do {
            let photos = try await service.setPhotos(tripID: tripID, enabled: enabled, cameraOffsetMinutes: cameraOffsetMinutes)
            guard photoSourceKey == key else { return }
            tripPhotos[tripID] = photos
            tripPhotosProblem[tripID] = nil
        } catch {
            guard photoSourceKey == key else { return }
            tripPhotos[tripID] = before
            tripPhotosProblem[tripID] = Self.photoProblem(error)
        }
    }

    func undoTripPhotos(_ tripID: String, date: CalendarDate) async -> TripPhotos.Undo? {
        guard let service = photoService, let key = photoSourceKey else { return nil }
        do {
            let undo = try await service.undoPhotos(tripID: tripID, date: date)
            guard photoSourceKey == key else { return nil }
            tripPhotos[tripID] = undo.photos
            tripPhotosProblem[tripID] = nil
            return undo
        } catch {
            guard photoSourceKey == key else { return nil }
            tripPhotosProblem[tripID] = Self.photoProblem(error)
            return nil
        }
    }

    static func photoProblem(_ error: any Error) -> String {
        if let api = error as? APIError {
            switch api {
            case .transport: return "Can't reach the companion."
            case .notFound: return "The companion can't see this trip."
            case .server(let status, _) where status == 503: return "Photos aren't set up on the companion."
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// Stands in for a companion with photos set up, for UI tests and the gallery (`AL_SEED_PHOTOS`).
actor SeededTripPhotos: TripPhotosService {
    private let tripID: String
    private var current: TripPhotos

    init(tripID: String, photos: TripPhotos) {
        self.tripID = tripID
        self.current = photos
    }

    func photos(tripID: String) async throws -> TripPhotos {
        guard tripID == self.tripID else { throw APIError.notFound(ServerMessage(summary: "Not found.")) }
        return current
    }

    func setPhotos(tripID: String, enabled: Bool, cameraOffsetMinutes: Int) async throws -> TripPhotos {
        _ = try await photos(tripID: tripID)
        current.enabled = enabled
        current.cameraOffsetMinutes = cameraOffsetMinutes
        return current
    }

    func undoPhotos(tripID: String, date: CalendarDate) async throws -> TripPhotos.Undo {
        _ = try await photos(tripID: tripID)
        guard let index = current.days.firstIndex(where: { $0.date == date }) else {
            return TripPhotos.Undo(restored: 0, kept: 0, photos: current)
        }
        let restored = current.days[index].photos + current.days[index].failed
        current.days[index].undone += restored
        current.days[index].photos = 0
        current.days[index].failed = 0
        current.days[index].stops = []
        return TripPhotos.Undo(restored: restored, kept: 0, photos: current)
    }
}

/// On the Log tab, when the companion has photos set up: the trip's switch and camera offset, and
/// what was matched on each day shown (every day for Trip, the one day for a day).
struct PhotosSection: View {
    let tripID: String
    let plan: TripPlan
    /// Only this day; nil for the whole trip.
    let date: CalendarDate?
    @Environment(AppModel.self) private var model
    @State private var editingOffset = false
    @State private var undoing: TripPhotos.Day?
    @State private var outcome: String?

    var body: some View {
        if model.photoService != nil {
            content
                .task(id: tripID) { await model.loadTripPhotos(tripID) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: ALSpace.space3) { sections }
    }

    @ViewBuilder private var sections: some View {
        let photos = model.tripPhotos[tripID]
        Overline("Photos for Lightroom").padding(.top, ALSpace.space2)
        VStack(alignment: .leading, spacing: ALSpace.space3) {
            Toggle(isOn: Binding(get: { photos?.enabled ?? false },
                                 set: { on in Task { await model.setTripPhotos(tripID, enabled: on, cameraOffsetMinutes: photos?.cameraOffsetMinutes ?? 0) } })) {
                Label("Match my camera's photos", systemImage: "camera")
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.ink)
            }
            .tint(ALColor.primary)
            .disabled(photos == nil)
            .accessibilityIdentifier("photos.enabled")

            if let photos, photos.enabled {
                Button {
                    editingOffset = true
                } label: {
                    HStack {
                        Text("Camera clock")
                            .foregroundStyle(ALColor.ink)
                        Spacer(minLength: ALSpace.space2)
                        Text(TripPhotos.offsetText(photos.cameraOffsetMinutes))
                            .foregroundStyle(ALColor.inkMuted)
                        Image(systemName: "chevron.right")
                            .font(ALFont.footnote)
                            .foregroundStyle(ALColor.inkMuted)
                    }
                    .font(ALFont.subheadline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("photos.offset")
                status(photos)
            } else if photos != nil {
                Text("The companion finds this trip's raw photos in Immich, writes the stop each was taken at into its Lightroom sidecar, and shows a few on each place.")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
            }
            if let problem = model.tripPhotosProblem[tripID] {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.warningText)
                    .accessibilityIdentifier("photos.problem")
            }
            if let outcome {
                Text(outcome)
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
                    .accessibilityIdentifier("photos.outcome")
            }
        }
        .alCard()
        .sheet(isPresented: $editingOffset) {
            CameraOffsetSheet(minutes: photos?.cameraOffsetMinutes ?? 0) { minutes in
                Task { await model.setTripPhotos(tripID, enabled: true, cameraOffsetMinutes: minutes) }
            }
        }
        .confirmationDialog(undoing.map { "Undo the photos for \(title($0.date))?" } ?? "",
                            isPresented: Binding(get: { undoing != nil }, set: { if !$0 { undoing = nil } }),
                            titleVisibility: .visible, presenting: undoing) { day in
            Button("Undo day", role: .destructive) {
                Task {
                    if let undo = await model.undoTripPhotos(tripID, date: day.date) { outcome = Self.text(undo) }
                }
            }
            .accessibilityIdentifier("photos.undo.confirm")
        } message: { _ in
            Text("Their sidecars go back to how they were, and they're taken off the trip's places and album. A photo changed in Lightroom since is left as it is.")
        }

        if let photos {
            let days = shownDays(photos)
            if !days.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        PhotoDayRow(title: title(day.date), day: day, onUndo: { undoing = day })
                        if index < days.count - 1 { Divider().overlay(ALColor.hairline) }
                    }
                }
                .padding(.horizontal, ALSpace.space3)
                .background(ALColor.surface200, in: RoundedRectangle(cornerRadius: ALRadius.box, style: .continuous))
            }
        }
    }

    /// Days with something to show; just the one day when a day is picked.
    private func shownDays(_ photos: TripPhotos) -> [TripPhotos.Day] {
        let days = photos.days.filter { $0.photos > 0 || $0.undone > 0 || $0.failed > 0 }
        if let date { return days.filter { $0.date == date } }
        return days.sorted { $0.date > $1.date }
    }

    @ViewBuilder private func status(_ photos: TripPhotos) -> some View {
        let total = photos.totalPhotos
        let looked = photos.lastRun.flatMap(ISO8601.parse)
        let count = total == 0 ? "No photos matched yet" : (total == 1 ? "1 photo matched" : "\(total) photos matched")
        Group {
            if let looked {
                Text("\(count) · last looked \(looked.formatted(.dateTime.day().month().hour().minute()))")
            } else {
                Text(count + " · the companion looks every few minutes")
            }
        }
        .font(ALFont.footnote)
        .foregroundStyle(ALColor.inkMuted)
        .accessibilityIdentifier("photos.status")
        if let error = photos.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(ALFont.footnote)
                .foregroundStyle(ALColor.warningText)
        }
    }

    private func title(_ date: CalendarDate) -> String {
        plan.day(for: date).map(DayTitle.text) ?? DayText.long(date)
    }

    static func text(_ undo: TripPhotos.Undo) -> String {
        var parts = [undo.restored == 1 ? "1 photo put back" : "\(undo.restored) photos put back"]
        if undo.kept > 0 { parts.append(undo.kept == 1 ? "1 kept: it changed in Lightroom since" : "\(undo.kept) kept: they changed in Lightroom since") }
        return parts.joined(separator: " · ")
    }
}

private struct PhotoDayRow: View {
    let title: String
    let day: TripPhotos.Day
    let onUndo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ALSpace.space2) {
            Text(title)
                .font(ALFont.headline)
                .foregroundStyle(ALColor.ink)
            Text(day.countText)
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
            if !day.stopsText.isEmpty {
                Text(day.stopsText)
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
            }
            if day.canUndo {
                Button("Undo", action: onUndo)
                    .buttonStyle(ALButtonStyle(.plain, small: true))
                    .accessibilityIdentifier("photos.undo.\(day.date)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ALSpace.space3)
    }
}

/// How far off the camera's clock was, beyond the home zone the companion reads it in.
private struct CameraOffsetSheet: View {
    @State var minutes: Int
    let onSave: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $minutes, in: TripPhotos.offsetRange) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Camera clock")
                            Text(TripPhotos.offsetText(minutes))
                                .font(ALFont.subheadline)
                                .foregroundStyle(ALColor.inkMuted)
                                .accessibilityIdentifier("photos.offset.value")
                        }
                    }
                    .accessibilityIdentifier("photos.offset.stepper")
                } footer: {
                    Text("Keep the camera on home time while travelling; the companion reads it that way. If its clock drifted, say by how much. This applies to photos not matched yet. To redo a day, undo it here, then turn photos off and on again.")
                }
                .listRowBackground(ALColor.surface200)
                if minutes != 0 {
                    Button("Set to on time") { minutes = 0 }
                        .listRowBackground(ALColor.surface200)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ALColor.surface100)
            .navigationTitle("Camera clock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(minutes)
                        dismiss()
                    }
                    .accessibilityIdentifier("photos.offset.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
