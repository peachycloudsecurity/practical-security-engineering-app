#!/bin/bash
# SAST pipeline — paste this into Jenkins freestyle job > Execute shell
# Runs bandit against the lab Python app and writes JSON + HTML reports.
# Jenkins has already checked out the repo; WORKSPACE is set automatically.

set -uo pipefail

TARGET="labs/github-actions-devsecops"
JSON_OUT="$WORKSPACE/bandit-results.json"
HTML_OUT="$WORKSPACE/bandit-results.html"

echo "--- Installing bandit ---"
pip install bandit --quiet --break-system-packages

echo "--- Running SAST scan on $TARGET ---"
python3 -m bandit -r "$TARGET" -f json  -o "$JSON_OUT"  || true
python3 -m bandit -r "$TARGET" -f html  -o "$HTML_OUT"  || true

echo "--- Finding summary ---"
python3 - <<'EOF'
import json, sys
try:
    with open("bandit-results.json") as f:
        data = json.load(f)
    metrics = data.get("metrics", {}).get("_totals", {})
    print(f"  HIGH:   {metrics.get('SEVERITY.HIGH', 0)}")
    print(f"  MEDIUM: {metrics.get('SEVERITY.MEDIUM', 0)}")
    print(f"  LOW:    {metrics.get('SEVERITY.LOW', 0)}")
    issues = data.get("results", [])
    print(f"  Total issues: {len(issues)}")
except Exception as e:
    print(f"  Could not parse results: {e}")
EOF

echo "--- Done. Artifacts: bandit-results.json, bandit-results.html ---"
