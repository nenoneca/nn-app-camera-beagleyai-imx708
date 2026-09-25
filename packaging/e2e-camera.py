#!/usr/bin/env python3
"""End-to-end test for the BeagleY camera on the Buildroot image.

    e2e-camera.py [--skip-lifecycle]

Drives the REAL paths, through the hub's public API only:

  A. streaming      the hub sees live video from the slot (HLS media-sequence
                    ADVANCES -- ingest counters are not proof of video)
  B. inference      the device's edge engine reports: the hub's detection
                    timestamp advances at the device's rate ('D' records)
  C. lifecycle      unregister (CLEAR) -> the camera wipes itself, forgets
                    Wi-Fi and returns to BLE setup mode -> the hub's wizard
                    provisions it over BLE into the SAME slot -> it rejoins,
                    and A + B pass again with a NEW device identity

Wi-Fi credentials come from ~/.config/nn/wifi.env and are never printed.
"""
import json, os, re, sys, time, urllib.request, urllib.error

def _cfg():
    """Bench identifiers come from the environment, never from this file.

    A hub URL and a board's BLE MAC are deployment facts, and the standing
    rule here is no hardcoded endpoints in source -- this script is committed,
    so they live in ~/.config/nn/e2e.env (or the environment) alongside
    wifi.env, which is already how the Wi-Fi PSK is kept out of the tree.
    """
    env = dict(os.environ)
    p = os.path.expanduser(os.environ.get("NN_E2E_ENV", "~/.config/nn/e2e.env"))
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env.setdefault(k.strip(), v.strip())
    missing = [k for k in ("NN_E2E_HUB", "NN_E2E_CAM", "NN_E2E_ADDR") if not env.get(k)]
    if missing:
        sys.exit("e2e-camera: %s not set. Put them in %s (0600), e.g.\n"
                 "  NN_E2E_HUB=http://<hub-host>:8769/api/v1\n"
                 "  NN_E2E_CAM=cam3\n"
                 "  NN_E2E_ADDR=AA:BB:CC:DD:EE:FF\n"
                 "  NN_E2E_NAME=BeagleY Wide NoIR" % (", ".join(missing), p))
    return (env["NN_E2E_HUB"].rstrip("/"), env["NN_E2E_CAM"],
            env["NN_E2E_ADDR"].upper(), env.get("NN_E2E_NAME", env["NN_E2E_CAM"]))


HUB, CAM, ADDR, NAME = _cfg()
# Self-test floor, conf x1000.  The bundled reference frame scores 0.857 on the
# float reference (next best 0.640, 0.507), so 0.40 clears the noise floor by a
# wide margin while leaving room for C7x/TIDL quantisation to come out lower
# than host float.  Raise it only with measurements from the device.
SELFTEST_MIN_CONF = 400
results = []
warnings = []


