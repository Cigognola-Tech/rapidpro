#!/bin/bash
# Diagnostic aid for EB 502s: show how host nginx reaches the app container.
set -x
echo "=== nginx upstream ==="
cat /etc/nginx/conf.d/elasticbeanstalk-nginx-docker-upstream.conf 2>/dev/null || true
echo "=== nginx status ==="
systemctl is-active nginx 2>/dev/null || true
echo "=== docker ==="
docker ps --no-trunc 2>/dev/null || true
echo "=== curl via nginx ==="
curl -sS -o /tmp/health.out -w "http_code=%{http_code}\n" --max-time 5 http://127.0.0.1/health || true
head -c 200 /tmp/health.out 2>/dev/null || true
echo
CID=$(docker ps -q | head -n1)
if [ -n "${CID}" ]; then
  IP=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "${CID}" 2>/dev/null || true)
  echo "=== curl container ${CID} ip=${IP} ==="
  if [ -n "${IP}" ]; then
    curl -sS -o /tmp/health-direct.out -w "http_code=%{http_code}\n" --max-time 5 "http://${IP}:8000/health" || true
    head -c 200 /tmp/health-direct.out 2>/dev/null || true
    echo
  fi
fi
