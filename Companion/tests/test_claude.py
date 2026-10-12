# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Replan asks through Claude, against a fake Anthropic API."""

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from companion.app import Settings, create_app
from companion.claude import Claude, ClaudeError, clean, describe
from tests.test_worker import KEY, fake_adventurelog

# The rest of a synthetic Freycinet afternoon, as the phone sends it.
SITUATION = {
    "date": "2027-03-08",
    "now": "2027-03-08T05:48:00Z",
    "zoneID": "Australia/Hobart",
    "delayMinutes": 48,
    "stops": [
        {
            "rowID": "row-walk",
            "itemID": "walk",
            "title": "Cape Tourville walk",
            "kind": "location",
            "start": "2027-03-08T05:00:00Z",
            "end": "2027-03-08T06:00:00Z",
            "zoneID": "Australia/Hobart",
            "isBooked": False,
            "isFlight": False,
        },
        {
            "rowID": "row-tour",
            "itemID": "tour",
            "title": "Night wildlife tour",
            "kind": "location",
            "start": "2027-03-08T10:00:00Z",
            "end": "2027-03-08T11:30:00Z",
            "zoneID": "Australia/Hobart",
            "isBooked": True,
            "isFlight": False,
        },
    ],
}
ANSWER = {
    "behindMinutes": 48,
    "summary": "This keeps the tour and saves the walk for tomorrow.",
    "changes": [
        {"type": "keep", "rowID": "row-tour"},
        {
            "type": "move",
            "rowID": "row-walk",
            "date": "2027-03-09",
            "start": "2027-03-08T21:00:00Z",
            "end": "2027-03-08T22:00:00Z",
            "reason": " ",
        },
        {"type": "add", "title": "Dinner at the campsite", "content": "Rest before the tour", "date": "2027-03-08"},
    ],
}


