# -----------------------------------------------------------------------------------
# Production / container settings for RapidPro.
#
# Runtime config is expected from Elastic Beanstalk (or equivalent) environment
# variables injected into the container. No .env file is loaded here.
#
# Expected env vars:
#   SECRET_KEY                 required — Django secret
#   DATABASE_URL               required — Postgres/PostGIS URL
#   READONLY_DATABASE_URL      optional — read replica; defaults to DATABASE_URL
#   REDIS_URL                  required — cache + Celery broker
#   ALLOWED_HOSTS              comma-separated hosts (default "*")
#   HOSTNAME                   hostname (default from DOMAIN or "localhost")
#   DOMAIN                     brand domain (default "localhost")
#   MAILROOM_URL               Mailroom base URL
#   MAILROOM_AUTH_TOKEN        Mailroom auth token
#   ELASTICSEARCH_URL          Elasticsearch URL
#   STORAGE_URL                public media/base URL
#   RUN_MIGRATE                used by entrypoint (not Django); default "true"
#   RAPIDPRO_BUILD             set to "1" only during image build (locmem cache)
# -----------------------------------------------------------------------------------

import os
import shutil

import dj_database_url

from .settings_common import *  # noqa
from .settings_security import *  # noqa

DEBUG = False

SECRET_KEY = os.environ.get("SECRET_KEY", "build-only-insecure-secret-key")

_domain = os.environ.get("DOMAIN", "localhost")
HOSTNAME = os.environ.get("HOSTNAME", _domain)
ALLOWED_HOSTS = [h.strip() for h in os.environ.get("ALLOWED_HOSTS", "*").split(",") if h.strip()]

BRAND["domain"] = _domain
BRAND["hosts"] = ALLOWED_HOSTS if ALLOWED_HOSTS != ["*"] else [_domain]

STORAGE_URL = os.environ.get("STORAGE_URL", f"https://{_domain}/media")

MAILROOM_URL = os.environ.get("MAILROOM_URL")
MAILROOM_AUTH_TOKEN = os.environ.get("MAILROOM_AUTH_TOKEN")
ELASTICSEARCH_URL = os.environ.get("ELASTICSEARCH_URL", "http://localhost:9200")

# GIS libraries on Debian-based images
_gdal = shutil.which("gdal-config")
if _gdal:
    # Prefer explicit paths when present (slim images)
    for candidate in (
        "/usr/lib/libgdal.so",
        "/usr/lib/x86_64-linux-gnu/libgdal.so",
        "/usr/lib/aarch64-linux-gnu/libgdal.so",
    ):
        if os.path.exists(candidate):
            GDAL_LIBRARY_PATH = candidate
            break
for candidate in (
    "/usr/lib/libgeos_c.so",
    "/usr/lib/x86_64-linux-gnu/libgeos_c.so",
    "/usr/lib/aarch64-linux-gnu/libgeos_c.so",
):
    if os.path.exists(candidate):
        GEOS_LIBRARY_PATH = candidate
        break

# -----------------------------------------------------------------------------------
# Database (PostGIS)
# -----------------------------------------------------------------------------------
_db_defaults = {
    "ATOMIC_REQUESTS": True,
    "CONN_MAX_AGE": 60,
    "OPTIONS": {},
    "DISABLE_SERVER_SIDE_CURSORS": True,
}

_default_database_config = dj_database_url.parse(
    os.environ.get("DATABASE_URL", "postgis://temba:temba@localhost:5432/temba"),
    engine="django.contrib.gis.db.backends.postgis",
    conn_max_age=60,
)
_default_database_config.update(_db_defaults)

_readonly_url = os.environ.get("READONLY_DATABASE_URL") or os.environ.get(
    "DATABASE_URL", "postgis://temba:temba@localhost:5432/temba"
)
_readonly_database_config = dj_database_url.parse(
    _readonly_url,
    engine="django.contrib.gis.db.backends.postgis",
    conn_max_age=60,
)
_readonly_database_config.update(_db_defaults)

DATABASES = {"default": _default_database_config, "readonly": _readonly_database_config}

# -----------------------------------------------------------------------------------
# Cache / Celery
# -----------------------------------------------------------------------------------
_redis_url = os.environ.get("REDIS_URL", "redis://localhost:6379/15")

if os.environ.get("RAPIDPRO_BUILD") == "1":
    # Image build: collectstatic/compress must not require live Redis/Postgres
    CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "rapidpro-build",
        }
    }
    CELERY_TASK_ALWAYS_EAGER = True
    CELERY_TASK_EAGER_PROPAGATES = True
else:
    CACHES = {
        "default": {
            "BACKEND": "django_redis.cache.RedisCache",
            "LOCATION": _redis_url,
            "OPTIONS": {"CLIENT_CLASS": "django_redis.client.DefaultClient"},
        }
    }

CELERY_BROKER_URL = _redis_url

# -----------------------------------------------------------------------------------
# Compression (less via project node_modules)
# -----------------------------------------------------------------------------------
_node = shutil.which("node") or "/usr/local/bin/node"
_lessc = os.path.join(PROJECT_DIR, "../node_modules/less/bin/lessc")
COMPRESS_PRECOMPILERS = (
    (
        "text/less",
        '%s %s --include-path="%s" {infile} {outfile}'
        % (_node, _lessc, os.path.join(PROJECT_DIR, "../static", "less")),
    ),
)

COMPRESS_ENABLED = True
COMPRESS_OFFLINE = True

STATIC_URL = "/sitestatic/"
