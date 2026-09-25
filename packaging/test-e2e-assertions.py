#!/usr/bin/env python3
"""Test the E2E's own assertions by faking the broken states they exist to catch.

An assertion nobody has watched fail is not a test, it is decoration.  Five
checks in e2e-camera.py could not fail (or failed wrongly) and shipped green
for weeks while the detector had never detected anything; these cases pin the
fixes so they cannot rot back.

Run: python3 packaging/test-e2e-assertions.py
"""
import importlib.util, os, sys, types

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("NN_E2E_HUB", "http://e2e.invalid/api/v1")
os.environ.setdefault("NN_E2E_CAM", "cam3")
os.environ.setdefault("NN_E2E_ADDR", "AA:BB:CC:DD:EE:FF")

spec = importlib.util.spec_from_file_location("e2ecam", os.path.join(HERE, "e2e-camera.py"))
E = importlib.util.module_from_spec(spec)
spec.loader.exec_module(E)

fails = []


class FakeClock:
    """e2e-camera's wait() loops on the real wall clock, so stubbing sleep()
    alone makes the tests spin for the full 240 s timeout.  Advance a fake
    clock from sleep() instead: the stage logic is unchanged, it just runs in
    milliseconds."""
    def __init__(self):
        self.t = 1_700_000_000.0
        self.real = __import__("time")
    def time(self):
        self.t += 0.01
        return self.t
    def sleep(self, n):
        self.t += max(float(n), 0.5)
    def strftime(self, *a, **k):
        return self.real.strftime(*a, **k)


def case(name, ok, detail=""):
    print("  %s  %s%s" % ("ok  " if ok else "FAIL", name, ("  -- " + detail) if detail else ""))
    if not ok:
        fails.append(name)


def run_stage(stage, responses, argv=()):
    """Run a stage with `http` stubbed by a path->(status, body) callable."""
    E.results.clear(); E.warnings.clear()
    old_http, old_argv, old_time = E.http, sys.argv, E.time
    E.http = responses
    sys.argv = ["e2e"] + list(argv)
    E.time = FakeClock()
    try:
        stage("t")
    finally:
        E.http, sys.argv, E.time = old_http, old_argv, old_time
    return {n: ok for n, ok, _ in E.results}


def named(res, needle):
    hit = [v for k, v in res.items() if needle in k]
    return hit[0] if hit else None


JPEG_A = b"\xff\xd8\xff" + b"A" * 900
JPEG_B = b"\xff\xd8\xff" + b"B" * 900


def streaming_responses(stale, seqs, snaps):
    """seqs: successive MEDIA-SEQUENCE values; snaps: successive snapshot bodies."""
    seq_it, snap_it = iter(seqs), iter(snaps)

    def http(method, path, body=None, timeout=30):
        if path == "/cameras":
            return 200, [{"id": "cam3", "streaming": True, "video_stale_s": stale}]
        if path.endswith("live.m3u8"):
            try:
                v = next(seq_it)
            except StopIteration:
                v = seqs[-1]
            if v is None:
                return 404, b""
            return 200, ("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:%d\n" % v).encode()
        if path.endswith("snapshot.jpg"):
            try:
                return 200, next(snap_it)
            except StopIteration:
                return 200, snaps[-1]
        return 404, b""
    return http


print("F1  video_stale_s == 0 is the BEST reading and must PASS")
r = run_stage(E.stage_streaming, streaming_responses(0, [5, 6], [JPEG_A, JPEG_B]))
case("stale=0 passes (was: 0 -> falsy -> 99 -> FAIL)", named(r, "video is fresh") is True)

print("F1b missing video_stale_s must FAIL")
def no_stale(method, path, body=None, timeout=30):
    if path == "/cameras":
        return 200, [{"id": "cam3", "streaming": True}]
    return streaming_responses(0, [5, 6], [JPEG_A, JPEG_B])(method, path, body, timeout)
