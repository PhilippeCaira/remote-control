"""End-to-end tests for admin-pw-service. Run with `pytest -q` from this
directory (ensure requirements.txt + pytest + httpx are installed)."""

import hashlib
import hmac
import os
import sqlite3
import time
from pathlib import Path

import jwt
import pytest

HMAC_KEY = b"test-hmac-key-32-bytes-________"
JWT_KEY = "test-jwt-key"


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("ADMIN_PW_HMAC_KEY", HMAC_KEY.decode())
    monkeypatch.setenv("ADMIN_PW_JWT_KEY", JWT_KEY)
    monkeypatch.setenv("ADMIN_PW_DB_PATH", str(tmp_path / "t.db"))
    # Force re-import so the module picks up the tmp DB + env vars.
    import importlib
    import sys
    sys.modules.pop("main", None)
    import main  # noqa: E402  -- depends on env setup above
    importlib.reload(main)
    from fastapi.testclient import TestClient
    return TestClient(main.app)


def _sign(device_id: str, password: str, ts: int) -> str:
    msg = f"{device_id}:{password}:{ts}".encode()
    return hmac.new(HMAC_KEY, msg, hashlib.sha256).hexdigest()


def _admin_jwt() -> str:
    return jwt.encode({"sub": "admin", "exp": int(time.time()) + 60}, JWT_KEY, algorithm="HS256")


def _post(client, device_id, password, ts=None, sig=None):
    ts = ts or int(time.time())
    sig = sig or _sign(device_id, password, ts)
    return client.post(
        f"/admin-pw/{device_id}",
        json={"password": password, "ts": ts, "hmac": sig},
    )


def test_healthz(client):
    assert client.get("/healthz").json() == {"status": "ok"}


def test_happy_path(client):
    r = _post(client, "dev1", "password123")
    assert r.status_code == 201

    r = client.get("/admin-pw/dev1", headers={"Authorization": f"Bearer {_admin_jwt()}"})
    assert r.status_code == 200
    assert r.json() == {"device_id": "dev1", "password": "password123"}


def test_hmac_rejection(client):
    r = _post(client, "dev1", "password123", sig="0" * 64)
    assert r.status_code == 401


def test_timestamp_skew(client):
    r = _post(client, "dev1", "password123", ts=int(time.time()) - 600)
    assert r.status_code == 400


def test_anti_takeover(client):
    assert _post(client, "dev1", "password-1").status_code == 201
    assert client.get(
        "/admin-pw/dev1", headers={"Authorization": f"Bearer {_admin_jwt()}"}
    ).status_code == 200
    # Once onboarded, a second POST is rejected.
    assert _post(client, "dev1", "password-2").status_code == 409


def test_jwt_required(client):
    r = client.get("/admin-pw/dev1")
    assert r.status_code == 401

    r = client.get("/admin-pw/dev1", headers={"Authorization": "Bearer not-a-jwt"})
    assert r.status_code == 401


def test_delete_then_reregister(client):
    _post(client, "dev1", "password-1")
    client.get("/admin-pw/dev1", headers={"Authorization": f"Bearer {_admin_jwt()}"})

    r = client.delete("/admin-pw/dev1", headers={"Authorization": f"Bearer {_admin_jwt()}"})
    assert r.status_code == 200

    # After DELETE a fresh POST must succeed again.
    assert _post(client, "dev1", "password-2").status_code == 201
