// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

private let d1 = CalendarDate("2027-03-07")!
private let d2 = CalendarDate("2027-03-08")!
private let hobart = TimeZone(identifier: "Australia/Hobart")!

private func at(_ iso: String) -> Date { ISO8601.parse(iso)! }

extension FakeDevice {
    func place(_ name: String) throws -> Location {
        try #require(shown.locations.first { $0.name == name })
    }

    func leg(_ name: String) throws -> Transportation {
        try #require(shown.transportations.first { $0.name.contains(name) })
    }

    /// The edit that sets `values` on the named place's first visit, as the edit sheet makes it.
    func editPlace(_ name: String, _ values: [ItemField: FieldValue]) throws -> TripEdit {
        let place = try place(name)
        let visit = place.visits.first?.id
        let item = TripPlan.Item.location(place, visits: place.visits)
        return .editItem(try #require(TripEdit.EditItem(item: item, visitID: visit, values: values)))
    }

    func editLeg(_ name: String, _ values: [ItemField: FieldValue]) throws -> TripEdit {
        .editItem(try #require(TripEdit.EditItem(item: .transportation(try leg(name)), visitID: nil, values: values)))
    }

    func appendTo(_ name: String, _ line: String) throws -> TripEdit {
        let place = try place(name)
        return .appendNote(TripEdit.AppendNote(kind: .location, itemID: place.id, visitID: place.visits.first?.id, title: place.name, line: line))
    }
}

@Suite("Editing items")
struct ItemEditTests {
    @Test func aPlacesTimesAndVisitNotesShowAtOnceAndReachTheServer() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        await server.setOffline(true)

        phone.make(try phone.editPlace("Harbour kayak tour", [
            .start: .time(at("2027-03-07T02:00:00Z")), .end: .time(at("2027-03-07T02:45:00Z")),
            .visitNotes: .text("Moved to the 13:00 slot."),
        ]))
        let shownVisit = try #require(try phone.place("Harbour kayak tour").visits.first)
        #expect(shownVisit.startDate == at("2027-03-07T02:00:00Z"))
        #expect(shownVisit.notes == "Moved to the 13:00 slot.")

        await phone.drain(to: server)
        #expect(phone.outbox.waitingCount == 1) // offline: still waiting

        await server.setOffline(false)
        phone.outbox.retryNow()
        await phone.drain(to: server)
        #expect(phone.outbox.entries.isEmpty)
        let saved = try #require(await server.trip.locations.first { $0.name == "Harbour kayak tour" }?.visits.first)
        #expect(saved.startDate == at("2027-03-07T02:00:00Z") && saved.endDate == at("2027-03-07T02:45:00Z"))
        #expect(saved.notes == "Moved to the 13:00 slot.")
    }

    @Test func aClashOnOneFieldSavesTheOthersAndAsks() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        phone.make(try phone.editPlace("Harbour kayak tour", [
            .start: .time(at("2027-03-07T02:00:00Z")), .visitNotes: .text("Meet at the second pontoon."),
        ]))
        // Someone moved the start on the web meanwhile.
        await server.mutate { trip in
            let place = trip.locations.firstIndex { $0.name == "Harbour kayak tour" }!
            trip.locations[place].visits[0].startDate = at("2027-03-07T01:30:00Z")
        }
        await phone.drain(to: server)

        let visit = try #require(await server.trip.locations.first { $0.name == "Harbour kayak tour" }?.visits.first)
        #expect(visit.notes == "Meet at the second pontoon.") // saved
        #expect(visit.startDate == at("2027-03-07T01:30:00Z")) // theirs, for now
        let entry = try #require(phone.outbox.entries.first)
        guard case .fieldConflict(let conflict) = entry.state, case .editItem(let edit) = entry.edit else {
            Issue.record("expected a field conflict, got \(entry.state)")
            return
        }
        #expect(conflict.clashes == [FieldClash(field: .start, server: .time(at("2027-03-07T01:30:00Z")))])
        #expect(edit.changes.map(\.field) == [.start]) // only the clash is left

        phone.outbox.keepMine(entry.id)
        await phone.drain(to: server)
        #expect(phone.outbox.entries.isEmpty)
        #expect(await server.trip.locations.first { $0.name == "Harbour kayak tour" }?.visits.first?.startDate == at("2027-03-07T02:00:00Z"))
    }

