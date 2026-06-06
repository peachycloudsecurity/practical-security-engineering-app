#!/bin/bash
# DAST pipeline — paste this into Jenkins freestyle job > Execute shell
# Starts the vulnerable app, runs ZAP baseline scan, stops the app.
# Jenkins container has Docker socket mounted; containers run on the host.

set -uo pipefail

VULN_APP_PORT=8082
VULN_APP_IMAGE="peachycloudsecurity/vulnerable-python-app:latest"
TARGET_URL="http://localhost:${VULN_APP_PORT}"
ZAP_IMAGE="ghcr.io/zaproxy/zaproxy:stable"

echo "--- Pulling vulnerable app image ---"
docker pull "$VULN_APP_IMAGE" || true

echo "--- Starting vulnerable app on port $VULN_APP_PORT ---"
docker rm -f lab-vuln-app 2>/dev/null || true
docker run -d \
    --name lab-vuln-app \
    -p "${VULN_APP_PORT}:8080" \
    "$VULN_APP_IMAGE"

echo "--- Waiting 15s for app to start ---"
sleep 15

echo "--- Running ZAP baseline scan against $TARGET_URL ---"
# Note: Jenkins shell runs inside lab-jenkins container. Docker commands run on the
# HOST daemon via the mounted socket. $WORKSPACE is a path inside the Jenkins container
# so -v "$WORKSPACE":/zap/wrk/ would fail (host daemon resolves it on host FS, not inside Jenkins).
# Solution: run ZAP without a volume mount, then docker cp results into $WORKSPACE.
docker rm -f lab-zap-run 2>/dev/null || true
docker run \
    --name lab-zap-run \
    --network host \
    "$ZAP_IMAGE" \
    zap-baseline.py \
    -t "$TARGET_URL" \
    -J /zap/wrk/zap-results.json \
    -x /zap/wrk/zap-results.xml \
    -r /zap/wrk/zap-results.html \
    -I || true
# -I: do not fail on warnings (keep pipeline green for observation)

echo "--- Copying ZAP output into workspace ---"
docker cp lab-zap-run:/zap/wrk/zap-results.json "$WORKSPACE"/ || true
docker cp lab-zap-run:/zap/wrk/zap-results.xml  "$WORKSPACE"/ || true
docker cp lab-zap-run:/zap/wrk/zap-results.html "$WORKSPACE"/ || true
docker rm lab-zap-run 2>/dev/null || true

echo "--- ZAP scan complete ---"
ls -lh "$WORKSPACE"/zap-results.* 2>/dev/null || echo "No output files found"

echo "--- Stopping vulnerable app ---"
docker stop lab-vuln-app 2>/dev/null || true

echo "--- Done. Artifacts: zap-results.json, zap-results.xml, zap-results.html ---"
