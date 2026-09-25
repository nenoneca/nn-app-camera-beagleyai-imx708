#!/usr/bin/env python3
"""mk-selftest-rgb.py -- build the detector self-test reference frame.

The camera runs this frame through the real C7x/TIDL engine at startup and
publishes what it found (see src/infer.c selftest_run and
packaging/e2e-camera.py).  It is the only check that fails when inference
breaks: the device emits a 'D' record every cycle even when it detected
nothing, so without a known-answer frame a dead detector and a blank wall look
identical on the wire.

Raw RGB888 at exactly NN_INFER_SRC_W x NN_INFER_SRC_H (640x360) -- no decoder
on the target, so the check cannot fail for a reason unrelated to inference.

WHY THIS IS GENERATED AND NOT COMMITTED
---------------------------------------
The default source is TI's own sample image from edgeai-tidl-tools
(test_data/airshow.jpg), which ships under the TEXAS INSTRUMENTS TEXT FILE
LICENSE.  That licence permits redistribution of derivative works only "for
use only with TI Devices" and requires the licence and copyright notice to be
reproduced with any distribution.  Our use is on a TI device (AM67A), so
building and running this is fine -- but committing a derivative of TI's
image into this repository would be a redistribution, and that is a licensing
decision for the repository owner, not something to do silently.  So the tool
is in git and its output is not (see .gitignore).

The same reasoning applies to packaging/mk-imx708-dcc.py, whose output is a
modified copy of TI's DCC binary.

Any image works as long as the model detects something in it with confidence
comfortably above e2e-camera.py's SELFTEST_MIN_CONF; pass --src to use your
own.  airshow.jpg scores 0.857 (class 4, aeroplane) on the float reference and
0.849 on the device, with two more classes above 0.4, so it has plenty of
margin for quantisation.

Usage:
    mk-selftest-rgb.py [--src <image>] [--out board/selftest.rgb]
"""
import argparse, os, sys

# No baked absolute path: that is machine-specific and this repo keeps paths
# out of source.  Give --src, or $NN_SELFTEST_SRC, or drop the image at one of
# these repo-relative spots.
CANDIDATES = ("board/selftest-src.jpg",
              "../beagley-edgeai/edgeai-tidl-tools/test_data/airshow.jpg",
              "../../nn_project_nowest/beagley-edgeai/edgeai-tidl-tools/test_data/airshow.jpg")
W, H = 640, 360


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.environ.get("NN_SELFTEST_SRC"))
    ap.add_argument("--out", default="board/selftest.rgb")
    ap.add_argument("--gray", action="store_true",
                    help="emit a single BT.601 luma plane (for a 1-channel "
                         "model, which takes the ISP's Y directly)")
    a = ap.parse_args()

    src = a.src
    if not src:
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        for c in CANDIDATES:
            if os.path.exists(os.path.join(here, c)):
                src = os.path.join(here, c)
                break
    if not src or not os.path.exists(src):
        sys.exit("mk-selftest-rgb: no source image.\n"
                 "  Give --src <image> or set $NN_SELFTEST_SRC, or place one at\n"
                 "  one of: %s\n"
                 "  Any image works if the model detects something in it well\n"
                 "  above e2e-camera.py's SELFTEST_MIN_CONF; TI's\n"
                 "  edgeai-tidl-tools test_data/airshow.jpg is what the numbers\n"
                 "  in this repo were measured with (0.857 host / 0.849 device)."
                 % ", ".join(CANDIDATES))
    a.src = src
    try:
        from PIL import Image
    except ImportError:
        sys.exit("mk-selftest-rgb: needs Pillow on the BUILD host "
                 "(pip install pillow); nothing is needed on the target.")

    im = Image.open(a.src).convert("RGB").resize((W, H), Image.BILINEAR)
    if a.gray:
        # BT.601 luma, matching what the VPAC puts in NV12's Y plane
        import struct
        px = im.tobytes()
        data = bytes(bytearray(
            min(255, max(0, int(0.257 * px[i] + 0.504 * px[i + 1] + 0.098 * px[i + 2] + 16)))
            for i in range(0, len(px), 3)))
        exp = W * H
    else:
        data = im.tobytes()
        exp = W * H * 3
    if len(data) != exp:
        sys.exit("mk-selftest-rgb: produced %d bytes, expected %d" % (len(data), exp))
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    open(a.out, "wb").write(data)
    print("mk-selftest-rgb: wrote %s (%d bytes, %dx%d %s) from %s"
          % (a.out, len(data), W, H, "GRAY8" if a.gray else "RGB888", a.src))
    print("  Verify the model still finds it before relying on the check:")
    print("    the device logs  infer: selftest: N detection(s), best class C @ conf")


if __name__ == "__main__":
    main()
