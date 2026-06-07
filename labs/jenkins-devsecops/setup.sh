#!/bin/bash
# DevSecOps Lab — docker-compose setup: Jenkins + GitLab + DefectDojo
# Configures webhooks, Jenkins jobs, and GitLab project automatically.
#
# Usage:
#   cd ~/practical-security-engineering-app
#   bash labs/jenkins-devsecops/setup.sh
#
# Credentials after setup:
#   Jenkins    : admin / superman          (http://localhost:8080)
#   GitLab     : root  / Supercomplex@123# (http://localhost:8929)
#   DefectDojo : admin / see end of output (http://localhost:8181)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAB_DIR="$HOME/devsecops-lab"
JENKINS_URL="http://localhost:8080"
GITLAB_URL="http://localhost:8929"
DD_PORT=8181
WEBHOOK_SECRET="lab-hook-2024"
JENKINS_USER="admin"
JENKINS_PASS="superman"
GITLAB_USER="root"
GITLAB_PASS="Supercomplex@123#"

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------
log()  { echo "==> $*"; }
wait_http() {
    local url="$1" label="$2" timeout="${3:-600}" start elapsed
    start=$(date +%s)
    printf "Waiting for %s " "$label"
    until curl -sf -o /dev/null "$url" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start ))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo " TIMEOUT after ${elapsed}s"; return 1
        fi
        sleep 5; printf "."
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
# Remove volumes so init scripts run fresh
docker volume rm jenkins-devsecops_jenkins_data \
    jenkins-devsecops_gitlab_config \
    jenkins-devsecops_gitlab_logs \
    jenkins-devsecops_gitlab_data 2>/dev/null || true

# Stop previous DefectDojo if running
if [ -d "$LAB_DIR/defectdojo" ]; then
    log "Stopping previous DefectDojo stack..."
    cd "$LAB_DIR/defectdojo" && docker compose down --remove-orphans 2>/dev/null || true
    cd "$SCRIPT_DIR"
fi

mkdir -p "$LAB_DIR"

# -------------------------------------------------------------------------
# Build and start Jenkins + GitLab
# -------------------------------------------------------------------------
log "Building Jenkins image and starting stack (this takes a few minutes)..."
cd "$SCRIPT_DIR"
docker compose build --progress=plain 2>&1 | grep -E "^(Step|#|DONE|ERROR|---)" | head -60 || true
docker compose up -d

# -------------------------------------------------------------------------
# Wait for Jenkins
# -------------------------------------------------------------------------
log "Waiting for Jenkins to initialise (~60s)..."
wait_http "$JENKINS_URL/login" "Jenkins" 180

# Verify admin/superman works
log "Verifying Jenkins credentials..."
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -u "$JENKINS_USER:$JENKINS_PASS" \
    "$JENKINS_URL/api/json")
if [ "$HTTP" != "200" ]; then
    echo "ERROR: Jenkins auth failed (HTTP $HTTP). Check container logs:"; \
    docker logs lab-jenkins 2>&1 | tail -20; exit 1
fi
log "Jenkins OK — admin/superman authenticated"

# -------------------------------------------------------------------------
# Generate Jenkins API token (no CSRF needed for subsequent calls)
# -------------------------------------------------------------------------
log "Generating Jenkins API token..."
# Obtain a session cookie and crumb together (same HTTP session)
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
# All subsequent Jenkins API calls use admin:JENKINS_API_TOKEN — no crumb needed

# -------------------------------------------------------------------------
# Wait for GitLab
# -------------------------------------------------------------------------
log "Waiting for GitLab to become ready (5-10 minutes on first start)..."
wait_http "$GITLAB_URL/users/sign_in" "GitLab" 900

# -------------------------------------------------------------------------
# Create GitLab root user + API token via rails runner
# -------------------------------------------------------------------------
log "Creating GitLab root user and API token..."
cat > /tmp/gitlab_setup.rb << 'RUBYEOF'
begin
  # Disable breached/complexity password checks for lab
  settings = ApplicationSetting.first_or_create
  settings.update_columns(
    password_number_required: false,
    password_symbol_required: false,
    password_lowercase_required: false,
    password_uppercase_required: false
  )
