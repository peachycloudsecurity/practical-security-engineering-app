#!/bin/bash
# DevSecOps Lab — docker-compose setup: Jenkins + Gitea + DefectDojo
# Configures webhooks and Jenkins jobs automatically.
#
# Usage:
#   cd /home/ubuntu/workspace/devsecops/practical-security-engineering-app
#   bash labs/jenkins-devsecops/setup.sh
#
# Credentials after setup:
#   Jenkins    : admin / superman  (http://localhost:8090)
#   Gitea      : admin / superman  (http://localhost:3100)
#   DefectDojo : admin / printed at end  (http://localhost:8181)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
JENKINS_URL="http://localhost:8090"
GITEA_URL="http://localhost:3100"
DD_PORT=8181
LAB_DIR="$HOME/devsecops-lab"
WEBHOOK_SECRET="lab-hook-2024"
JENKINS_USER="admin"
JENKINS_PASS="superman"
GITEA_USER="admin"
GITEA_PASS="superman"

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------
log() { echo "==> $*"; }
wait_http() {
    local url="$1" label="$2" timeout="${3:-300}" start elapsed
    start=$(date +%s)
    printf "Waiting for %s " "$label"
    until curl -sf -o /dev/null "$url" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start ))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo " TIMEOUT after ${elapsed}s"; return 1
        fi
        sleep 3; printf "."
    done
    echo " ready"
}

# -------------------------------------------------------------------------
# Pre-flight
# -------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found"; exit 1
fi

# -------------------------------------------------------------------------
# Cleanup previous run
# -------------------------------------------------------------------------
log "Stopping previous lab stack (if any)..."
cd "$SCRIPT_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker rm -f lab-vuln-app lab-zap-run 2>/dev/null || true
docker volume rm jenkins-devsecops_jenkins_data \
    jenkins-devsecops_gitea_data 2>/dev/null || true

if [ -d "$LAB_DIR/defectdojo" ]; then
    log "Stopping previous DefectDojo stack..."
    cd "$LAB_DIR/defectdojo" && docker compose down --remove-orphans 2>/dev/null || true
    cd "$SCRIPT_DIR"
fi

# -------------------------------------------------------------------------
# Build and start Jenkins + Gitea
# -------------------------------------------------------------------------
log "Building Jenkins image and starting stack..."
cd "$SCRIPT_DIR"
docker compose build 2>&1 | tail -5
docker compose up -d

# -------------------------------------------------------------------------
# Wait for Jenkins
# -------------------------------------------------------------------------
log "Waiting for Jenkins to initialise (~60s)..."
wait_http "$JENKINS_URL/login" "Jenkins" 180

HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$JENKINS_USER:$JENKINS_PASS" \
    "$JENKINS_URL/api/json")
if [ "$HTTP" != "200" ]; then
    echo "ERROR: Jenkins auth failed (HTTP $HTTP)"
    docker logs lab-jenkins 2>&1 | tail -20; exit 1
fi
log "Jenkins OK — admin/superman authenticated"

# -------------------------------------------------------------------------
# Generate Jenkins API token
# -------------------------------------------------------------------------
log "Generating Jenkins API token..."
curl -s -c /tmp/jenkins-cookies.txt -b /tmp/jenkins-cookies.txt \
    -u "$JENKINS_USER:$JENKINS_PASS" "$JENKINS_URL/api/json" > /dev/null

CRUMB_VALUE=$(curl -s -c /tmp/jenkins-cookies.txt -b /tmp/jenkins-cookies.txt \
    -u "$JENKINS_USER:$JENKINS_PASS" "$JENKINS_URL/crumbIssuer/api/json" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['crumb'])")

TOKEN_RESP=$(curl -s -c /tmp/jenkins-cookies.txt -b /tmp/jenkins-cookies.txt \
    -u "$JENKINS_USER:$JENKINS_PASS" \
    -H "Jenkins-Crumb: $CRUMB_VALUE" \
    -X POST "$JENKINS_URL/user/$JENKINS_USER/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken" \
    -d "newTokenName=lab-setup-token")
JENKINS_API_TOKEN=$(echo "$TOKEN_RESP" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['data']['tokenValue'])")

