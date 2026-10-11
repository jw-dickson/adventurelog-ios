// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

private let d1 = CalendarDate("2027-03-07")!
private let d2 = CalendarDate("2027-03-08")!

@Suite("Itinerary layout")
struct ItineraryLayoutTests {
    @Test func reorderingWithinADayRenumbersFromZero() throws {
        let trip = try Fixture.trip()
        let rows = ItineraryLayout.group(d2, in: trip.itinerary)
        let cruise = try #require(rows.last)
        let moved = try #require(ItineraryLayout.move(cruise.id, to: d2, at: 0, in: trip.itinerary))
        let after = ItineraryLayout.group(d2, in: moved.rows)
        #expect(after.map(\.id) == [cruise.id] + rows.dropLast().map(\.id))
        #expect(after.map(\.order) == Array(0..<rows.count))
        #expect(moved.rows.count == trip.itinerary.count)
        // Only rows whose order changed go in the request.
        #expect(Set(moved.changed.map(\.id)) == Set(after.map(\.id)))
    }

    @Test func movingToAnotherDayClosesTheGapAndClampsThePosition() throws {
        let trip = try Fixture.trip()
        let lookout = try #require(ItineraryLayout.group(d2, in: trip.itinerary).first { $0.kind == .location })
        let moved = try #require(ItineraryLayout.move(lookout.id, to: d1, at: 99, in: trip.itinerary))
        let day1 = ItineraryLayout.group(d1, in: moved.rows)
        let day2 = ItineraryLayout.group(d2, in: moved.rows)
        #expect(day1.last?.id == lookout.id)
        #expect(day1.last?.date == d1)
        #expect(day1.map(\.order) == Array(0..<day1.count))
        #expect(day2.map(\.order) == Array(0..<day2.count))
        #expect(!day2.contains { $0.id == lookout.id })
    }

    @Test func tripWideMovesSendANullDate() throws {
        let trip = try Fixture.trip()
        let note = try #require(ItineraryLayout.group(d1, in: trip.itinerary).first { $0.kind == .note })
        let moved = try #require(ItineraryLayout.move(note.id, to: nil, at: 0, in: trip.itinerary))
        let request = try #require(ItineraryLayout.request(for: moved))
        let entry = try #require(request.items.first { $0.id == note.id })
        #expect(entry.isGlobal && entry.date == nil && entry.order == 0)
        let json = String(decoding: try ALCoding.encoder().encode(request), as: UTF8.self)
        #expect(json.contains("\"date\":null"))
        #expect(json.contains("\"is_global\":true"))
    }

    @Test func movingARowToWhereItIsChangesNothing() throws {
        let trip = try Fixture.trip()
        let first = try #require(ItineraryLayout.group(d1, in: trip.itinerary).first)
        let moved = try #require(ItineraryLayout.move(first.id, to: d1, at: 0, in: trip.itinerary))
        #expect(ItineraryLayout.request(for: moved) == nil)
        #expect(ItineraryLayout.move("not-a-row", to: d1, at: 0, in: trip.itinerary) == nil)
    }
}

@Suite("Edits shown before they sync")
struct TripEditTests {
    @Test func aTickFindsItsItemAfterTheIdsChange() throws {
        var trip = try Fixture.trip()
        let list = try #require(trip.checklists.first { $0.name == "Car pickup" })
        let spare = try #require(list.items.first { $0.name == "Check the spare tyre" })
        let edit = try #require(TripEdit.CheckItem(checklist: list, itemID: spare.id, isChecked: true))
        // Another phone saved the list: every item has a new id.
        let index = try #require(trip.checklists.firstIndex { $0.id == list.id })
        for i in trip.checklists[index].items.indices { trip.checklists[index].items[i].id = UUID().uuidString }
        TripEdit.checkItem(edit).apply(to: &trip)
        #expect(trip.checklists[index].items.first { $0.name == "Check the spare tyre" }?.isChecked == true)
    }

