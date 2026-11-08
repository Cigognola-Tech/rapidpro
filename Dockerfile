# syntax=docker/dockerfile:1.7
# Multi-stage RapidPro image optimized for BuildKit / GitHub Actions cache.
# Same image runs webapp (gunicorn) or celery via CMD.

ARG PYTHON_IMAGE=python:3.12-slim-bookworm
ARG NODE_IMAGE=node:20-bookworm-slim

# -----------------------------------------------------------------------------
# Frontend deps (yarn) — invalidates only when package manifests change
# -----------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS frontend

WORKDIR /app

COPY package.json yarn.lock .npmrc ./
RUN --mount=type=cache,target=/usr/local/share/.cache/yarn \
    yarn install --frozen-lockfile --production --network-timeout 600000

# -----------------------------------------------------------------------------
# Python deps — invalidates only when poetry lockfiles change
# -----------------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS python-deps

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    POETRY_VERSION=2.2.1 \
    POETRY_VIRTUALENVS_IN_PROJECT=true \
    POETRY_NO_INTERACTION=1 \
    POETRY_CACHE_DIR=/tmp/poetry-cache

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        curl \
        ffmpeg \
        gdal-bin \
        libffi-dev \
        libgdal-dev \
        libgeos-dev \
        libjpeg62-turbo-dev \
        libmagic1 \
        libpq-dev \
        libxml2-dev \
        libxslt1-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "poetry==${POETRY_VERSION}"

WORKDIR /app

COPY pyproject.toml poetry.lock ./
RUN --mount=type=cache,target=/tmp/poetry-cache \
    poetry install --only main --no-root --no-ansi

# -----------------------------------------------------------------------------
# Builder — app + static collect/compress
# -----------------------------------------------------------------------------
FROM python-deps AS builder

# Node is required for lessc during compress
COPY --from=frontend /usr/local/bin/node /usr/local/bin/node
COPY --from=frontend /app/node_modules /app/node_modules

WORKDIR /app

COPY . .
# Image uses docker settings; local temba/settings.py is gitignored / dockerignored
RUN cp temba/settings_docker.py temba/settings.py \
    && ln -sf /app/node_modules/less/bin/lessc /usr/local/bin/lessc

ENV DJANGO_SETTINGS_MODULE=temba.settings \
    RAPIDPRO_BUILD=1 \
    SECRET_KEY=build-only-insecure-secret-key \
    DATABASE_URL=postgis://temba:temba@localhost:5432/temba \
    REDIS_URL=redis://localhost:6379/15 \
    DOMAIN=localhost \
    ALLOWED_HOSTS=* \
    PATH="/app/.venv/bin:/usr/local/bin:${PATH}"

RUN poetry install --only main --no-ansi \
    && python manage.py collectstatic --noinput --verbosity=0 \
    && python manage.py compress --extension=".html" --settings=temba.settings_compress \
    && python manage.py collectstatic --noinput --verbosity=0 \
    && find /app -type d -name "__pycache__" -prune -exec rm -rf {} + \
    && rm -rf /tmp/poetry-cache /root/.cache

# -----------------------------------------------------------------------------
# Runtime — slim, no Poetry / compilers
# -----------------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DJANGO_SETTINGS_MODULE=temba.settings \
    PATH="/app/.venv/bin:${PATH}" \
    PORT=8000

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ffmpeg \
        gdal-bin \
        libgdal32 \
        libgeos-c1v5 \
        libjpeg62-turbo \
        libmagic1 \
        libpq5 \
        libxml2 \
        libxslt1.1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 --shell /bin/bash temba

WORKDIR /app

# Drop build-only tooling from the app tree before runtime copy would be ideal;
# runtime image never installs Poetry. Keep node for lessc shebang if compress re-runs.
COPY --from=builder --chown=temba:temba /app /app
COPY --from=frontend /usr/local/bin/node /usr/local/bin/node
COPY --chmod=755 docker/entrypoint.sh /app/docker/entrypoint.sh

USER temba

EXPOSE 8000

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["webapp"]