if [ -z "$JENKINS_API_TOKEN" ] || [ "$JENKINS_API_TOKEN" = "None" ]; then
    echo "ERROR: Failed to generate Jenkins API token. Response: $TOKEN_RESP"; exit 1
fi
log "Jenkins API token generated"

# -------------------------------------------------------------------------
# Wait for Gitea
# -------------------------------------------------------------------------
log "Waiting for Gitea to start (~10s)..."
wait_http "$GITEA_URL" "Gitea" 120

# -------------------------------------------------------------------------
# Bootstrap Gitea admin user via CLI (INSTALL_LOCK=true skips install page)
# -------------------------------------------------------------------------
log "Creating Gitea admin user via CLI..."
# Retry loop: DB may still be migrating on first start
RETRIES=0
until docker exec -u git lab-gitea gitea admin user create \
        --username "$GITEA_USER" \
        --password "$GITEA_PASS" \
        --email "admin@example.com" \
        --admin \
        --must-change-password=false 2>/dev/null; do
    RETRIES=$((RETRIES+1))
    if [ "$RETRIES" -ge 20 ]; then echo "ERROR: gitea admin user create failed after 20 attempts"; exit 1; fi
    sleep 3; printf "."
done
echo " Gitea admin created"

# Verify API is reachable with credentials
until curl -sf -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/user" > /dev/null 2>&1; do
    sleep 2; printf "."
done
echo " Gitea API ready"

# -------------------------------------------------------------------------
# Create Gitea API token
# -------------------------------------------------------------------------
log "Creating Gitea API token..."
# Delete old token if exists
curl -s -X DELETE \
    -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/users/$GITEA_USER/tokens/lab-setup" > /dev/null 2>/dev/null || true

GITEA_TOKEN=$(curl -s -X POST \
    -u "$GITEA_USER:$GITEA_PASS" \
    -H "Content-Type: application/json" \
    "$GITEA_URL/api/v1/users/$GITEA_USER/tokens" \
    -d '{"name":"lab-setup","scopes":["write:repository","write:user","write:admin","write:issue","write:notification","write:organization","write:package","read:user","read:repository"]}' | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['sha1'])")

if [ -z "$GITEA_TOKEN" ]; then
    echo "ERROR: Failed to create Gitea token"; exit 1
fi
log "Gitea token: ${GITEA_TOKEN:0:10}..."

# -------------------------------------------------------------------------
# Create Gitea repository
# -------------------------------------------------------------------------
log "Creating Gitea repository 'vulnerable-app'..."
curl -s -X DELETE \
    -H "Authorization: token $GITEA_TOKEN" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/vulnerable-app" > /dev/null 2>/dev/null || true

curl -s -X POST \
    -H "Authorization: token $GITEA_TOKEN" \
    -H "Content-Type: application/json" \
    "$GITEA_URL/api/v1/user/repos" \
    -d '{"name":"vulnerable-app","private":false,"auto_init":false}' > /dev/null

# -------------------------------------------------------------------------
# Push code to Gitea
# -------------------------------------------------------------------------
log "Pushing repo to Gitea..."
cd "$REPO_ROOT"
git remote remove gitea 2>/dev/null || true
git remote add gitea "http://${GITEA_USER}:${GITEA_TOKEN}@localhost:3100/${GITEA_USER}/vulnerable-app.git"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
git push --force gitea "${CURRENT_BRANCH}:main"
git remote remove gitea 2>/dev/null || true
cd "$SCRIPT_DIR"
log "Code pushed to Gitea"

# -------------------------------------------------------------------------
# Add Gitea credentials to Jenkins
# -------------------------------------------------------------------------
log "Adding Gitea credentials to Jenkins..."
curl -s -o /dev/null \
    -X POST "$JENKINS_URL/credentials/store/system/domain/_/createCredentials" \
    -u "$JENKINS_USER:$JENKINS_API_TOKEN" \
    -H "Content-Type: application/xml" \
    -d "<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
          <scope>GLOBAL</scope>
          <id>gitea-admin</id>
          <username>${GITEA_USER}</username>
          <password>${GITEA_TOKEN}</password>
          <description>Gitea admin token</description>
        </com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>"
log "Credentials 'gitea-admin' added"

# -------------------------------------------------------------------------
# Get Jenkins container IP (for webhook — Gitea blocks hostnames)
# -------------------------------------------------------------------------
JENKINS_IP=$(docker inspect lab-jenkins \
    --format '{{(index .NetworkSettings.Networks "jenkins-devsecops_lab-net").IPAddress}}')