    @Test func duplicateNamesAreTellApartByOccurrence() {
        let items = [
            ChecklistItem(id: "a", name: "Water", isChecked: false, checklist: "l"),
            ChecklistItem(id: "b", name: "Snacks", isChecked: false, checklist: "l"),
            ChecklistItem(id: "c", name: "Water", isChecked: false, checklist: "l"),
        ]
        let list = Checklist(id: "l", user: nil, name: "Day pack", date: nil, isPublic: nil, collection: nil, items: items, createdAt: nil, updatedAt: nil)
        let edit = TripEdit.CheckItem(checklist: list, itemID: "c", isChecked: true)
        #expect(edit?.occurrence == 1)
        let renamed = items.map { ChecklistItem(id: $0.id + "2", name: $0.name, isChecked: $0.isChecked, checklist: "l") }
        #expect(edit?.index(in: renamed) == 2)
        #expect(edit?.index(in: Array(renamed.prefix(2))) == nil, "the second Water was removed")
    }

    @Test func noteAndMoveEditsShowOnTheTrip() throws {
        let trip = try Fixture.trip()
        let note = try #require(trip.notes.first { $0.name == "Hobart day tips" })
        let cruise = try #require(ItineraryLayout.group(d2, in: trip.itinerary).last)
        let shown = trip.applying([
            .editNote(.init(noteID: note.id, noteName: note.name, baseContent: note.content ?? "", content: "Ferry at 9.")),
            .moveRow(.init(rowID: cruise.id, title: "Sunset cruise", toDate: d2, toIndex: 0)),
        ])
        #expect(shown.notes.first { $0.id == note.id }?.content == "Ferry at 9.")
        #expect(ItineraryLayout.group(d2, in: shown.itinerary).first?.id == cruise.id)
        // The saved copy itself is untouched.
        #expect(trip.notes.first { $0.id == note.id }?.content == note.content)
    }
}

@Suite("Writes")
struct WriteRequestTests {
    let client = AdventureLogClient(baseURL: URL(string: "https://adventurelog.example")!, apiKey: "al_test")

    @Test func checklistPatchesAlwaysCarryEveryItemAndTheCollection() throws {
        let list = try Fixture.trip().checklists.first { $0.name == "Car pickup" }
        let patch = ChecklistPatch(try #require(list), collection: "trip-1")
        let object = try #require(try JSONSerialization.jsonObject(with: ALCoding.encoder().encode(patch)) as? [String: Any])
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items.count == 5)
        #expect(items.allSatisfy { $0.keys.sorted() == ["is_checked", "name"] }, "ids are dropped by the server anyway")
        #expect(object["collection"] as? String == list?.collection ?? "trip-1")
        #expect(object["name"] as? String == "Car pickup")
    }

    @Test func notePatchesCarryTheCollection() throws {
        let json = String(decoding: try ALCoding.encoder().encode(NotePatch(collection: "trip-1", content: "Hi")), as: UTF8.self)
        #expect(json == #"{"collection":"trip-1","content":"Hi"}"#)
    }

    @Test func writePaths() {
        #expect(client.makeRequest("PATCH", "api/checklists/abc/").url?.path() == "/api/checklists/abc/")
        #expect(client.makeRequest("PATCH", "api/notes/abc/").httpMethod == "PATCH")
    }
}

