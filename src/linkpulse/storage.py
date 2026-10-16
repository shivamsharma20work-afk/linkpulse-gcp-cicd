"""Storage layer.

`LinkStore` is the interface; the app only talks to it. Right now we have an
in-memory implementation for local dev and tests. In Step 2 we add a
Firestore implementation without touching the API code.
"""

import secrets
import string
from datetime import UTC, datetime
from typing import Protocol

from pydantic import BaseModel

CODE_ALPHABET = string.ascii_letters + string.digits


class Link(BaseModel):
    code: str
    url: str
    clicks: int = 0
    created_at: datetime


class LinkStore(Protocol):
    def create(self, url: str, code: str | None = None) -> Link: ...
    def get(self, code: str) -> Link | None: ...
    def hit(self, code: str) -> Link | None: ...
    def recent(self, limit: int = 10) -> list[Link]: ...


class CodeTakenError(Exception):
    pass


def new_code(length: int = 6) -> str:
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(length))


class InMemoryStore:
    def __init__(self) -> None:
        self._links: dict[str, Link] = {}

    def create(self, url: str, code: str | None = None) -> Link:
        if code and code in self._links:
            raise CodeTakenError(code)
        code = code or new_code()
        while code in self._links:
            code = new_code()
        link = Link(code=code, url=url, created_at=datetime.now(UTC))
        self._links[code] = link
        return link

    def get(self, code: str) -> Link | None:
        return self._links.get(code)

    def hit(self, code: str) -> Link | None:
        link = self._links.get(code)
        if link:
            link.clicks += 1
        return link

    def recent(self, limit: int = 10) -> list[Link]:
        links = sorted(self._links.values(), key=lambda l: l.created_at, reverse=True)
        return links[:limit]


class FirestoreStore:
    """Firestore-backed store. One collection per environment (links_staging, links_prod)."""

    def __init__(self, project: str | None, environment: str) -> None:
        # Imported lazily so local dev/tests don't need GCP libraries or credentials
        from google.cloud import firestore

        self._fs = firestore
        self._col = firestore.Client(project=project).collection(f"links_{environment}")

    def create(self, url: str, code: str | None = None) -> Link:
        from google.api_core.exceptions import AlreadyExists

        link = Link(code=code or new_code(), url=url, created_at=datetime.now(UTC))
        for _ in range(5):
            try:
                # .create() fails if the doc exists -> atomic "insert if absent"
                self._col.document(link.code).create(link.model_dump())
                return link
            except AlreadyExists:
                if code:
                    raise CodeTakenError(code) from None
                link.code = new_code()
        raise RuntimeError("Could not generate a unique code")

    def get(self, code: str) -> Link | None:
        snap = self._col.document(code).get()
        return Link(**snap.to_dict()) if snap.exists else None

    def hit(self, code: str) -> Link | None:
        from google.api_core.exceptions import NotFound

        try:
            # Server-side atomic increment: safe when many instances get clicks at once
            self._col.document(code).update({"clicks": self._fs.Increment(1)})
        except NotFound:
            return None
        return self.get(code)

    def recent(self, limit: int = 10) -> list[Link]:
        query = self._col.order_by("created_at", direction="DESCENDING").limit(limit)
        return [Link(**snap.to_dict()) for snap in query.stream()]


def build_store(backend: str, project: str | None, environment: str) -> LinkStore:
    if backend == "firestore":
        return FirestoreStore(project, environment)
    return InMemoryStore()