def http(method, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(HUB + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw[:1] in b"{[" else raw)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode("utf-8", "replace")[:300]
    except Exception as e:
        return 0, str(e)


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print("  %s  %s%s" % ("PASS" if ok else "FAIL", name, ("  -- " + detail) if detail else ""), flush=True)
    return bool(ok)


def warn(msg):
    """A known-flaky or degraded observation that does not fail the run.

    Collected and REPRINTED in the summary: a WARN buried in 200 lines of
    output is a WARN nobody reads, and these are exactly the things whose
    frequency we want to track across repeated runs.
    """
    warnings.append(msg)
    print("  WARN  %s" % msg, flush=True)


def cam():
    st, cams = http("GET", "/cameras")
    if st != 200:
        return None
    return next((c for c in cams if c["id"] == CAM), None)


def wait(pred, timeout, every=5, what=""):
    t0 = time.time()
    while time.time() - t0 < timeout:
        v = pred()
        if v:
            return v, time.time() - t0
        time.sleep(every)
    return None, time.time() - t0


def media_sequence():
    st, body = http("GET", "/cameras/%s/hls/live.m3u8" % CAM, timeout=10)
    if st != 200:
        return None
    text = body.decode() if isinstance(body, bytes) else str(body)
    m = re.search(r"#EXT-X-MEDIA-SEQUENCE:(\d+)", text)
    return int(m.group(1)) if m else None


def stage_streaming(tag):
    print("== %s: streaming ==" % tag, flush=True)
    c, dt = wait(lambda: (lambda x: x if x and x.get("streaming") else None)(cam()), 240, what="streaming")
    check("%s: hub reports the slot streaming" % tag, c, "after %.0f s" % dt)
    if not c:
        return False
    # NOT `(x or 99) < 15`: a perfectly fresh video_stale_s of 0 is falsy and
    # became 99, failing on the best possible reading.  Absent stays a failure.
    vs = c.get("video_stale_s")
    check("%s: video is fresh" % tag, isinstance(vs, (int, float)) and vs < 15,
          "video_stale_s=%s" % vs)
    # Wait for an ADVANCE rather than sampling a fixed 20 s window: right
    # after a (re)start the playlist sits at sequence 0 until its window
    # fills, and a fixed sample there reads "0 -> 0" on perfectly good video.
    a = media_sequence()
    # 200 s, not 90: after a camera REBOOT the hub's HLS branch can stall until
    # its own watchdog (120 s, exit 42) restarts the video service, and the
    # playlist is briefly absent across that restart.  That is a hub-side
    # recovery cost, not a camera fault -- so tolerate it, but SAY so: a slow
    # advance is reported, never silently absorbed.
    # The baseline may be absent (no playlist yet).  Re-baseline in that case
    # instead of treating "a playlist appeared" as an advance: with `a is None`
    # the old condition was satisfied by ANY value, so a playlist that appeared
    # and then froze passed this check.
    state = {"a": a}
    def advanced():
        b = media_sequence()
        if b is None:
            return None
        if state["a"] is None:
            state["a"] = b
            return None
        return b if b != state["a"] else None
    adv, dt = wait(advanced, 200, every=5)
    a = state["a"]
    ok = check("%s: HLS media-sequence advances" % tag, adv is not None, "%s -> %s after %.0f s" % (a, adv, dt))
    if ok and dt > 30:
        warn("HLS took %.0f s to advance -- the hub's HLS watchdog restart "
             "window (hub-side)" % dt)
    st, jpg = http("GET", "/cameras/%s/snapshot.jpg" % CAM, timeout=15)
    isjpg = st == 200 and isinstance(jpg, bytes) and jpg[:3] == b"\xff\xd8\xff"
    check("%s: snapshot is a JPEG" % tag, isjpg,
          "%s bytes" % (len(jpg) if isinstance(jpg, bytes) else 0))
    # Magic bytes alone cannot fail for a FROZEN endpoint: a stale frame is
    # still a valid JPEG.  So require the bytes to CHANGE -- but poll for it
    # instead of sampling a fixed interval: the hub serves a periodically
    # refreshed cache, not a live grab, measured at 12-30 s between changes
    # (median ~22 s).  A fixed 4 s sample failed on a perfectly healthy camera.
    # The endpoint also 502s occasionally (2 in 40 requests), so a transient
    # non-200 keeps polling and is reported rather than failing the run.
    if isjpg:
        t0, errs, jpg2 = time.time(), 0, None
        while time.time() - t0 < 75:
            time.sleep(5)
            st2, b = http("GET", "/cameras/%s/snapshot.jpg" % CAM, timeout=15)
            if st2 != 200 or not isinstance(b, bytes) or b[:3] != b"\xff\xd8\xff":
                errs += 1
                continue
            if b != jpg:
                jpg2 = b
                break
        dt = time.time() - t0
        check("%s: snapshot refreshes (bytes change)" % tag, jpg2 is not None,
              "after %.0f s%s" % (dt, "" if jpg2 is not None
                                  else " -- unchanged for 75 s: frozen endpoint"))
        if errs:
            warn("snapshot endpoint returned %d transient error(s) while polling "
                 "(hub-side; seen ~5%% of requests)" % errs)
    return ok


def stage_inference(tag):
    """Prove the DEVICE's edge engine actually infers.

    The timestamp checks below are necessary but NOT sufficient, and on their
    own they are close to worthless: /detections is the media-host's view of
    its own event engine, whose ts advances from motion processing alone, and
    the device emits a 'D' record every cycle even when it detected nothing.
    So a camera with a dead detector, a camera with NO model installed and a
    camera aimed at a blank wall all passed this stage identically -- which is
    exactly what happened until 2026-09-18.

    The load-bearing check is the detector self-test: the device runs a
    reference frame with a known answer through the real C7x engine at
    startup and publishes the result.  That is the only assertion here that
    fails when inference breaks."""
    print("== %s: edge inference ==" % tag, flush=True)
    def ts():
        st, d = http("GET", "/cameras/%s/detections" % CAM, timeout=10)
        return d.get("ts") if st == 200 and isinstance(d, dict) else None
    seen = []
    for _ in range(6):
        seen.append(ts()); time.sleep(3)
    vals = [v for v in seen if v]
    adv = len(set(vals)) >= 3 and vals[-1] > vals[0]
    fresh = bool(vals) and abs(time.time() * 1000 - vals[-1]) < 30000
    check("%s: device detection records arrive (timestamp advances)" % tag, adv, "%d distinct in 18 s" % len(set(vals)))
    check("%s: detection timestamp is current" % tag, fresh, "age %.1f s" % ((time.time() * 1000 - vals[-1]) / 1000 if vals else -1))

    # --- the real check: the device's own report of its engine -------------
    st, dev = http("GET", "/cameras/%s/device" % CAM, timeout=10)
    dev = dev if isinstance(dev, dict) else {}
    settings = dev.get("settings") or {}
    caps = settings.get("infer") or {}
    stest = settings.get("selftest")
    err = settings.get("infer_error")

    engine = check("%s: device advertises an edge engine" % tag, bool(caps),
                   ("model=%s %sx%s" % (caps.get("model"), caps.get("w"), caps.get("h")))
                   if caps else ("infer_error=%s" % err if err else "no infer caps reported"))

    if isinstance(stest, dict):
        n = stest.get("n") or 0
        conf = stest.get("conf") or 0
        sok = check("%s: detector self-test found the reference objects" % tag,
                    n > 0 and conf >= SELFTEST_MIN_CONF,
                    "%d detection(s), best class %s @ %.3f (floor %.2f)"
                    % (n, stest.get("cls"), conf / 1000.0, SELFTEST_MIN_CONF / 1000.0))
    elif stest is None:
        # Previously this warned and PASSED, which is the same "assertion that
        # cannot fail" that let a dead detector look healthy for weeks: a
        # bundle built without selftest.rgb would have silently gone back to
        # proving nothing.  Absent self-test is now a failure; --allow-no-selftest
        # exists only for bringing up a board that predates the feature.
        if "--allow-no-selftest" in sys.argv:
            sok = True
            warn("no self-test in the device's status and --allow-no-selftest "
                 "given: inference is NOT actually verified by this run")
        else:
            sok = check("%s: detector self-test found the reference objects" % tag, False,
                        "the device reported NO selftest -- app bundle without "
                        "selftest.rgb, or an app older than 20260918b "
                        "(pass --allow-no-selftest to tolerate)")
    else:
        sok = check("%s: detector self-test found the reference objects" % tag,
                    False, "device reported selftest=%r" % (stest,))

    st, d = http("GET", "/cameras/%s/detections" % CAM, timeout=10)
    n = len(d.get("detections", [])) if isinstance(d, dict) else 0
    print("  ....  %d object(s) in view right now%s" % (n, "" if n else " (an empty scene is a valid result)"), flush=True)
    if dev.get("yolo_src"):
        print("  ....  media-host detection source: %s" % dev["yolo_src"], flush=True)
    return adv and fresh and engine and sok


def stage_gateway(tag):
    """Camera-as-gateway: with an NCP on the camera's USB the hub must see a
    LIVE gateway hosted by this slot, attached to the mesh, under the identity
    the hub minted for the slot -- proven from the hub's own records, the
    same way the rest of this run is."""
    st, g = http("GET", "/cameras/%s/gateway" % CAM)
    if st != 200:
        check("%s: hub answers the camera's gateway status" % tag, False, "HTTP %s" % st)
        return
    if not check("%s: camera reports its gateway capability" % tag,
                 "no gateway report" not in (g.get("reason") or ""), g.get("reason") or ""):
        return
    if not g.get("supported"):
        warn("no NCP on this camera (%s) -- gateway checks skipped" % g.get("reason"))
        return
    if not g.get("enabled"):
        warn("gateway role is disabled for %s by the operator -- gateway checks skipped" % CAM)
        return

    def live():
        st, gws = http("GET", "/gateways")
        if st != 200:
            return None
        mine = next((x for x in gws if x.get("host_camera") == CAM), None)
        if not mine:
            return None
        age = time.time() - (mine.get("last_seen") or 0)
        if age < 90 and mine.get("role_name") in ("child", "router", "leader"):
            return mine
        return None
    # provision-net + dataset apply + Thread attach: a few minutes worst case
    mine, dt = wait(live, 360, every=10, what="gateway live")
    check("%s: hub sees a live gateway hosted by this camera" % tag, mine,
          "%s role=%s after %.0f s" % ((mine or {}).get("id"), (mine or {}).get("role_name"), dt))
    if mine:
        st, gws = http("GET", "/gateways")
        dups = [x for x in (gws or []) if x.get("name") == mine.get("name") and x["id"] != mine["id"]]
        check("%s: no duplicate gateway record for %s" % (tag, mine.get("name")), not dups,
              "" if not dups else ", ".join(x["id"] for x in dups))


def wifi():
    env = {}
    for line in open(os.path.expanduser("~/.config/nn/wifi.env")):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1); env[k] = v
    return env["NN_WIFI_SSID"], env["NN_WIFI_PSK"]