@Suite("Sending edits")
struct EditSenderTests {
    @Test func aTickIsReplayedOntoTheServersCurrentList() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try await server.collection(id: Fixture.trip().id))
        phone.make(try phone.tick("Check the spare tyre", on: "Car pickup"))

        // Meanwhile the list is saved on the web: new ids, and one more item.
        await server.mutate { trip in
            let index = trip.checklists.firstIndex { $0.name == "Car pickup" }!
            trip.checklists[index].items = trip.checklists[index].items.map {
                ChecklistItem(id: UUID().uuidString, name: $0.name, isChecked: $0.isChecked, checklist: $0.checklist)
            } + [ChecklistItem(id: "new", name: "Top up washer fluid", isChecked: false, checklist: nil)]
        }
        await phone.drain(to: server)

        #expect(phone.outbox.isEmpty)
        let list = try #require(await server.trip.checklists.first { $0.name == "Car pickup" })
        #expect(list.items.count == 6, "the web's new item survives")
        #expect(list.items.first { $0.name == "Check the spare tyre" }?.isChecked == true)
        #expect(list.items.first { $0.name == "Top up washer fluid" }?.isChecked == false)
        #expect(list.items.filter(\.isChecked).count == 4)
    }

    @Test func aTickThatAlreadyMatchesSendsNothing() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        phone.make(try phone.tick("Driver licences + IDP", on: "Car pickup", true)) // already ticked
        await phone.drain(to: server)
        #expect(phone.outbox.isEmpty)
        #expect(await server.writes == 0)
    }

    @Test func aTickOnARemovedItemIsDroppedWithANotice() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        phone.make(try phone.tick("Check the spare tyre", on: "Car pickup"))
        await server.mutate { trip in
            let index = trip.checklists.firstIndex { $0.name == "Car pickup" }!
            trip.checklists[index].items.removeAll { $0.name == "Check the spare tyre" }
        }
        await phone.drain(to: server)
        #expect(phone.outbox.entries.isEmpty)
        #expect(phone.outbox.notices.first?.message.contains("Check the spare tyre") == true)
    }

    @Test func aNoteEditSavesWhenNobodyElseChangedIt() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        phone.make(try phone.noteEdit("Hobart day tips", to: "Ferry leaves at 9."))
        await phone.drain(to: server)
        #expect(await server.trip.notes.first { $0.name == "Hobart day tips" }?.content == "Ferry leaves at 9.")
        #expect(phone.outbox.isEmpty)
    }

    @Test func aNoteChangedOnBothSidesIsAConflictUntilThePersonChooses() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        phone.make(try phone.noteEdit("Hobart day tips", to: "Mine."))
        await server.mutate { trip in
            let index = trip.notes.firstIndex { $0.name == "Hobart day tips" }!
            trip.notes[index].content = "Theirs."
        }
        await phone.drain(to: server)

        let entry = try #require(phone.outbox.entries.first)
        #expect(entry.state == .conflict(NoteConflict(serverContent: "Theirs.", serverUpdatedAt: entry.conflict?.serverUpdatedAt)))
        // Until then the phone shows its own version, and the server keeps theirs.
        #expect(phone.shown.notes.first { $0.name == "Hobart day tips" }?.content == "Mine.")
        #expect(await server.trip.notes.first { $0.name == "Hobart day tips" }?.content == "Theirs.")

        phone.outbox.keepMine(entry.id)
        await phone.drain(to: server)
        #expect(await server.trip.notes.first { $0.name == "Hobart day tips" }?.content == "Mine.")
        #expect(phone.outbox.isEmpty)
    }

    @Test func keepingTheirsDiscardsTheEdit() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        phone.make(try phone.noteEdit("Hobart day tips", to: "Mine."))
        await server.mutate { trip in trip.notes[trip.notes.firstIndex { $0.name == "Hobart day tips" }!].content = "Theirs." }
        await phone.drain(to: server)
        phone.outbox.discard(try #require(phone.outbox.entries.first).id)
        try await phone.refresh(from: server)
        #expect(phone.shown.notes.first { $0.name == "Hobart day tips" }?.content == "Theirs.")
    }

    @Test func aMoveIsReplayedOntoTheServersCurrentDay() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        phone.make(try phone.move("Sunset cruise", to: d2, at: 0))
        #expect(phone.titles(on: d2).first == "Sunset cruise")

        // Meanwhile someone moves the D1 note onto D2, at the top.
        let noteRow = try phone.row("Hobart day tips")
        await server.mutate { trip in
            trip.itinerary = ItineraryLayout.move(noteRow.id, to: d2, at: 0, in: trip.itinerary)!.rows
        }
        await phone.drain(to: server)
        try await phone.refresh(from: server)

        #expect(phone.outbox.isEmpty)
        #expect(phone.titles(on: d2).prefix(2) == ["Sunset cruise", "Hobart day tips"])
        #expect(ItineraryLayout.group(d2, in: phone.saved.itinerary).map(\.order) == Array(0..<7))
    }

    @Test func aMoveToADayThatLeftTheTripIsDropped() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        phone.make(try phone.move("Sunset cruise", to: CalendarDate("2027-03-20")!, at: 0))
        await server.mutate { trip in trip.endDate = CalendarDate("2027-03-12") }
        await phone.drain(to: server)
        #expect(phone.outbox.entries.isEmpty)
        #expect(phone.outbox.notices.count == 1)
        #expect(await server.writes == 0)
    }

    @Test func offlineEditsWaitAndThenGoInOrder() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        await server.setOffline(true)
        var phone = FakeDevice(try Fixture.trip())
        phone.make(try phone.tick("Check the spare tyre", on: "Car pickup"))
        phone.make(try phone.noteEdit("Trip essentials", to: "Passports."))
        await phone.drain(to: server)
        #expect(phone.outbox.waitingCount == 2)
        #expect(phone.outbox.entries[0].attempts == 1)
        #expect(phone.outbox.entries[1].attempts == 0, "nothing after the first is tried")
        #expect(phone.outbox.next(at: phone.now) == nil, "backing off")

        await server.setOffline(false)
        phone.outbox.retryNow() // the connection came back
        await phone.drain(to: server)
        #expect(phone.outbox.isEmpty)
        #expect(await server.writes == 2)
    }

    @Test(arguments: [
        (APIError.notFound(ServerMessage(summary: "Not found.")), "dropped"),
        (APIError.forbidden(ServerMessage(summary: "No.")), "failed"),
        (APIError.invalid(ServerMessage(summary: "Bad.")), "failed"),
        (APIError.unauthorized(ServerMessage(summary: "Invalid or expired API key.")), "unauthorized"),
        (APIError.server(status: 502, ServerMessage(summary: "Bad gateway")), "retry"),
        (APIError.server(status: 429, ServerMessage(summary: "Slow down")), "retry"),
        (APIError.transport(code: -1001, description: "Timed out"), "retry"),
    ])
    func errorsMapToOutcomes(_ error: APIError, _ expected: String) async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        await server.setFailure(error)
        let phone = FakeDevice(try Fixture.trip())
        let outcome = await EditSender(server: server).send(try phone.noteEdit("Trip essentials", to: "x"), tripID: phone.tripID)
        let name: String
        switch outcome {
        case .done: name = "done"
        case .dropped: name = "dropped"
        case .conflict: name = "conflict"
        case .retry: name = "retry"
        case .failed: name = "failed"
        case .unauthorized: name = "unauthorized"
        }
        #expect(name == expected)
    }
}

