#!/bin/bash
# DevSecOps Lab — Jenkins + DefectDojo setup for GitHub Codespaces
# Creates ~/devsecops-lab/, starts Jenkins on :8080 and DefectDojo on :8181.
#
# Usage:
#   bash labs/jenkins-devsecops/setup.sh
#
# Safe to re-run — only removes containers this script created (lab-jenkins).
# Never touches vsc-* or other Codespace system containers.

set -euo pipefail

JENKINS_PORT=8080
DD_PORT=8181
LAB_DIR="$HOME/devsecops-lab"

echo "==> Creating lab directory: $LAB_DIR"
mkdir -p "$LAB_DIR/jenkins-data"

# -------------------------------------------------------------------
# Container cleanup — only named lab containers, never system ones
# -------------------------------------------------------------------
echo "==> Checking for previous lab containers..."
for c in lab-jenkins lab-vuln-app; do
    if docker ps -aq --filter "name=^/${c}$" | grep -q .; then
        echo "    Removing $c..."
        docker rm -f "$c" 2>/dev/null || true
    fi
done

# If a previous DefectDojo compose stack exists, bring it down cleanly
if [ -d "$LAB_DIR/defectdojo" ]; then
    echo "    Stopping previous DefectDojo stack..."
    cd "$LAB_DIR/defectdojo" && docker compose down --remove-orphans 2>/dev/null || true
    cd - > /dev/null
fi

# -------------------------------------------------------------------
# Jenkins
# -------------------------------------------------------------------
echo "==> Starting Jenkins on port $JENKINS_PORT..."
docker run -d \
    --name lab-jenkins \
    -p "${JENKINS_PORT}:8080" \
    -p 50000:50000 \
    -v "$LAB_DIR/jenkins-data":/var/jenkins_home \
    -v /var/run/docker.sock:/var/run/docker.sock \
    jenkins/jenkins:lts-jdk17

# -------------------------------------------------------------------
# DefectDojo — clone if not already present, override nginx port
# -------------------------------------------------------------------
echo "==> Setting up DefectDojo on port $DD_PORT..."
if [ ! -d "$LAB_DIR/defectdojo" ]; then
    git clone --depth=1 https://github.com/DefectDojo/django-DefectDojo \
        "$LAB_DIR/defectdojo"
fi

# Write a docker-compose override to remap nginx from 80/8080 → DD_PORT
cat > "$LAB_DIR/defectdojo/docker-compose.override.yml" <<EOF
services:
  nginx:
    ports:
      - "${DD_PORT}:8080"
EOF

# Patch the base compose so it doesn't also bind 8080 (would conflict with Jenkins)
# Replace any existing 8080 or 80 host port binding in nginx service
sed -i.bak \
    -e '/^\s*- "8080:8080"/d' \
    -e '/^\s*- "80:8080"/d' \
    "$LAB_DIR/defectdojo/docker-compose.yml" 2>/dev/null || true

cd "$LAB_DIR/defectdojo"
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d \
    --remove-orphans 2>&1 | tail -10
cd - > /dev/null

# -------------------------------------------------------------------
# Wait and report
# -------------------------------------------------------------------
echo ""
echo "==> Waiting for Jenkins to initialise (60s)..."
sleep 60

JENKINS_PASS=$(docker exec lab-jenkins \
    cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null \
    || echo "(still starting — run: docker exec lab-jenkins cat /var/jenkins_home/secrets/initialAdminPassword)")

DD_PASS=$(cd "$LAB_DIR/defectdojo" && \
    docker compose logs initializer 2>/dev/null | grep -i "admin password" | tail -1 \
    || echo "(run: cd $LAB_DIR/defectdojo && docker compose logs initializer | grep -i password)")

echo ""
echo "============================================================"
echo "  Jenkins:    http://localhost:${JENKINS_PORT}"
echo "  DefectDojo: http://localhost:${DD_PORT}"
echo ""
echo "  Jenkins unlock password : ${JENKINS_PASS}"
echo "  DefectDojo admin login  : admin"
echo "  DefectDojo admin pass   : ${DD_PASS}"
echo "============================================================"
echo ""
echo "Note: DefectDojo takes 3-5 minutes to fully start."
echo "      Check status: cd $LAB_DIR/defectdojo && docker compose ps"
