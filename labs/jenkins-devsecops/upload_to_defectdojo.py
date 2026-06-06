#!/usr/bin/env python3
"""
upload_to_defectdojo.py — push scanner output to a DefectDojo engagement via API v2.

Usage example:
  python3 upload_to_defectdojo.py \
    --host localhost:8181 \
    --token <api-v2-token> \
    --engagement_id 1 \
    --lead_id 1 \
    --product_id 1 \
    --scan_type "Bandit Scan" \
    --result_file bandit-results.json \
    --environment Development
"""

import argparse
from datetime import datetime
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

SUPPORTED_SCAN_TYPES = [
    "Bandit Scan",
    "ZAP Scan",
    "Trivy Scan",
    "Grype Scan",
]


def push_scan_results(
    dd_host,
    token,
    scan_type,
    result_file,
    engagement_id,
    lead_id,
    environment,
    verify_tls=False,
):
    base_url = f"https://{dd_host}/api/v2"
    import_url = f"{base_url}/import-scan/"

    headers = {"Authorization": f"Token {token}"}

    payload = {
        "minimum_severity": "Low",
        "scan_date": datetime.now().strftime("%Y-%m-%d"),
        "verified": False,
        "active": False,
        "engagement": engagement_id,
        "lead": lead_id,
        "scan_type": scan_type,
        "environment": environment,
    }

    with open(result_file) as f:
        files = {"file": f}
        resp = requests.post(
            import_url,
            headers=headers,
            files=files,
            data=payload,
            verify=verify_tls,
        )

    return resp.status_code


def main():
    parser = argparse.ArgumentParser(
        description="Upload scanner results to DefectDojo (API v2)"
    )
    parser.add_argument("--host",        required=True,  help="DefectDojo host:port (e.g. localhost:8181)")
    parser.add_argument("--token",       required=True,  help="DefectDojo API v2 token")
    parser.add_argument("--engagement_id", required=True, help="Engagement ID in DefectDojo")
    parser.add_argument("--product_id",  required=True,  help="Product ID in DefectDojo")
    parser.add_argument("--lead_id",     required=True,  help="User ID running the test")
    parser.add_argument("--scan_type",   required=True,  help=f"Scanner type. Supported: {SUPPORTED_SCAN_TYPES}")
    parser.add_argument("--result_file", required=True,  help="Path to scanner output file")
    parser.add_argument("--environment", required=True,  help="Environment label (e.g. Development, Staging)")
    parser.add_argument("--build_id",    required=False, help="CI build reference (optional)")

    args = parser.parse_args()

    print(f"Uploading {args.result_file} ({args.scan_type}) to DefectDojo at {args.host}...")
    status = push_scan_results(
        dd_host=args.host,
        token=args.token,
        scan_type=args.scan_type,
        result_file=args.result_file,
        engagement_id=args.engagement_id,
        lead_id=args.lead_id,
        environment=args.environment,
    )

    if status == 201:
        print("Upload successful — check DefectDojo for findings.")
    else:
        print(f"Upload failed with status {status}. Check token, engagement ID, and scan type.")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
