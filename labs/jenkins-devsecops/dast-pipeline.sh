#!/bin/bash
# DAST pipeline — paste this into Jenkins freestyle job > Execute shell
# Starts the vulnerable app, runs ZAP baseline scan, stops the app.
# Jenkins container has Docker socket mounted; containers run on the host.

set -uo pipefail

VULN_APP_PORT=8082
VULN_APP_IMAGE="peachycloudsecurity/vulnerable-python-app:latest"
TARGET_URL="http://localhost:${VULN_APP_PORT}"
ZAP_IMAGE="ghcr.io/zaproxy/zaproxy:stable"

JSON_OUT="$WORKSPACE/zap-results.json"
XML_OUT="$WORKSPACE/zap-results.xml"
HTML_OUT="$WORKSPACE/zap-results.html"

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
docker run --rm \
    --network host \
    -v "$WORKSPACE":/zap/wrk/:rw \
    "$ZAP_IMAGE" \
    zap-baseline.py \
    -t "$TARGET_URL" \
    -J zap-results.json \
    -x zap-results.xml \
    -r zap-results.html \
    -I || true
# -I: do not fail on warnings (keep pipeline green for observation)

echo "--- ZAP scan complete ---"
ls -lh "$WORKSPACE"/zap-results.* 2>/dev/null || echo "No output files found"

echo "--- Stopping vulnerable app ---"
docker stop lab-vuln-app 2>/dev/null || true

echo "--- Done. Artifacts: zap-results.json, zap-results.xml, zap-results.html ---"
