#!/bin/bash
# reset.sh — remove containers and volumes but KEEP images
# Faster than cleanup.sh: next setup.sh skips image pulls.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$HOME/devsecops-lab"

echo "=== Lab reset: containers + volumes removed, images kept ==="

# --- Jenkins + Gitea stack ---
echo "--- Stopping Jenkins + Gitea stack ---"
cd "$SCRIPT_DIR"
docker compose down --volumes --remove-orphans 2>/dev/null || true

# --- DefectDojo stack ---
if [ -d "$LAB_DIR/defectdojo" ]; then
    echo "--- Stopping DefectDojo stack ---"
    cd "$LAB_DIR/defectdojo"
    docker compose down --volumes --remove-orphans 2>/dev/null || true
fi

# --- Leftover temp containers ---
docker rm -f lab-zap-run lab-vuln-app 2>/dev/null || true

# --- Leftover ZAP work volumes ---
docker volume ls --format '{{.Name}}' | grep "^lab-zap-work-" | xargs -r docker volume rm 2>/dev/null || true

echo ""
echo "=== Done. Images kept. Re-run setup.sh to bring the lab back up. ==="
