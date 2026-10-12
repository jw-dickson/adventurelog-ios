# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Replan suggestions from Claude (Stage 5b): the free-text ask on the phone's replan sheet.

The phone sends the rest of today (its `Replan.Situation`), its own proposal, the trip's days and
what the person asked. Claude answers through a tool whose input is the phone's proposal format,
so the reply is data the phone can check with `ReplanCheck` before showing it. Nothing is stored.
"""

from __future__ import annotations

import json
from datetime import datetime
from zoneinfo import ZoneInfo

import httpx

API_VERSION = "2023-06-01"
DEFAULT_MODEL = "claude-sonnet-5-5"
CHANGE_TYPES = ("keep", "retime", "move", "skip", "add")

SYSTEM = """You help a traveller who is running late rearrange the rest of today's trip plan.

You get the remaining stops in order (each with a rowID, its planned start and end as UTC ISO-8601 \
and as local time, whether it is booked, and where it is), how many minutes late they are, the \
trip's days, the phone's own proposal, and what the traveller asked for. Answer only by calling \
propose_replan.

Rules the phone enforces (a proposal that breaks one is thrown away):
- Booked stops never change: list each one as {"type": "keep"} and nothing else.
- Use only the rowIDs given, at most one change per row.
- "retime" gives new start and end on today, as UTC ISO-8601 with a Z. Nothing starts before now. \
End after start.
- "move" puts a stop on a later day from the trip's days, with start and end on that day.
- "skip" leaves a stop out today (it stays in the trip).
- "add" adds a note (title, short content) on today or a later trip day, e.g. a meal.
- Nothing you change may overlap another stop afterwards. Leave travel time between places.
- Keep things planned for daylight before sunset when you can, and the day over by 23:00.

Start from the phone's proposal and change what the traveller asked for. Put booked stops first, \
then the rest in the day's order. "summary" is one or two short sentences in plain English saying \
what the plan keeps and what it gives up. A "reason" is a few words, or leave it out."""

TOOL = {
    "name": "propose_replan",
    "description": "The revised rest-of-today, in the phone's proposal format.",
    "input_schema": {
        "type": "object",
        "required": ["behindMinutes", "summary", "changes"],
        "properties": {
            "behindMinutes": {"type": "integer", "minimum": 0},
            "summary": {"type": "string"},
            "changes": {
                "type": "array",
                "maxItems": 40,
                "items": {
                    "type": "object",
                    "required": ["type"],
                    "properties": {
                        "type": {"type": "string", "enum": list(CHANGE_TYPES)},
                        "rowID": {"type": "string"},
                        "start": {"type": "string", "description": "UTC ISO-8601, e.g. 2027-03-08T07:45:00Z"},
                        "end": {"type": "string", "description": "UTC ISO-8601"},
                        "date": {"type": "string", "description": "YYYY-MM-DD, for move and add"},
                        "title": {"type": "string", "description": "For add"},
                        "content": {"type": "string", "description": "For add"},
                        "reason": {"type": "string"},
                    },
                },
            },
        },
    },
}


class ClaudeError(Exception):
    """Claude couldn't be reached, refused, or answered something unusable."""


def _local(iso: str | None, zone: str | None) -> str | None:
    if not iso:
        return None
    try:
        moment = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return moment.astimezone(ZoneInfo(zone or "UTC")).strftime("%a %d %b %H:%M")
    except (ValueError, KeyError):
        return None


def describe(situation: dict) -> dict:
    """The situation with each stop's times also in local time, which Claude reads more reliably."""
    stops = []
    for stop in situation.get("stops", []):
        zone = stop.get("zoneID")
        stops.append(
            {
                **stop,
                "localStart": _local(stop.get("start"), zone),
                "localEnd": _local(stop.get("end"), zone),
            }
        )
    described = {**situation, "stops": stops}
    described["localNow"] = _local(situation.get("now"), situation.get("zoneID"))
    return described


def clean(proposal: object) -> dict:
    """Claude's tool input as a proposal, or ClaudeError. The phone checks the rest."""
    if not isinstance(proposal, dict) or not isinstance(proposal.get("changes"), list):
        raise ClaudeError("Claude's answer had no list of changes.")
    changes = []
    for change in proposal["changes"]:
        if not isinstance(change, dict) or change.get("type") not in CHANGE_TYPES:
            raise ClaudeError("Claude's answer had a change the app doesn't know.")
        changes.append({key: value for key, value in change.items() if isinstance(value, str) and value.strip()})
    behind = proposal.get("behindMinutes")
    return {
        "behindMinutes": behind if isinstance(behind, int) and behind >= 0 else 0,
        "summary": str(proposal.get("summary") or "").strip(),
        "changes": changes,
        "source": "claude",
    }


class Claude:
    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_MODEL,
        transport: httpx.AsyncBaseTransport | None = None,
        base_url: str = "https://api.anthropic.com",
    ):
        self.model = model
        self._client = httpx.AsyncClient(
            base_url=base_url,
            transport=transport,
            timeout=60,
            headers={"x-api-key": api_key, "anthropic-version": API_VERSION, "content-type": "application/json"},
        )

    async def close(self) -> None:
        await self._client.aclose()

    async def replan(self, situation: dict, ask: str, proposal: dict | None, trip_days: list[str]) -> dict:
        message = {
            "today": describe(situation),
            "tripDays": trip_days,
            "phoneProposal": proposal,
            "ask": ask,
        }
        body = {
            "model": self.model,
            "max_tokens": 2000,
            "system": SYSTEM,
            "tools": [TOOL],
            "tool_choice": {"type": "tool", "name": TOOL["name"]},
            "messages": [{"role": "user", "content": json.dumps(message, ensure_ascii=False)}],
        }
        try:
            response = await self._client.post("/v1/messages", json=body)
        except httpx.HTTPError as error:
            raise ClaudeError(f"Claude can't be reached: {error}") from error
        if response.status_code in (401, 403):
            raise ClaudeError("Claude refused the companion's API key.")
        if response.status_code == 429:
            raise ClaudeError("Claude is busy (rate limited). Try again in a minute.")
        if response.status_code >= 400:
            raise ClaudeError(f"Claude answered {response.status_code}.")
        try:
            content = response.json().get("content", [])
        except ValueError as error:
            raise ClaudeError("Claude sent something other than JSON.") from error
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == TOOL["name"]:
                return clean(block.get("input"))
        raise ClaudeError("Claude didn't propose a plan.")
