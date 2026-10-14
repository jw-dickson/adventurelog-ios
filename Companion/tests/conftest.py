# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Store targets for tests: a SQLite file, and Postgres when COMPANION_TEST_DATABASE_URL names a
disposable database (CI runs one as a service). Each Postgres test gets a schema of its own,
dropped afterwards, so tests never see each other's rows."""

import os
import uuid
from urllib.parse import quote

import pytest

POSTGRES_URL = os.environ.get("COMPANION_TEST_DATABASE_URL")


@pytest.fixture(params=["sqlite", "postgres"])
def store_target(request, tmp_path):
    if request.param == "sqlite":
        yield str(tmp_path / "c.sqlite")
        return
    if not POSTGRES_URL:
        pytest.skip("COMPANION_TEST_DATABASE_URL is not set")
    import psycopg

    schema = f"test_{uuid.uuid4().hex[:12]}"
    with psycopg.connect(POSTGRES_URL, autocommit=True) as connection:
        connection.execute(f'create schema "{schema}"')
    separator = "&" if "?" in POSTGRES_URL else "?"
    yield f"{POSTGRES_URL}{separator}options={quote(f'-csearch_path={schema}')}"
    with psycopg.connect(POSTGRES_URL, autocommit=True) as connection:
        connection.execute(f'drop schema "{schema}" cascade')