@Suite("Outbox")
struct OutboxTests {
    let now = Date(timeIntervalSince1970: 1_900_000_000)

    func tick(_ checked: Bool, item: String = "i1") -> TripEdit {
        .checkItem(.init(checklistID: "l", checklistName: "List", itemID: item, itemName: item, occurrence: 0, isChecked: checked))
    }

    @Test func tickingTheSameItemAgainReplacesTheEdit() {
        var outbox = Outbox()
        outbox.enqueue(tick(true), tripID: "t", at: now)
        outbox.enqueue(tick(true, item: "i2"), tripID: "t", at: now)
        outbox.enqueue(tick(false), tripID: "t", at: now)
        #expect(outbox.entries.count == 2)
        #expect(outbox.entries[0].edit == tick(false))
    }

    @Test func typingANoteBackToWhereItStartedCancelsTheEdit() {
        var outbox = Outbox()
        let base = TripEdit.EditNote(noteID: "n", noteName: "Note", baseContent: "a", content: "ab")
        outbox.enqueue(.editNote(base), tripID: "t", at: now)
        var more = base
        more.content = "abc"
        more.baseContent = "ab" // the screen's base moves on; the outbox keeps the original
        outbox.enqueue(.editNote(more), tripID: "t", at: now)
        #expect(outbox.entries.count == 1)
        guard case .editNote(let merged) = outbox.entries[0].edit else { Issue.record("not a note edit"); return }
        #expect(merged.baseContent == "a" && merged.content == "abc")
        var back = base
        back.content = "a"
        outbox.enqueue(.editNote(back), tripID: "t", at: now)
        #expect(outbox.entries.isEmpty)
        outbox.enqueue(.editNote(back), tripID: "t", at: now)
        #expect(outbox.entries.isEmpty, "an edit that changes nothing isn't queued")
    }

