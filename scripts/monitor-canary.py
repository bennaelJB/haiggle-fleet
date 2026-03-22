#!/usr/bin/env python3
"""
monitor-canary.py
Poll Prometheus for the canary schools' HTTP 5xx error rate.
Exits with code 1 if the error rate exceeds the threshold at any poll.

Usage:
    python3 scripts/monitor-canary.py \\
        --prometheus-url https://prometheus.internal \\
        --duration-minutes 30 \\
        --poll-interval 60 \\
        --error-threshold 0.02
"""

import argparse
import os
import sys
import time
import urllib.request
import urllib.parse
import json

def query_prometheus(base_url: str, promql: str, token: str | None) -> float:
    """Run an instant PromQL query and return the first scalar result."""
    params = urllib.parse.urlencode({"query": promql})
    url = f"{base_url}/api/v1/query?{params}"
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())

    results = data.get("data", {}).get("result", [])
    if not results:
        return 0.0

    return float(results[0]["value"][1])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prometheus-url", required=True)
    parser.add_argument("--duration-minutes", type=int, default=30)
    parser.add_argument("--poll-interval", type=int, default=60)
    parser.add_argument("--error-threshold", type=float, default=0.02)
    args = parser.parse_args()

    token = os.environ.get("PROMETHEUS_TOKEN")
    end_time = time.time() + (args.duration_minutes * 60)
    poll_count = 0

    # PromQL: ratio of 5xx responses to total responses for canary schools
    # Assumes haiggle-app metrics are labelled with deploy_group="canary"
    error_rate_query = (
        'sum(rate(http_requests_total{deploy_group="canary", status=~"5.."}[5m])) / '
        'sum(rate(http_requests_total{deploy_group="canary"}[5m]))'
    )

    print(f"Monitoring canary for {args.duration_minutes} minutes "
          f"(threshold={args.error_threshold * 100:.1f}%, poll every {args.poll_interval}s)")

    while time.time() < end_time:
        poll_count += 1
        remaining = int(end_time - time.time())

        try:
            error_rate = query_prometheus(args.prometheus_url, error_rate_query, token)
        except Exception as exc:
            print(f"[Poll {poll_count}] WARNING: Prometheus query failed: {exc}")
            time.sleep(args.poll_interval)
            continue

        status = "OK" if error_rate <= args.error_threshold else "FAIL"
        print(f"[Poll {poll_count}] error_rate={error_rate:.4f} ({error_rate*100:.2f}%) "
              f"threshold={args.error_threshold*100:.1f}% → {status} | {remaining}s remaining")

        if error_rate > args.error_threshold:
            print(f"\n[FAIL] Canary error rate {error_rate*100:.2f}% exceeds threshold "
                  f"{args.error_threshold*100:.1f}% — aborting deploy")
            sys.exit(1)

        time.sleep(args.poll_interval)

    print(f"\n[PASS] Canary monitoring complete after {poll_count} polls — error rate within threshold")


if __name__ == "__main__":
    main()
