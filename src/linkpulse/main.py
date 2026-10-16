from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import FileResponse, RedirectResponse
from pydantic import BaseModel, Field, HttpUrl

from linkpulse.config import Settings, get_settings
from linkpulse.storage import CodeTakenError, Link, LinkStore, build_store

STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="LinkPulse", version="0.1.0")
_settings = get_settings()
_store: LinkStore = build_store(
    _settings.storage_backend, _settings.gcp_project, _settings.environment
)


def get_store() -> LinkStore:
    return _store


StoreDep = Annotated[LinkStore, Depends(get_store)]
SettingsDep = Annotated[Settings, Depends(get_settings)]


class CreateLink(BaseModel):
    url: HttpUrl
    alias: str | None = Field(default=None, pattern=r"^[A-Za-z0-9_-]{3,32}$")


# --- Ops endpoints: Cloud Run / load balancers call these ---------------------


@app.get("/healthz", tags=["ops"])
def healthz() -> dict:
    """Liveness: the process is up."""
    return {"status": "ok"}


@app.get("/api/info", tags=["ops"])
def info(settings: SettingsDep) -> dict:
    """Which build is running. Handy for checking that a deploy really went out."""
    return {
        "app": settings.app_name,
        "environment": settings.environment,
        "version": settings.app_version,
        "storage": settings.storage_backend,
    }


# --- Product API --------------------------------------------------------------


@app.post("/api/links", status_code=201, tags=["links"])
def create_link(body: CreateLink, store: StoreDep) -> Link:
    try:
        return store.create(str(body.url), body.alias)
    except CodeTakenError:
        raise HTTPException(409, f"Alias '{body.alias}' is already taken") from None


@app.get("/api/links", tags=["links"])
def recent_links(store: StoreDep) -> list[Link]:
    return store.recent()


@app.get("/api/links/{code}", tags=["links"])
def link_stats(code: str, store: StoreDep) -> Link:
    link = store.get(code)
    if not link:
        raise HTTPException(404, "Link not found")
    return link


@app.get("/", include_in_schema=False)
def home() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/{code}", include_in_schema=False)
def follow(code: str, store: StoreDep) -> RedirectResponse:
    link = store.hit(code)
    if not link:
        raise HTTPException(404, "Link not found")
    return RedirectResponse(link.url, status_code=307)