    @Test func keepingTheirsLeavesTheServersValue() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        phone.make(try phone.editLeg("EX 1501", [.flightNumber: .text("EX1503")]))
        await server.mutate { trip in
            let leg = trip.transportations.firstIndex { $0.name.contains("EX 1501") }!
            trip.transportations[leg].flightNumber = "EX1505"
        }
        await phone.drain(to: server)
        let entry = try #require(phone.outbox.entries.first)
        phone.outbox.discard(entry.id)
        #expect(phone.outbox.entries.isEmpty)
        #expect(await server.trip.transportations.first { $0.name.contains("EX 1501") }?.flightNumber == "EX1505")
    }

    @Test func aFlightEditCarriesTheTripSoCollaboratorsCanSave() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        let leg = try phone.leg("EX 1501")
        let later = try #require(leg.date).addingTimeInterval(1800)
        phone.make(try phone.editLeg("EX 1501", [.start: .time(later), .description: .text(nil)]))
        await phone.drain(to: server)
        #expect(phone.outbox.entries.isEmpty)
        let saved = try #require(await server.trip.transportations.first { $0.id == leg.id })
        #expect(saved.date == later)
        #expect(saved.description == nil) // cleared, not left as it was
    }

    @Test func editingAFieldBackToWhereItStartedDropsTheEdit() throws {
        var phone = FakeDevice(try Fixture.trip())
        let original = try phone.place("Harbour kayak tour").name
        phone.make(try phone.editPlace("Harbour kayak tour", [.name: .text("Kayak tour")]))
        #expect(phone.outbox.entries.count == 1)
        // The sheet always starts from what's shown, so the second edit's base is the first's value.
        phone.make(try phone.editPlace("Kayak tour", [.name: .text(original)]))
        #expect(phone.outbox.entries.isEmpty)
    }

    @Test func notesAddedOnThePhoneGoAfterWhateverTheServerHas() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        let line = TripEdit.AppendNote.line("Moved to 13:00.", at: at("2027-03-06T23:42:00Z"), in: hobart)
        #expect(line == "**10:42** · Moved to 13:00.")
        phone.make(try phone.appendTo("Harbour kayak tour", line))
        #expect(try phone.place("Harbour kayak tour").visits.first?.notes?.hasSuffix(line) == true)

        // Someone else rewrote the visit notes before this phone came online.
        await server.mutate { trip in
            let place = trip.locations.firstIndex { $0.name == "Harbour kayak tour" }!
            trip.locations[place].visits[0].notes = "Rebooked by phone."
        }
        await phone.drain(to: server)
        #expect(phone.outbox.entries.isEmpty)
        let notes = await server.trip.locations.first { $0.name == "Harbour kayak tour" }?.visits.first?.notes
        #expect(notes == "Rebooked by phone.\n\n" + line)

        // Sending it again (a lost answer) doesn't add it twice.
        let again = await EditSender(server: server).send(try phone.appendTo("Harbour kayak tour", line), tripID: phone.tripID)
        #expect(again == .done)
        #expect(await server.trip.locations.first { $0.name == "Harbour kayak tour" }?.visits.first?.notes == notes)
    }

    @Test func aNewNoteShowsAtTheEndOfTheDayAndIsAddedOnce() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        let add = TripEdit.AddNote(name: "Dinner change", content: "Booked the 19:30 table.", date: d1)
        phone.make(.addNote(add))
        #expect(phone.titles(on: d1).last == "Dinner change")

        // Editing it before it's sent changes what is added.
        phone.make(.editNote(TripEdit.EditNote(noteID: add.localID, noteName: add.title, baseContent: add.content, content: "Booked the 20:00 table.")))
        #expect(phone.outbox.entries.count == 1)

        // The note is made but the answer is lost; the retry finds it instead of making another.
        await server.loseNextAnswer()
        await phone.drain(to: server)
        #expect(phone.outbox.waitingCount == 1)
        phone.outbox.retryNow()
        await phone.drain(to: server)
        #expect(phone.outbox.entries.isEmpty)
        #expect(await server.createdNotes == 1)

        try await phone.refresh(from: server)
        #expect(phone.titles(on: d1).last == "Dinner change")
        #expect(phone.shown.notes.first { $0.name == "Dinner change" }?.content == "Booked the 20:00 table.")
    }

    @Test func editsToANoteBeingSentGoToTheServersNote() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        let add = TripEdit.AddNote(name: "Fuel", content: "Fill up in Swansea.", date: d1)
        phone.make(.addNote(add))

        // The note is on its way to the server when it's edited and moved: those edits queue
        // behind it instead of changing what's being sent.
        let entry = try #require(phone.outbox.next(at: phone.now))
        phone.outbox.markSending(entry.id)
        phone.make(.editNote(TripEdit.EditNote(noteID: add.localID, noteName: add.title, baseContent: add.content, content: "Fill up in Bicheno.")))
        phone.make(.moveRow(TripEdit.MoveRow(rowID: add.rowID, title: add.title, toDate: d2, toIndex: 0)))
        #expect(phone.outbox.entries.count == 3)
        #expect(phone.shown.notes.first { $0.name == "Fuel" }?.content == "Fill up in Bicheno.")
        #expect(phone.titles(on: d2).first == "Fuel")

        let outcome = await EditSender(server: server).send(entry.edit, tripID: phone.tripID)
        phone.outbox.record(outcome, for: entry.id, sent: entry.edit, at: phone.now)
        await phone.drain(to: server)
        #expect(phone.outbox.entries.isEmpty)
        #expect(phone.outbox.notices.isEmpty)
        #expect(await server.createdNotes == 1)

        try await phone.refresh(from: server)
        #expect(phone.shown.notes.filter { $0.name == "Fuel" }.map(\.content) == ["Fill up in Bicheno."])
        #expect(phone.titles(on: d2).first == "Fuel")
        #expect(!phone.titles(on: d1).contains("Fuel"))
    }

    @Test func twoIdenticalNotesAreBothAdded() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        // As the app does: each counts the twins already shown, including ones not yet sent.
        for _ in 0..<2 {
            var add = TripEdit.AddNote(name: "Fuel", content: "Fill up.", date: d1)
            add.occurrence = phone.shown.notes.filter(add.isTwin).count
            phone.make(.addNote(add))
        }
        await phone.drain(to: server)
        #expect(phone.outbox.entries.isEmpty)
        #expect(await server.createdNotes == 2)
        try await phone.refresh(from: server)
        #expect(phone.titles(on: d1).filter { $0 == "Fuel" }.count == 2)
    }

    @Test func movingOrRemovingANoteBeforeItsSentChangesWhatIsAdded() throws {
        var phone = FakeDevice(try Fixture.trip())
        let add = TripEdit.AddNote(name: "Fuel", content: "Fill up in Swansea.", date: d1)
        phone.make(.addNote(add))
        phone.make(.moveRow(TripEdit.MoveRow(rowID: add.rowID, title: add.title, toDate: d2, toIndex: 0)))
        #expect(phone.outbox.entries.count == 1)
        #expect(phone.titles(on: d2).last == "Fuel")
        #expect(!phone.titles(on: d1).contains("Fuel"))

        phone.make(.removeRow(TripEdit.RemoveRow(rowID: add.rowID, title: add.title, date: d2)))
        #expect(phone.outbox.entries.isEmpty)
        #expect(!phone.titles(on: d2).contains("Fuel"))
    }

    @Test func removingFromADayKeepsTheItemAndItsVisit() async throws {
        let server = FakeTripServer(trip: try Fixture.trip())
        var phone = FakeDevice(try Fixture.trip())
        let row = try phone.row("Harbour kayak tour")
        phone.make(.removeRow(TripEdit.RemoveRow(rowID: row.id, title: "Harbour kayak tour", date: row.date)))
        #expect(!phone.titles(on: d1).contains("Harbour kayak tour"))
        await phone.drain(to: server)
        #expect(phone.outbox.entries.isEmpty)
        let trip = await server.trip
        #expect(!trip.itinerary.contains { $0.id == row.id })
        #expect(trip.locations.first { $0.name == "Harbour kayak tour" }?.visits.isEmpty == false)
        // Already gone counts as done.
        #expect(await EditSender(server: server).send(.removeRow(TripEdit.RemoveRow(rowID: row.id, title: "x", date: nil)), tripID: trip.id) == .done)
    }

    @Test func patchesSendOnlyTheChangedFieldsAndNullForCleared() throws {
        let patch = ItemPatch(kind: .transportation, fields: [
            .start: .time(at("2027-03-06T20:30:00Z")), .link: .text("  "), .name: .text(""), .flightNumber: .text("EX1503"),
        ], collection: "trip-1")
        let json = String(decoding: try ALCoding.encoder().encode(patch), as: UTF8.self)
        #expect(json == #"{"collection":"trip-1","date":"2027-03-06T20:30:00Z","flight_number":"EX1503","link":null}"#)

        let stay = ItemPatch(kind: .lodging, fields: [.end: .time(nil), .reservationNumber: .text("HP-0008")], collection: nil)
        let stayJSON = String(decoding: try ALCoding.encoder().encode(stay), as: UTF8.self)
        #expect(stayJSON == #"{"check_out":null,"reservation_number":"HP-0008"}"#)

        let row = ItineraryRowCreate(collection: "t", contentType: "note", objectId: "n", order: 3, date: nil)
        let rowJSON = String(decoding: try ALCoding.encoder().encode(row), as: UTF8.self)
        #expect(rowJSON == #"{"collection":"t","content_type":"note","is_global":true,"object_id":"n","order":3}"#)
    }
}
