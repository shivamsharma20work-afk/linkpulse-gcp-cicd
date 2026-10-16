import pytest
from fastapi.testclient import TestClient

from linkpulse.main import app, get_store
from linkpulse.storage import InMemoryStore


@pytest.fixture
def client():
    # Fresh store per test so tests don't leak state into each other
    store = InMemoryStore()
    app.dependency_overrides[get_store] = lambda: store
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_healthz(client):
    assert client.get("/healthz").json() == {"status": "ok"}


def test_info_reports_version(client):
    body = client.get("/api/info").json()
    assert body["app"] == "LinkPulse"
    assert "version" in body


def test_create_and_follow_link(client):
    r = client.post("/api/links", json={"url": "https://cloud.google.com/run"})
    assert r.status_code == 201
    code = r.json()["code"]

    r = client.get(f"/{code}", follow_redirects=False)
    assert r.status_code == 307
    assert r.headers["location"] == "https://cloud.google.com/run"

    assert client.get(f"/api/links/{code}").json()["clicks"] == 1


def test_custom_alias_conflict(client):
    body = {"url": "https://example.com", "alias": "my-resume"}
    assert client.post("/api/links", json=body).status_code == 201
    assert client.post("/api/links", json=body).status_code == 409


@pytest.mark.parametrize("bad", ["not-a-url", "ftp://", ""])
def test_rejects_invalid_url(client, bad):
    assert client.post("/api/links", json={"url": bad}).status_code == 422


def test_unknown_code_404(client):
    assert client.get("/nope", follow_redirects=False).status_code == 404


def test_build_store_defaults_to_memory():
    from linkpulse.storage import build_store

    assert isinstance(build_store("memory", None, "local"), InMemoryStore)
