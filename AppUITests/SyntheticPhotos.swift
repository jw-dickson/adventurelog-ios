// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

/// A companion's photo summary for the sample trip (Stage 6), as `GET /v1/trips/{id}/photos`
/// answers: what the Log's Photos section shows in the UI tests and the gallery. Made up.
enum SyntheticPhotos {
    static let json = """
    {"enabled": true, "cameraOffsetMinutes": 0, "lastRun": null, "lastError": null, "days": [
      {"date": "2027-03-07", "photos": 4, "undone": 0, "failed": 1, "stops": [
        {"title": "Harbour kayak tour", "photos": 2}, {"title": "Tasmanian Museum and Art Gallery", "photos": 2}]},
      {"date": "2027-03-08", "photos": 6, "undone": 0, "failed": 0, "stops": [
        {"title": "Wineglass Bay Lookout", "photos": 3}, {"title": "Sunset cruise", "photos": 1}, {"title": "", "photos": 2}]}
    ]}
    """
}
