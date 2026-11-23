#!/bin/sh
set -eu

ACTION="${1:-webapp}"

case "$ACTION" in
  webapp)
    if [ "${RUN_MIGRATE:-true}" = "true" ]; then
      echo "Running database migrations..."
      python manage.py migrate --noinput
    fi
    # Keep in sync with Dockerfile EXPOSE and Dockerrun ContainerPort (EB nginx upstream).
    WEB_PORT="${PORT:-8000}"
    echo "Starting RapidPro webapp (gunicorn) on 0.0.0.0:${WEB_PORT}..."
    exec gunicorn temba.wsgi:application \
      --bind "0.0.0.0:${WEB_PORT}" \
      --workers "${WEB_CONCURRENCY:-3}" \
      --timeout "${GUNICORN_TIMEOUT:-120}" \
      --access-logfile "-" \
      --error-logfile "-"
    ;;
  celery)
    if [ -z "${REDIS_URL:-}" ]; then
      echo "ERROR: REDIS_URL is not set in the container environment" >&2
      exit 1
    fi
    # Beat persists schedule via shelve; /app is not writable for user temba.
    BEAT_SCHEDULE="${CELERY_BEAT_SCHEDULE_FILENAME:-/tmp/celerybeat-schedule}"
    echo "Starting RapidPro celery worker (broker host from REDIS_URL, beat schedule ${BEAT_SCHEDULE})..."
    exec celery -A temba worker -E -B \
      --schedule="${BEAT_SCHEDULE}" \
      --loglevel="${CELERY_LOGLEVEL:-INFO}"
    ;;
  *)
    exec "$@"
    ;;
esac