log "Jenkins IP on lab-net: $JENKINS_IP"

# -------------------------------------------------------------------------
# Create Jenkins-SAST freestyle job
# -------------------------------------------------------------------------
log "Creating Jenkins-SAST freestyle job..."
cat > /tmp/jenkins-sast-job.xml << 'XMLEOF'
<?xml version='1.1' encoding='UTF-8'?>
<project>
  <description>SAST scan with bandit against the vulnerable Python app</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class="hudson.plugins.git.GitSCM" plugin="git">
    <configVersion>2</configVersion>
    <userRemoteConfigs>
      <hudson.plugins.git.UserRemoteConfig>
        <url>http://lab-gitea:3000/admin/vulnerable-app.git</url>
        <credentialsId>gitea-admin</credentialsId>
      </hudson.plugins.git.UserRemoteConfig>
    </userRemoteConfigs>
    <branches>
      <hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec>
    </branches>
    <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
    <submoduleCfg class="empty-list"/>
    <extensions/>
  </scm>
  <canRoam>true</canRoam>
  <disabled>false</disabled>
  <triggers>
    <org.jenkinsci.plugins.gwt.GenericTrigger plugin="generic-webhook-trigger">
      <spec></spec>
      <genericVariables/>
      <regexpFilterText></regexpFilterText>
      <regexpFilterExpression></regexpFilterExpression>
      <printContributedVariables>false</printContributedVariables>
      <printPostContent>false</printPostContent>
      <silentResponse>false</silentResponse>
      <token>Jenkins-SAST</token>
    </org.jenkinsci.plugins.gwt.GenericTrigger>
  </triggers>
  <concurrentBuild>false</concurrentBuild>
  <builders>
    <hudson.tasks.Shell><command>bash labs/jenkins-devsecops/sast-pipeline.sh</command></hudson.tasks.Shell>
  </builders>
  <publishers>
    <htmlpublisher.HtmlPublisher plugin="htmlpublisher">
      <reportTargets>
        <htmlpublisher.HtmlPublisherTarget>
          <reportName>Bandit SAST Report</reportName>
          <reportDir></reportDir>
          <reportFiles>bandit-results.html</reportFiles>
          <alwaysLinkToLastBuild>false</alwaysLinkToLastBuild>
          <keepAll>false</keepAll>
          <allowMissing>true</allowMissing>
          <reportTitles></reportTitles>
        </htmlpublisher.HtmlPublisherTarget>
      </reportTargets>
    </htmlpublisher.HtmlPublisher>
  </publishers>
  <buildWrappers/>
</project>
XMLEOF

HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$JENKINS_URL/createItem?name=Jenkins-SAST" \
    -u "$JENKINS_USER:$JENKINS_API_TOKEN" \
    -H "Content-Type: application/xml" \
    --data-binary @/tmp/jenkins-sast-job.xml)
log "Jenkins-SAST job: HTTP $HTTP"

# -------------------------------------------------------------------------
# Create Jenkins-DAST freestyle job
# -------------------------------------------------------------------------
log "Creating Jenkins-DAST freestyle job..."
cat > /tmp/jenkins-dast-job.xml << 'XMLEOF'
<?xml version='1.1' encoding='UTF-8'?>
<project>
  <description>DAST scan with ZAP against the vulnerable Python app</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class="hudson.plugins.git.GitSCM" plugin="git">
    <configVersion>2</configVersion>
    <userRemoteConfigs>
      <hudson.plugins.git.UserRemoteConfig>
        <url>http://lab-gitea:3000/admin/vulnerable-app.git</url>
        <credentialsId>gitea-admin</credentialsId>
      </hudson.plugins.git.UserRemoteConfig>
    </userRemoteConfigs>
    <branches>
      <hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec>
    </branches>
    <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
    <submoduleCfg class="empty-list"/>
    <extensions/>
  </scm>
  <canRoam>true</canRoam>
  <disabled>false</disabled>
  <triggers/>
  <concurrentBuild>false</concurrentBuild>
  <builders>
    <hudson.tasks.Shell><command>bash labs/jenkins-devsecops/dast-pipeline.sh</command></hudson.tasks.Shell>
  </builders>
  <publishers>
    <htmlpublisher.HtmlPublisher plugin="htmlpublisher">
      <reportTargets>
        <htmlpublisher.HtmlPublisherTarget>
          <reportName>ZAP DAST Report</reportName>
          <reportDir></reportDir>
          <reportFiles>zap-results.html</reportFiles>
          <alwaysLinkToLastBuild>false</alwaysLinkToLastBuild>
          <keepAll>false</keepAll>
          <allowMissing>true</allowMissing>
          <reportTitles></reportTitles>
        </htmlpublisher.HtmlPublisherTarget>
      </reportTargets>
    </htmlpublisher.HtmlPublisher>
  </publishers>
  <buildWrappers/>
