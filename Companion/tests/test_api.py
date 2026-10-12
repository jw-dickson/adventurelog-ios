# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
from fastapi.testclient import TestClient

from companion.app import Settings, create_app
from tests.test_worker import KEY, fake_adventurelog


def client(tmp_path) -> TestClient:
    settings = Settings(
        {"ADVENTURELOG_URL": "https://adventurelog.example", "COMPANION_DB": str(tmp_path / "c.sqlite")}
    )
    return TestClient(create_app(settings, adventurelog=fake_adventurelog(), run_worker=False))


def test_registration_needs_a_key_adventurelog_accepts(tmp_path):
    with client(tmp_path) as api:
        assert api.post("/v1/devices", json={}, headers={"X-API-Key": "wrong"}).status_code == 401
        first = api.post("/v1/devices", json={"environment": "sandbox", "startToken": "t1"}, headers={"X-API-Key": KEY})
        assert first.status_code == 200
        # Registering again (a new start token) keeps the same device.
        again = api.post("/v1/devices", json={"environment": "sandbox", "startToken": "t2"}, headers={"X-API-Key": KEY})
        assert again.json()["id"] == first.json()["id"]
        assert api.app.state.store.device(first.json()["id"]).start_token == "t2"
        # The app is told whether activities can start while it's closed (#24); a later
        # registration without a token keeps the one already held.
        assert first.json()["canStart"] is True
        assert api.post("/v1/devices", json={"environment": "sandbox"}, headers={"X-API-Key": KEY}).json()["canStart"] is True


def test_a_phone_without_a_start_token_is_told_so(tmp_path):
    with client(tmp_path) as api:
        reply = api.post("/v1/devices", json={"environment": "production"}, headers={"X-API-Key": KEY}).json()
        assert reply["canStart"] is False


def test_activity_tokens_and_unregistering(tmp_path):
    with client(tmp_path) as api:
        token = {"tripID": "trip", "rowID": "row", "pushToken": "abc"}
        assert api.put("/v1/activities", json=token, headers={"X-API-Key": KEY}).status_code == 404
        device = api.post("/v1/devices", json={}, headers={"X-API-Key": KEY}).json()["id"]
        assert api.put("/v1/activities", json=token, headers={"X-API-Key": KEY}).status_code == 204
        assert api.app.state.store.activity(device, "trip", "row").push_token == "abc"
        assert api.delete("/v1/devices", headers={"X-API-Key": KEY}).status_code == 204
        assert api.app.state.store.device(device) is None


def test_health_says_whether_pushes_are_configured(tmp_path):
    with client(tmp_path) as api:
        assert api.get("/healthz").json() == {"ok": True, "pushes": False}
