# ---- Stage 1: build ---------------------------------------------------------
# Install deps with uv into a venv. Build tools stay in this stage only.
FROM python:3.12-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:0.12.23 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never

WORKDIR /app
# Copy only lock files first -> this layer is cached until deps change
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY src ./src
RUN uv sync --frozen --no-dev --no-editable

# ---- Stage 2: runtime -------------------------------------------------------
# Only the venv is copied over: no uv, no source tree, no build cache.
FROM python:3.12-slim

RUN useradd --create-home --uid 10001 app
COPY --from=builder --chown=app:app /app/.venv /app/.venv

ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1 PORT=8080
USER app
EXPOSE 8080

# Cloud Run sends the port in $PORT; default 8080 for local runs
CMD ["sh", "-c", "exec uvicorn linkpulse.main:app --host 0.0.0.0 --port ${PORT}"]