</project>
XMLEOF

HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$JENKINS_URL/createItem?name=Jenkins-DAST" \
    -u "$JENKINS_USER:$JENKINS_API_TOKEN" \
    -H "Content-Type: application/xml" \
    --data-binary @/tmp/jenkins-dast-job.xml)
log "Jenkins-DAST job: HTTP $HTTP"

# -------------------------------------------------------------------------
# Create Gitea webhook → Jenkins-SAST
# -------------------------------------------------------------------------
log "Creating Gitea webhook → Jenkins..."
HOOK_RESP=$(curl -s -X POST \
    -H "Authorization: token $GITEA_TOKEN" \
    -H "Content-Type: application/json" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/vulnerable-app/hooks" \
    -d "{
        \"type\": \"gitea\",
        \"active\": true,
        \"events\": [\"push\"],
        \"config\": {
            \"url\": \"http://${JENKINS_IP}:8080/generic-webhook-trigger/invoke?token=Jenkins-SAST\",
            \"content_type\": \"json\",
            \"secret\": \"${WEBHOOK_SECRET}\"
        }
    }")
HOOK_ID=$(echo "$HOOK_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id','?'))" 2>/dev/null || true)
log "Gitea webhook created — id=$HOOK_ID → http://${JENKINS_IP}:8080/generic-webhook-trigger/invoke?token=Jenkins-SAST"

# -------------------------------------------------------------------------
# Trigger initial SAST build
# -------------------------------------------------------------------------
log "Triggering initial Jenkins-SAST build..."
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$JENKINS_URL/job/Jenkins-SAST/build" \
    -u "$JENKINS_USER:$JENKINS_API_TOKEN")
log "Build queued: HTTP $HTTP"

# -------------------------------------------------------------------------
# Start DefectDojo
# -------------------------------------------------------------------------
log "Setting up DefectDojo on port $DD_PORT..."
mkdir -p "$LAB_DIR"
if [ ! -d "$LAB_DIR/defectdojo" ]; then
    git clone --depth=1 https://github.com/DefectDojo/django-DefectDojo \
        "$LAB_DIR/defectdojo"
fi
cat > "$LAB_DIR/defectdojo/.env" << EOF
DD_PORT=${DD_PORT}
EOF
cd "$LAB_DIR/defectdojo"
docker compose up -d --remove-orphans 2>&1 | tail -5
cd "$SCRIPT_DIR"

DD_PASS=$(cd "$LAB_DIR/defectdojo" && \
    docker compose logs initializer 2>/dev/null | grep -i "admin password" | tail -1 \
    || echo "(run: cd $LAB_DIR/defectdojo && docker compose logs initializer | grep -i password)")

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  DevSecOps Lab — Ready"
echo "================================================================"
echo ""
echo "  Jenkins    : http://localhost:8090   admin / superman"
echo "  Gitea      : http://localhost:3100   admin / superman"
echo "  DefectDojo : http://localhost:${DD_PORT}   admin / (see below)"
echo ""
echo "  DefectDojo password: ${DD_PASS}"
echo ""
echo "  Gitea repo : http://localhost:3100/admin/vulnerable-app"
echo ""
echo "  Jenkins jobs:"
echo "    Jenkins-SAST : http://localhost:8090/job/Jenkins-SAST/"
echo "    Jenkins-DAST : http://localhost:8090/job/Jenkins-DAST/"
echo ""
echo "  Webhook: git push → Gitea → Jenkins-SAST (auto-triggered)"
echo ""
echo "  Note: DefectDojo takes 3-5 min to fully initialise."
echo "================================================================"