def anthropic(seen: list, status: int = 200, reply: dict | None = None) -> httpx.MockTransport:
    def handle(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if status != 200:
            return httpx.Response(status, json={"type": "error"})
        content = (
            reply
            if reply is not None
            else {
                "content": [
                    {"type": "text", "text": "Here you go."},
                    {"type": "tool_use", "id": "t1", "name": "propose_replan", "input": ANSWER},
                ]
            }
        )
        return httpx.Response(200, json=content)

    return httpx.MockTransport(handle)


def client(tmp_path, claude: Claude | None, per_hour: int = 20) -> TestClient:
    settings = Settings(
        {
            "ADVENTURELOG_URL": "https://adventurelog.example",
            "COMPANION_DB": str(tmp_path / "c.sqlite"),
            "COMPANION_REPLAN_ASKS_PER_HOUR": str(per_hour),
        }
    )
    return TestClient(create_app(settings, adventurelog=fake_adventurelog(), run_worker=False, claude=claude))


def ask(api: TestClient, text: str = "Keep the walk if you can", key: str = KEY):
    body = {"situation": SITUATION, "ask": text, "proposal": {"changes": []}, "tripDays": ["2027-03-08", "2027-03-09"]}
    return api.post("/v1/replan", json=body, headers={"X-API-Key": key})


def test_an_ask_goes_to_claude_and_comes_back_as_a_proposal(tmp_path):
    seen: list[httpx.Request] = []
    with client(tmp_path, Claude("sk-test", model="claude-test", transport=anthropic(seen))) as api:
        assert api.get("/healthz").json()["replan"] is True
        reply = ask(api)
        assert reply.status_code == 200
        proposal = reply.json()
        assert proposal["source"] == "claude"
        assert proposal["changes"][0] == {"type": "keep", "rowID": "row-tour"}
        assert "reason" not in proposal["changes"][1], "blank fields are dropped"
        assert proposal["changes"][2]["title"] == "Dinner at the campsite"

    request = seen[0]
    assert request.url.path == "/v1/messages"
    assert request.headers["x-api-key"] == "sk-test"
    assert request.headers["anthropic-version"] == "2023-06-01"
    body = json.loads(request.content)
    assert body["model"] == "claude-test"
    assert body["tool_choice"] == {"type": "tool", "name": "propose_replan"}
    sent = json.loads(body["messages"][0]["content"])
    assert sent["ask"] == "Keep the walk if you can"
    assert sent["tripDays"] == ["2027-03-08", "2027-03-09"]
    # Local times help Claude read the day: 16:00 AEDT for the walk.
    assert sent["today"]["stops"][0]["localStart"] == "Mon 08 Mar 16:00"
    assert sent["today"]["localNow"] == "Mon 08 Mar 16:48"


def test_without_a_key_the_companion_says_claude_isnt_set_up(tmp_path):
    with client(tmp_path, None) as api:
        assert api.get("/healthz").json()["replan"] is False
        reply = ask(api)
        assert reply.status_code == 503


def test_asks_need_a_key_adventurelog_accepts_and_some_words(tmp_path):
    seen: list[httpx.Request] = []
    with client(tmp_path, Claude("sk-test", transport=anthropic(seen))) as api:
        assert ask(api, key="wrong").status_code == 401
        assert ask(api, text="   ").status_code == 400
        assert ask(api, text="x" * 501).status_code == 422
    assert seen == [], "nothing reached Claude"


def test_asks_are_limited_per_hour(tmp_path):
    seen: list[httpx.Request] = []
    with client(tmp_path, Claude("sk-test", transport=anthropic(seen)), per_hour=2) as api:
        assert ask(api).status_code == 200
        assert ask(api).status_code == 200
        assert ask(api).status_code == 429
    assert len(seen) == 2


@pytest.mark.parametrize(
    ("status", "message"),
    [(401, "refused"), (429, "busy"), (500, "500")],
)
def test_claude_errors_become_502_with_a_reason(tmp_path, status, message):
    with client(tmp_path, Claude("sk-test", transport=anthropic([], status=status))) as api:
        reply = ask(api)
        assert reply.status_code == 502
        assert message in reply.json()["detail"]


def test_an_answer_without_the_tool_is_an_error(tmp_path):
    no_tool = {"content": [{"type": "text", "text": "Sorry"}]}
    with client(tmp_path, Claude("sk-test", transport=anthropic([], reply=no_tool))) as api:
        reply = ask(api)
        assert reply.status_code == 502
        assert "didn't propose" in reply.json()["detail"]


def test_clean_refuses_unknown_changes_and_fixes_small_things():
    with pytest.raises(ClaudeError):
        clean({"changes": [{"type": "teleport"}]})
    with pytest.raises(ClaudeError):
        clean({"summary": "no changes"})
    tidy = clean({"behindMinutes": -5, "summary": None, "changes": [{"type": "skip", "rowID": "r", "reason": ""}]})
    assert tidy == {"behindMinutes": 0, "summary": "", "changes": [{"type": "skip", "rowID": "r"}], "source": "claude"}


def test_clean_puts_times_in_the_phones_form():
    tidy = clean(
        {
            "changes": [
                {"type": "retime", "rowID": "r", "start": "2027-03-08T18:45:00.5+11:00", "end": "2027-03-08T08:30Z"}
            ]
        }
    )
    assert tidy["changes"][0]["start"] == "2027-03-08T07:45:00Z"
    assert tidy["changes"][0]["end"] == "2027-03-08T08:30:00Z"
    with pytest.raises(ClaudeError):
        clean(
            {"changes": [{"type": "retime", "rowID": "r", "start": "quarter past six", "end": "2027-03-08T08:30:00Z"}]}
        )
    with pytest.raises(ClaudeError):
        clean(
            {
                "changes": [
                    {"type": "retime", "rowID": "r", "start": "2027-03-08T18:45:00", "end": "2027-03-08T08:30:00Z"}
                ]
            }
        )


def test_describe_tolerates_missing_or_odd_times():
    described = describe({"stops": [{"rowID": "r", "start": "not a time", "zoneID": "Nowhere/Land"}]})
    assert described["stops"][0]["localStart"] is None
    assert described["localNow"] is None


def test_more_than_a_day_holds_is_refused_before_claude(tmp_path):
    seen: list[httpx.Request] = []
    with client(tmp_path, Claude("sk-test", transport=anthropic(seen))) as api:
        many = {**SITUATION, "stops": [SITUATION["stops"][0]] * 61}
        body = {"situation": many, "ask": "Help", "tripDays": []}
        assert api.post("/v1/replan", json=body, headers={"X-API-Key": KEY}).status_code == 422
        huge = {**SITUATION, "notes": "x" * 100_001}
        body = {"situation": huge, "ask": "Help", "tripDays": []}
        assert api.post("/v1/replan", json=body, headers={"X-API-Key": KEY}).status_code == 422
        changes = {"changes": [{"type": "keep", "rowID": "r"}] * 41}
        body = {"situation": SITUATION, "ask": "Help", "proposal": changes, "tripDays": []}
        assert api.post("/v1/replan", json=body, headers={"X-API-Key": KEY}).status_code == 422
    assert seen == []
