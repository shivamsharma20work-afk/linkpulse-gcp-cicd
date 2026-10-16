"""App settings, read from environment variables (12-factor style).

Cloud Run injects env vars at deploy time, so the same Docker image
runs locally and on GCP without code changes.
"""

from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    app_name: str = "LinkPulse"
    environment: str = "local"  # local | dev | prod
    app_version: str = "dev"  # set by Cloud Build to the git commit SHA
    storage_backend: str = "memory"  # memory | firestore
    gcp_project: str | None = None


@lru_cache
def get_settings() -> Settings:
    return Settings()