rescue => e
  puts "settings: #{e.message}"
end

unless User.find_by_username('root')
  org = (Organizations::Organization.first_or_create!(name: 'Default', path: 'default') rescue nil)
  u = User.new
  u.username = 'root'
  u.name = 'Administrator'
  u.email = 'admin@example.com'
  u.password = 'Supercomplex@123#'
  u.password_confirmation = 'Supercomplex@123#'
  u.admin = true
  u.skip_confirmation!
  u.build_namespace(path: 'root', name: 'root')
  u.namespace.organization = org if org
  u.save(validate: false)
end

u = User.find_by_username('root')
u.personal_access_tokens.where(name: 'lab-setup').delete_all
t = u.personal_access_tokens.create!(
  name: 'lab-setup',
  scopes: ['api', 'write_repository'],
  expires_at: 30.days.from_now
)
puts t.token
RUBYEOF

docker cp /tmp/gitlab_setup.rb lab-gitlab:/tmp/gitlab_setup.rb
GITLAB_TOKEN=$(docker exec lab-gitlab gitlab-rails runner /tmp/gitlab_setup.rb 2>&1 | \
    grep -E '^glpat-' | tail -1)

if [ -z "$GITLAB_TOKEN" ]; then
    echo "ERROR: Failed to create GitLab token. Runner output:"
    docker exec lab-gitlab gitlab-rails runner /tmp/gitlab_setup.rb 2>&1 | tail -15
    exit 1
fi
log "GitLab token: ${GITLAB_TOKEN:0:10}..."

# Allow webhook calls to internal/private network addresses (Jenkins is on same Docker network)
curl -s -X PUT "$GITLAB_URL/api/v4/application/settings" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"allow_local_requests_from_web_hooks_and_services":true}' > /dev/null
log "GitLab local webhook requests enabled"

# -------------------------------------------------------------------------
# Create GitLab project
# -------------------------------------------------------------------------
log "Creating GitLab project 'vulnerable-app'..."
# Delete existing project first if it exists
EXISTING=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_URL/api/v4/projects/root%2Fvulnerable-app" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
    log "Deleting existing project (id=$EXISTING)..."
    curl -s -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$EXISTING" > /dev/null
    sleep 5
fi

CREATE_RESP=$(curl -s -X POST "$GITLAB_URL/api/v4/projects" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"vulnerable-app","path":"vulnerable-app","visibility":"public","initialize_with_readme":false}')