r = run_stage(E.stage_streaming, no_stale)
case("absent stale fails", named(r, "video is fresh") is False)

print("F2  a playlist that APPEARS and then freezes must FAIL")
# first read absent, then a constant sequence forever
r = run_stage(E.stage_streaming, streaming_responses(1, [None] + [7] * 60, [JPEG_A, JPEG_B]))
case("appeared-then-frozen fails (was: any value passed when baseline None)",
     named(r, "media-sequence advances") is False)

print("F2b a genuinely advancing playlist must PASS")
r = run_stage(E.stage_streaming, streaming_responses(1, [None, 7, 8], [JPEG_A, JPEG_B]))
case("advancing passes", named(r, "media-sequence advances") is True)

print("F3  a snapshot endpoint that NEVER changes must FAIL")
# The hub serves a periodically refreshed cache (12-30 s), so the check polls;
# a frozen endpoint returns the same bytes forever.
r = run_stage(E.stage_streaming, streaming_responses(1, [5, 6], [JPEG_A] * 40))
case("never-changing snapshot fails", named(r, "snapshot refreshes") is False)
case("...while the JPEG-magic check still passes (so only the new one catches it)",
     named(r, "snapshot is a JPEG") is True)

print("F3b a snapshot that changes on a SLOW cadence must PASS (not just a 4 s sample)")
# identical for the first few polls, then different -- the real behaviour that
# a fixed 4 s interval wrongly failed
r = run_stage(E.stage_streaming, streaming_responses(1, [5, 6], [JPEG_A] * 4 + [JPEG_B] * 10))
case("slow-but-live snapshot passes", named(r, "snapshot refreshes") is True)

print("F4  a device reporting NO self-test must FAIL")
def dev_no_selftest(method, path, body=None, timeout=30):
    if path.endswith("/detections"):
        return 200, {"ts": int(1_700_000_000 * 1000), "detections": []}
    if path.endswith("/device"):
        return 200, {"settings": {"infer": {"model": "yolox_s_tidl", "w": 640, "h": 640}}}
    return 404, b""
r = run_stage(E.stage_inference, dev_no_selftest)
case("absent self-test fails (was: warn + PASS)", named(r, "self-test") is False)

print("F4b --allow-no-selftest tolerates it but WARNS")
r = run_stage(E.stage_inference, dev_no_selftest, argv=["--allow-no-selftest"])
case("escape hatch passes", named(r, "self-test") is None)
case("...and records a warning", any("NOT actually verified" in w for w in E.warnings))

print("F4c a self-test that found nothing must FAIL")
def dev_zero(method, path, body=None, timeout=30):
    if path.endswith("/detections"):
        return 200, {"ts": int(1_700_000_000 * 1000), "detections": []}
    if path.endswith("/device"):
        return 200, {"settings": {"infer": {"model": "m", "w": 640, "h": 640},
                                  "selftest": {"n": 0}}}
    return 404, b""
r = run_stage(E.stage_inference, dev_zero)
case("n=0 fails", named(r, "self-test") is False)

print("F4d a good self-test passes")
def dev_ok(method, path, body=None, timeout=30):
    if path.endswith("/detections"):
        return 200, {"ts": int(1_700_000_000 * 1000), "detections": []}
    if path.endswith("/device"):
        return 200, {"settings": {"infer": {"model": "m", "w": 640, "h": 640},
                                  "selftest": {"n": 3, "cls": 4, "conf": 849}}}
    return 404, b""
r = run_stage(E.stage_inference, dev_ok)
case("n=3 conf=849 passes", named(r, "self-test") is True)

print("F4e a self-test below the floor must FAIL")
def dev_low(method, path, body=None, timeout=30):
    if path.endswith("/detections"):
        return 200, {"ts": int(1_700_000_000 * 1000), "detections": []}
    if path.endswith("/device"):
        return 200, {"settings": {"infer": {"model": "m", "w": 640, "h": 640},
                                  "selftest": {"n": 2, "cls": 4, "conf": 120}}}
    return 404, b""