def stage_lifecycle():
    print("== lifecycle: unregister -> BLE setup mode -> provision ==", flush=True)
    if "--from-scan" in sys.argv:
        print("  ....  resuming at the BLE scan (unregister already done)", flush=True)
    elif "--force-unregister" in sys.argv:
        # The device is ALREADY cleared (a previous run's CLEAR was obeyed but
        # the hub could not confirm it); finish the hub side only.
        st, r = http("POST", "/cameras/%s/unregister" % CAM, {"force": True}, timeout=60)
        if not check("unregister (forced: device already cleared) archived the slot", st == 200 and r.get("ok"), "HTTP %s %s" % (st, json.dumps(r)[:140] if isinstance(r, dict) else r)):
            return False
    elif not (lambda st_r: check("unregister accepted and CLEAR applied by the camera", st_r[0] == 200 and st_r[1].get("cleared"), "HTTP %s %s" % (st_r[0], json.dumps(st_r[1])[:160] if isinstance(st_r[1], dict) else st_r[1])))(http("POST", "/cameras/%s/unregister" % CAM, {}, timeout=60)):
        return False
    if "--from-scan" not in sys.argv:
        # `cam()` returns None both when the slot is gone AND when the hub API
        # is unreachable -- the old predicate scored a DEAD HUB as a pass.
        # Require the API to answer, then require this slot to be not-streaming.
        def stopped():
            st, cams = http("GET", "/cameras")
            if st != 200 or not isinstance(cams, list):
                return None                      # hub not answering: undecided
            c = next((x for x in cams if x.get("id") == CAM), None)
            return True if (c is None or not c.get("streaming")) else None
        c, dt = wait(stopped, 120, every=5, what="stop")
        check("camera stopped streaming after the wipe", c, "after %.0f s" % dt)

    # A cleared board needs a reboot to reach setup mode; scanning at once
    # finds nothing.  Wait for THIS board's BLE address, not "any device".
    def scan():
        st, r = http("POST", "/provision/scan", {"scan_time": 8}, timeout=40)
        devs = (r.get("candidates") or r.get("devices") or []) if isinstance(r, dict) else (r if isinstance(r, list) else [])
        return next((d for d in devs if isinstance(d, dict) and str(d.get("addr", "")).upper() == ADDR), None)
    dev, dt = wait(scan, 300, every=10, what="BLE advertising")
    if not check("camera advertises BLE setup mode", dev, "found after %.0f s: %s" % (dt, (dev or {}).get("name"))):
        return False

    # BLE connect is flaky on this stack: the hub's scan finds the board and the
    # very next connect can fail with BleakDeviceNotFoundError during service
    # discovery (seen twice in ~6 lifecycle runs).  A retry has always worked.
    # Retried EXPLICITLY and reported, not silently absorbed: if this ever
    # needs more than one retry, that is a real regression and must be visible.
    ssid, psk = wifi()
    body = {"kind": "camera_linux", "name": NAME, "addr": ADDR,
            "ssid": ssid, "password": psk, "target_cam": CAM}
    del psk
    st, job = http("POST", "/provision/jobs", body, timeout=30)
    if not check("provisioning job accepted", st in (200, 201, 202) and isinstance(job, dict) and job.get("id"), "HTTP %s" % st):
        print("       ", job); return False
    last = None
    def done():
        nonlocal last
        st, j = http("GET", "/provision/jobs/%s" % job["id"], timeout=15)
        if not isinstance(j, dict):
            return None
        cur = "%s | %s" % (j.get("state"), j.get("step"))
        if cur != last:
            print("  ....  job: %s" % cur, flush=True); last = cur
        return j if j.get("state") not in ("running", "queued") else None
    j, dt = wait(done, 420, every=4, what="job")
    tries = 1
    while (not j or j.get("state") != "done") and tries < 3:
        err = str((j or {}).get("error", ""))
        if "BleakDeviceNotFound" not in err and "while connecting" not in err:
            break                       # a real failure, not the connect flake
        tries += 1
        print("  RETRY %d: BLE connect flake (%s)" % (tries, err.split(":")[0][:60]), flush=True)
        time.sleep(20)
        st, job = http("POST", "/provision/jobs", body, timeout=30)
        if st not in (200, 201, 202) or not isinstance(job, dict) or not job.get("id"):
            break
        last = None
        j, d2 = wait(done, 420, every=4, what="job"); dt += d2 + 20
    ok = check("BLE provisioning job finished 'done'", j and j.get("state") == "done",
               "%.0f s, %d attempt(s), unconfirmed=%s, error=%s"
               % (dt, tries, (j or {}).get("unconfirmed"), (j or {}).get("error")))
    if ok and tries > 1:
        warn("provisioning needed %d attempts (hub-side BLE connect flake) -- "
             "a pass, but count it when measuring the pass RATE" % tries)
    return ok


def main():
    skip = "--skip-lifecycle" in sys.argv
    print("E2E: BeagleY camera on Buildroot -- %s" % time.strftime("%F %T"), flush=True)
    if "--force-unregister" not in sys.argv and "--from-scan" not in sys.argv:
        stage_streaming("before")
        stage_inference("before")
        stage_gateway("before")
    if not skip:
        if stage_lifecycle():
            stage_streaming("after re-provisioning")
            stage_inference("after re-provisioning")
            stage_gateway("after re-provisioning")
    print("\n== summary ==")
    bad = [r for r in results if not r[1]]
    for n, ok, d in results:
        print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    if warnings:
        print("\n== warnings (passed, but degraded -- track these across runs) ==")
        for w in warnings:
            print("  WARN  %s" % w)
    print("\n%d/%d checks passed%s%s" % (len(results) - len(bad), len(results),
          "" if not bad else " -- FAILED",
          "" if not warnings else "  (%d warning(s))" % len(warnings)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