PROJECT_ID=$(echo "$CREATE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)
if [ -z "$PROJECT_ID" ]; then
    echo "ERROR: GitLab project creation failed"
    echo "$CREATE_RESP"
    exit 1
fi
log "GitLab project created — id=$PROJECT_ID"

# -------------------------------------------------------------------------
# Push repo to GitLab
# -------------------------------------------------------------------------
log "Pushing practical-security-engineering-app to GitLab..."
cd "$REPO_ROOT"
git remote remove gitlab 2>/dev/null || true
git remote add gitlab "http://root:${GITLAB_TOKEN}@localhost:8929/root/vulnerable-app.git"

# Get current branch name
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
git push --force gitlab "${CURRENT_BRANCH}:main"
log "Code pushed to GitLab (branch: main)"

git remote remove gitlab 2>/dev/null || true
cd "$SCRIPT_DIR"

# -------------------------------------------------------------------------
# Add GitLab credentials to Jenkins
# -------------------------------------------------------------------------
log "Adding GitLab credentials to Jenkins..."
curl -s -o /dev/null \
    -X POST "$JENKINS_URL/credentials/store/system/domain/_/createCredentials" \
    -u "$JENKINS_USER:$JENKINS_API_TOKEN" \
    -H "Content-Type: application/xml" \
    -d "<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
          <scope>GLOBAL</scope>
          <id>gitlab-root</id>
          <username>root</username>
          <password>${GITLAB_TOKEN}</password>
          <description>GitLab root API token</description>
        </com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>"
log "Credentials 'gitlab-root' added"

# -------------------------------------------------------------------------
# Create Jenkins-SAST freestyle job
# -------------------------------------------------------------------------
log "Creating Jenkins-SAST freestyle job..."
cat > /tmp/jenkins-sast-job.xml <<XMLEOF
<?xml version='1.1' encoding='UTF-8'?>
<project>
  <description>SAST scan with bandit against the vulnerable Python app</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class="hudson.plugins.git.GitSCM" plugin="git">
    <configVersion>2</configVersion>
    <userRemoteConfigs>
      <hudson.plugins.git.UserRemoteConfig>
        <url>http://gitlab/root/vulnerable-app.git</url>
        <credentialsId>gitlab-root</credentialsId>
      </hudson.plugins.git.UserRemoteConfig>
    </userRemoteConfigs>
    <branches>
      <hudson.plugins.git.BranchSpec>
        <name>*/main</name>
      </hudson.plugins.git.BranchSpec>
    </branches>
    <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
    <submoduleCfg class="empty-list"/>
    <extensions/>
  </scm>
  <canRoam>true</canRoam>
  <disabled>false</disabled>
  <blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding>
  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>
  <triggers>
    <com.dabsquared.gitlabjenkins.GitLabPushTrigger plugin="gitlab-plugin">
      <spec></spec>
      <triggerOnPush>true</triggerOnPush>
      <triggerOnMergeRequest>true</triggerOnMergeRequest>
      <triggerOnlyIfNewCommitsPushed>false</triggerOnlyIfNewCommitsPushed>
      <triggerOnPipelineEvent>false</triggerOnPipelineEvent>
      <triggerOnAcceptedMergeRequest>false</triggerOnAcceptedMergeRequest>
      <triggerOnClosedMergeRequest>false</triggerOnClosedMergeRequest>
      <triggerOnApprovedMergeRequest>true</triggerOnApprovedMergeRequest>
      <triggerOpenMergeRequestOnPush>never</triggerOpenMergeRequestOnPush>
      <triggerOnNoteRequest>true</triggerOnNoteRequest>
      <noteRegex>Jenkins please retry a build</noteRegex>
      <ciSkip>true</ciSkip>
      <skipWorkInProgressMergeRequest>true</skipWorkInProgressMergeRequest>
      <setBuildDescription>true</setBuildDescription>
      <branchFilterType>All</branchFilterType>
      <includeBranchesSpec></includeBranchesSpec>
      <excludeBranchesSpec></excludeBranchesSpec>
      <sourceBranchRegex></sourceBranchRegex>
      <targetBranchRegex></targetBranchRegex>
      <secretToken>${WEBHOOK_SECRET}</secretToken>
      <cancelPendingBuildsOnUpdate>false</cancelPendingBuildsOnUpdate>
    </com.dabsquared.gitlabjenkins.GitLabPushTrigger>
  </triggers>
  <concurrentBuild>false</concurrentBuild>
  <builders>
    <hudson.tasks.Shell>
      <command>bash labs/jenkins-devsecops/sast-pipeline.sh</command>
    </hudson.tasks.Shell>
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
log "Jenkins-SAST job create: HTTP $HTTP"

# -------------------------------------------------------------------------
# Create Jenkins-DAST freestyle job
# -------------------------------------------------------------------------
log "Creating Jenkins-DAST freestyle job..."
cat > /tmp/jenkins-dast-job.xml <<XMLEOF
<?xml version='1.1' encoding='UTF-8'?>
<project>
  <description>DAST scan with ZAP against the vulnerable Python app</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class="hudson.plugins.git.GitSCM" plugin="git">
    <configVersion>2</configVersion>
    <userRemoteConfigs>
      <hudson.plugins.git.UserRemoteConfig>
        <url>http://gitlab/root/vulnerable-app.git</url>
        <credentialsId>gitlab-root</credentialsId>
      </hudson.plugins.git.UserRemoteConfig>
    </userRemoteConfigs>
    <branches>
      <hudson.plugins.git.BranchSpec>
        <name>*/main</name>
      </hudson.plugins.git.BranchSpec>
    </branches>
    <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
    <submoduleCfg class="empty-list"/>
    <extensions/>
  </scm>
  <canRoam>true</canRoam>
  <disabled>false</disabled>
  <blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding>
  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>
  <triggers/>
  <concurrentBuild>false</concurrentBuild>
  <builders>
    <hudson.tasks.Shell>
      <command>bash labs/jenkins-devsecops/dast-pipeline.sh</command>
    </hudson.tasks.Shell>
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
log "Jenkins-DAST job create: HTTP $HTTP"

# -------------------------------------------------------------------------
# Create GitLab webhook → Jenkins-SAST
# GitLab rejects hostnames for internal addresses — use container IP directly
# -------------------------------------------------------------------------
log "Creating GitLab webhook → Jenkins..."
JENKINS_IP=$(docker inspect lab-jenkins --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
log "Jenkins container IP: $JENKINS_IP"
HOOK_RESP=$(curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/hooks" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"url\": \"http://${JENKINS_IP}:8080/project/Jenkins-SAST\",
        \"push_events\": true,
        \"merge_requests_events\": true,
        \"enable_ssl_verification\": false,
        \"token\": \"${WEBHOOK_SECRET}\"
    }")
HOOK_ID=$(echo "$HOOK_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id','?'))" 2>/dev/null || true)
log "GitLab webhook created — id=$HOOK_ID → http://${JENKINS_IP}:8080/project/Jenkins-SAST"

# -------------------------------------------------------------------------
# Start DefectDojo
# -------------------------------------------------------------------------
log "Setting up DefectDojo on port $DD_PORT..."
if [ ! -d "$LAB_DIR/defectdojo" ]; then
    git clone --depth=1 https://github.com/DefectDojo/django-DefectDojo \
        "$LAB_DIR/defectdojo"
fi

cat > "$LAB_DIR/defectdojo/.env" <<EOF
DD_PORT=${DD_PORT}
EOF

cd "$LAB_DIR/defectdojo"
docker compose up -d --remove-orphans 2>&1 | tail -5
cd "$SCRIPT_DIR"

# -------------------------------------------------------------------------
# Verify: trigger a test build in Jenkins-SAST
# -------------------------------------------------------------------------
log "Triggering initial Jenkins-SAST build to verify the pipeline..."
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$JENKINS_URL/job/Jenkins-SAST/build" \
    -u "$JENKINS_USER:$JENKINS_API_TOKEN")
log "Initial build triggered: HTTP $HTTP (201=queued)"

# -------------------------------------------------------------------------
# Verify: check webhook responds
# -------------------------------------------------------------------------
log "Testing webhook endpoint (expect HTTP 200)..."
WH_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://localhost:8080/project/Jenkins-SAST" \
    -H "X-Gitlab-Token: ${WEBHOOK_SECRET}" \
    -H "X-Gitlab-Event: Push Hook" \
    -H "Content-Type: application/json" \
    -d '{"object_kind":"push","ref":"refs/heads/main","checkout_sha":"abc123"}')
log "Webhook endpoint test: HTTP $WH_HTTP"

# Get DefectDojo admin password
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
echo "  Jenkins    : http://localhost:8080   admin / superman"
echo "  GitLab     : http://localhost:8929   root  / Supercomplex@123#"
echo "  DefectDojo : http://localhost:${DD_PORT}   admin / (see below)"
echo ""
echo "  DefectDojo admin password: ${DD_PASS}"
echo ""
echo "  GitLab project : http://localhost:8929/root/vulnerable-app"
echo "  Webhook secret : ${WEBHOOK_SECRET}"
echo ""
echo "  Jenkins jobs:"
echo "    Jenkins-SAST : http://localhost:8080/job/Jenkins-SAST/"
echo "    Jenkins-DAST : http://localhost:8080/job/Jenkins-DAST/"
echo ""
echo "  Webhook flow:"
echo "    git push → GitLab → Jenkins-SAST (auto-triggered)"
echo ""
echo "  Note: DefectDojo takes 3-5 min to fully start."
echo "        Check: cd $LAB_DIR/defectdojo && docker compose ps"
echo "================================================================"