r = run_stage(E.stage_inference, dev_low)
case("conf below SELFTEST_MIN_CONF fails", named(r, "self-test") is False)

print("F5  an UNREACHABLE hub must not score 'camera stopped streaming'")
# Let the unregister SUCCEED, then take the hub away -- otherwise the stage
# returns early and never reaches the predicate under test.
def hub_dies_after_unregister(method, path, body=None, timeout=30):
    if path.endswith("/unregister"):
        return 200, {"ok": True, "cleared": True, "archived": "cam3@1"}
    return 0, "connection refused"        # /cameras and everything after
E.results.clear(); E.warnings.clear()
old_http, old_argv, old_time = E.http, sys.argv, E.time
E.http = hub_dies_after_unregister
sys.argv = ["e2e"]
E.time = FakeClock()
try:
    E.stage_lifecycle()
finally:
    E.http, sys.argv, E.time = old_http, old_argv, old_time
got = {n: ok for n, ok, _ in E.results}
case("the stop check was actually reached", named(got, "stopped streaming") is not None,
     "recorded: %s" % list(got))
case("dead hub FAILS the stop check (was: cam()==None -> PASS)",
     named(got, "stopped streaming") is False)


# ── G: the gateway stage must prove liveness from the hub's own records ──

def gateway_responses(report, gateways):
    def http(method, path, body=None, timeout=30):
        if path.endswith("/gateway"):
            return 200, report
        if path == "/gateways":
            return 200, gateways
        return 404, {}
    return http

NOW = FakeClock().time()
LIVE = {"id": "b25d", "name": "cam3-gw", "host_camera": E.CAM, "role_name": "router", "last_seen": NOW - 5}
STALE = {"id": "b25d", "name": "cam3-gw", "host_camera": E.CAM, "role_name": "router", "last_seen": NOW - 4000}
DETACHED = {"id": "b25d", "name": "cam3-gw", "host_camera": E.CAM, "role_name": "detached", "last_seen": NOW - 5}
DUP = {"id": "1643", "name": "cam3-gw", "host_camera": None, "role_name": "router", "last_seen": NOW - 9e5}
REPORTED = {"supported": True, "reason": "NCP detected: usb-Espressif", "enabled": True, "has_creds": True}

print("G1  no agent report at all must FAIL (the agent is not running)")
r = run_stage(E.stage_gateway, gateway_responses(
    {"supported": False, "reason": "no gateway report from the camera yet", "enabled": True}, [LIVE]))
case("no report -> FAIL", named(r, "gateway capability") is False)

print("G2  a live router hosted by this slot passes, and no duplicate")
r = run_stage(E.stage_gateway, gateway_responses(REPORTED, [LIVE]))
case("live gateway -> PASS", named(r, "live gateway") is True)
case("no duplicate -> PASS", named(r, "duplicate") is True)

print("G3  a gateway the hub has not heard from must FAIL, even with the right role")
r = run_stage(E.stage_gateway, gateway_responses(REPORTED, [STALE]))
case("stale last_seen -> FAIL", named(r, "live gateway") is False)

print("G4  a gateway that never attached (detached) must FAIL")
r = run_stage(E.stage_gateway, gateway_responses(REPORTED, [DETACHED]))
case("detached -> FAIL", named(r, "live gateway") is False)

print("G5  a second record with the same label is the duplicate-identity bug")
r = run_stage(E.stage_gateway, gateway_responses(REPORTED, [LIVE, DUP]))
case("duplicate record -> FAIL", named(r, "duplicate") is False)

print("G6  no NCP on the bench is a WARN, not a failure")
r = run_stage(E.stage_gateway, gateway_responses(
    {"supported": False, "reason": "no NCP detected", "enabled": True}, []))
case("no NCP -> no live check, warned", named(r, "live gateway") is None and len(E.warnings) == 1)

print("\n%d case(s) failed" % len(fails))
sys.exit(1 if fails else 0)