    @Test func onlyBackToBackMovesOfOneRowMerge() {
        var outbox = Outbox()
        let a1 = TripEdit.moveRow(.init(rowID: "a", title: "A", toDate: d1, toIndex: 0))
        let a2 = TripEdit.moveRow(.init(rowID: "a", title: "A", toDate: d1, toIndex: 2))
        let b = TripEdit.moveRow(.init(rowID: "b", title: "B", toDate: d1, toIndex: 1))
        outbox.enqueue(a1, tripID: "t", at: now)
        outbox.enqueue(a2, tripID: "t", at: now)
        #expect(outbox.entries.map(\.edit) == [a2])
        outbox.enqueue(b, tripID: "t", at: now)
        outbox.enqueue(a1, tripID: "t", at: now)
        #expect(outbox.entries.map(\.edit) == [a2, b, a1])
    }

    @Test func outcomesUpdateTheQueue() {
        var outbox = Outbox()
        for item in ["1", "2", "3", "4"] { outbox.enqueue(tick(true, item: item), tripID: "t", at: now) }
        let ids = outbox.entries.map(\.id)
        outbox.record(.done, for: ids[0], at: now)
        outbox.record(.failed("No."), for: ids[1], at: now)
        outbox.record(.dropped("Gone."), for: ids[2], at: now)
        #expect(outbox.entries.map(\.id) == [ids[1], ids[3]])
        #expect(outbox.notices.map(\.message) == ["Gone."])
        #expect(outbox.next(at: now)?.id == ids[3], "failures are skipped")
        #expect(outbox.visibleEdits(for: "t").count == 1, "failed edits aren't shown")
        #expect(outbox.attentionCount == 2)
        outbox.retry(ids[1])
        #expect(outbox.next(at: now)?.id == ids[1])
    }

    @Test func anEditFoldedInWhileSendingIsStillSent() {
        var outbox = Outbox()
        outbox.enqueue(tick(true), tripID: "t", at: now)
        let sending = outbox.entries[0]
        // Untick again while the tick is on its way.
        outbox.enqueue(tick(false), tripID: "t", at: now)
        outbox.record(.done, for: sending.id, sent: sending.edit, at: now)
        #expect(outbox.entries.map(\.edit) == [tick(false)])
        #expect(outbox.next(at: now)?.id == sending.id)

        // A note saved twice: the second send starts from what the first one saved.
        var notes = Outbox()
        notes.enqueue(.editNote(.init(noteID: "n", noteName: "N", baseContent: "a", content: "b")), tripID: "t", at: now)
        let first = notes.entries[0]
        notes.enqueue(.editNote(.init(noteID: "n", noteName: "N", baseContent: "b", content: "c")), tripID: "t", at: now)
        notes.record(.done, for: first.id, sent: first.edit, at: now)
        #expect(notes.entries.first?.edit == .editNote(.init(noteID: "n", noteName: "N", baseContent: "b", content: "c")))
    }

    @Test func aNewTickSupersedesAFailedOne() {
        var outbox = Outbox()
        outbox.enqueue(tick(true), tripID: "t", at: now)
        outbox.record(.failed("No."), for: outbox.entries[0].id, at: now)
        outbox.enqueue(tick(false), tripID: "t", at: now)
        #expect(outbox.entries.map(\.edit) == [tick(false)])
        #expect(outbox.entries[0].isWaiting)
    }

    @Test func retriesBackOff() {
        var outbox = Outbox()
        outbox.enqueue(tick(true), tripID: "t", at: now)
        let id = outbox.entries[0].id
        outbox.record(.retry("Offline"), for: id, at: now)
        #expect(outbox.next(at: now) == nil)
        #expect(outbox.next(at: now.addingTimeInterval(5))?.id == id)
        outbox.record(.retry("Offline"), for: id, at: now)
        #expect(outbox.nextAttempt == now.addingTimeInterval(10))
        #expect(Outbox.backoff(attempts: 1) == 5)
        #expect(Outbox.backoff(attempts: 4) == 40)
        #expect(Outbox.backoff(attempts: 30) == 300)
        outbox.retryNow()
        #expect(outbox.next(at: now)?.id == id)
    }

