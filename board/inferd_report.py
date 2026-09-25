#!/usr/bin/env python3
"""Post this host's nn-inferd stats to the hub.

The hub reads stats.json directly when the daemon shares its filesystem;
hosts that do not (the BeagleY serves its own camera from the C7x) report
in over HTTP instead, so one Settings page shows every accelerator.

Failures are never fatal: this is telemetry, and a hub that is down must
not take a reporter with it.
"""
import json
import os
import socket
import sys
import time
import urllib.request

STATS = os.environ.get("NN_INFERD_STATS", "/run/nn-inferd/stats.json")
HUB = os.environ.get("NN_HUB_URL", "").rstrip("/")
PERIOD = int(os.environ.get("NN_REPORT_PERIOD_S", "30"))
HOST = os.environ.get("NN_REPORT_HOST") or socket.gethostname()


def once():
    with open(STATS) as f:
        doc = json.load(f)
    doc["host"] = HOST
    req = urllib.request.Request(
        HUB + "/api/v1/inferd/stats",
        data=json.dumps(doc).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status


def main():
    if not HUB:
        print("NN_HUB_URL unset", file=sys.stderr)
        return 2
    fails = 0
    while True:
        try:
            once()
            fails = 0
        except Exception as e:                      # noqa: BLE001 - telemetry
            fails += 1
            if fails in (1, 10) or fails % 100 == 0:
                print(f"report failed ({fails}): {e}", file=sys.stderr,
                      flush=True)
        time.sleep(PERIOD)


if __name__ == "__main__":
    sys.exit(main())
