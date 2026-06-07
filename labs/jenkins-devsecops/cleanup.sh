#!/bin/bash
# cleanup.sh — remove ALL lab artifacts: containers, volumes, AND images
# Use this for a full wipe. Re-run setup.sh + docker image pulls start fresh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$HOME/devsecops-lab"

echo "=== Lab full cleanup: containers + volumes + images ==="

# --- Jenkins + Gitea stack ---
echo "--- Stopping Jenkins + Gitea stack ---"
cd "$SCRIPT_DIR"
docker compose down --volumes --remove-orphans --rmi all 2>/dev/null || true

# --- DefectDojo stack ---
if [ -d "$LAB_DIR/defectdojo" ]; then
    echo "--- Stopping DefectDojo stack ---"
    cd "$LAB_DIR/defectdojo"
    docker compose down --volumes --remove-orphans --rmi all 2>/dev/null || true
fi

# --- Leftover temp containers ---
docker rm -f lab-zap-run lab-vuln-app 2>/dev/null || true

# --- Leftover ZAP work volumes ---
docker volume ls --format '{{.Name}}' | grep "^lab-zap-work-" | xargs -r docker volume rm 2>/dev/null || true

# --- ZAP and vuln-app images (not in compose files) ---
docker rmi ghcr.io/zaproxy/zaproxy:stable 2>/dev/null || true
docker rmi peachycloudsecurity/vulnerable-python-app:latest 2>/dev/null || true

echo ""
echo "=== Done. Everything removed. Re-run setup.sh for a fresh lab. ==="