    @Test func survivesARoundTripThroughJSON() throws {
        var outbox = Outbox()
        outbox.enqueue(tick(true), tripID: "t", at: now)
        outbox.enqueue(.editNote(.init(noteID: "n", noteName: "N", baseContent: "", content: "x")), tripID: "t", at: now)
        outbox.enqueue(.moveRow(.init(rowID: "r", title: "R", toDate: nil, toIndex: 1)), tripID: "t", at: now)
        outbox.record(.conflict(NoteConflict(serverContent: "y", serverUpdatedAt: now)), for: outbox.entries[1].id, at: now)
        outbox.record(.dropped("Gone"), for: outbox.entries[0].id, at: now)
        let data = try JSONEncoder().encode(outbox)
        #expect(try JSONDecoder().decode(Outbox.self, from: data) == outbox)
    }
}

@Suite("Two phones, one trip")
struct ConvergenceTests {
    /// The Stage 2 exit check in miniature: two phones edit the same trip offline, come back
    /// online in turn, and end up showing the same trip with both sets of changes.
    @Test func twoPhonesEditingOfflineConverge() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var alex = FakeDevice(try Fixture.trip())
        var sam = FakeDevice(try Fixture.trip())

        alex.make(try alex.tick("Check the spare tyre", on: "Car pickup"))
        alex.make(try alex.move("Sunset cruise", to: d2, at: 0))
        alex.make(try alex.noteEdit("Trip essentials", to: "Passports and chargers."))

        sam.make(try sam.tick("Note the fuel level", on: "Car pickup"))
        sam.make(try sam.tick("Driver licences + IDP", on: "Car pickup", false))
        sam.make(try sam.move("Wineglass Bay Lookout", to: d1, at: 99))
        sam.make(try sam.noteEdit("Hobart day tips", to: "Salamanca market is Saturday only."))

        await alex.drain(to: server)
        await sam.drain(to: server)
        try await alex.refresh(from: server)
        try await sam.refresh(from: server)

        #expect(alex.outbox.isEmpty && sam.outbox.isEmpty)
        #expect(alex.shown == sam.shown)

        let list = try #require(alex.shown.checklists.first { $0.name == "Car pickup" })
        let state = Dictionary(uniqueKeysWithValues: list.items.map { ($0.name, $0.isChecked) })
        #expect(state["Check the spare tyre"] == true)
        #expect(state["Note the fuel level"] == true)
        #expect(state["Driver licences + IDP"] == false)
        #expect(alex.titles(on: d2).first == "Sunset cruise")
        #expect(!alex.titles(on: d2).contains("Wineglass Bay Lookout"))
        #expect(alex.titles(on: d1).last == "Wineglass Bay Lookout")
        #expect(alex.shown.notes.first { $0.name == "Trip essentials" }?.content == "Passports and chargers.")
        #expect(alex.shown.notes.first { $0.name == "Hobart day tips" }?.content == "Salamanca market is Saturday only.")
    }

    @Test func bothEditingOneNoteEndsTheSameOnceOneChooses() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var alex = FakeDevice(try Fixture.trip())
        var sam = FakeDevice(try Fixture.trip())
        alex.make(try alex.noteEdit("Hobart day tips", to: "Alex's tips."))
        sam.make(try sam.noteEdit("Hobart day tips", to: "Sam's tips."))

        await alex.drain(to: server)
        await sam.drain(to: server)
        let conflict = try #require(sam.outbox.entries.first)
        #expect(conflict.conflict?.serverContent == "Alex's tips.")

        sam.outbox.keepMine(conflict.id)
        await sam.drain(to: server)
        try await alex.refresh(from: server)
        try await sam.refresh(from: server)
        #expect(alex.shown == sam.shown)
        #expect(alex.shown.notes.first { $0.name == "Hobart day tips" }?.content == "Sam's tips.")
    }
}

extension PendingEdit {
    var conflict: NoteConflict? {
        if case .conflict(let value) = state { return value }
        return nil
    }
}
