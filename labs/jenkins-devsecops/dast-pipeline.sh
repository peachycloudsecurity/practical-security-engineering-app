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
# ZAP requires /zap/wrk to be a mounted volume when using file output.
# $WORKSPACE is inside the Jenkins container so it cannot be volume-mounted
# directly (Docker daemon resolves paths on the HOST, not inside the container).
# Solution: named volume for ZAP output, then alpine helper pipes files to stdout
# which the Jenkins shell (inside the container) captures into $WORKSPACE.
ZAP_VOL="lab-zap-work-$$"
docker volume create "$ZAP_VOL" > /dev/null
# Fix ownership: ZAP runs as UID 1000; alpine writes as root — open the dir fully
docker run --rm -v "${ZAP_VOL}:/zap/wrk" alpine chmod 777 /zap/wrk
docker rm -f lab-zap-run 2>/dev/null || true
docker run \
    --name lab-zap-run \
    --network host \
    -v "${ZAP_VOL}:/zap/wrk:rw" \
    "$ZAP_IMAGE" \
    zap-baseline.py \
    -t "$TARGET_URL" \
    -J zap-results.json \
    -x zap-results.xml \
    -r zap-results.html \
    -I || true
# Filenames only (no path prefix): zap-baseline.py prepends /zap/wrk/ automatically
# -I: do not fail on warnings (keep pipeline green for observation)

echo "--- Copying ZAP output into workspace ---"
docker run --rm -v "${ZAP_VOL}:/data" alpine cat /data/zap-results.json > "$WORKSPACE/zap-results.json" 2>/dev/null || true
docker run --rm -v "${ZAP_VOL}:/data" alpine cat /data/zap-results.xml  > "$WORKSPACE/zap-results.xml"  2>/dev/null || true
docker run --rm -v "${ZAP_VOL}:/data" alpine cat /data/zap-results.html > "$WORKSPACE/zap-results.html" 2>/dev/null || true
docker rm -f lab-zap-run 2>/dev/null || true
docker volume rm "$ZAP_VOL" 2>/dev/null || true

echo "--- ZAP scan complete ---"
ls -lh "$WORKSPACE"/zap-results.* 2>/dev/null || echo "No output files found"

echo "--- Stopping vulnerable app ---"
docker stop lab-vuln-app 2>/dev/null || true

echo "--- Done. Artifacts: zap-results.json, zap-results.xml, zap-results.html ---"
