#!/usr/bin/env python3
"""mk-imx708-dcc.py -- derive an IMX708 VISS tuning file from TI's IMX219 DCC.

TI's vision-apps supports six sensors and IMX708 is not one of them
(`gst-inspect-1.0 tiovxisp` lists SENSOR_SONY_IMX219_RPI, IMX390, AR0820,
AR0233, OX05B1S, OV2312; there is no imx708 string anywhere in
libtivision_apps).  So the camera runs IMX219 tuning on an IMX708 sensor and
the picture comes out strongly magenta.

Measured on cam3 2026-09-18 (bench scene, ~4600K indoor):

    sensor raw (Bayer, black-subtracted)  R/G = 1.17   B/G = 0.66
    sensor raw (as read)                  R/G = 1.06   B/G = 0.88   ~neutral
    ISP output                            R/G = 1.51   B/G = 1.72   magenta
    same raw developed with the IMX708
    CCM on the host                       R/G = 1.01   B/G = 1.01   neutral

So the sensor is fine and the ISP manufactures the cast.  Isolation tests ruled
out the adaptive stages: `bypass-dwb=true` changed nothing (1.53/1.74) and
removing the 2A/AE-AWB DCC entirely changed nothing (1.53/1.73).  The cast is a
FIXED transform living in the VISS DCC.

The cause is visible in the coefficients.  TI's IMX219 red row subtracts 0.98
of green; the calibrated IMX708 matrix subtracts only 0.35.  Over-subtracting
green from red is exactly what turns a neutral wall magenta.

Layout (from the SDK's own headers, which ship in the edgeai rootfs at
usr/include/processor_sdk/imaging/algos/dcc/include):

    dcc_defs.h            DCC_ID_IPIPE_RGB_RGB_1 = 10   "RGB2RGB before gamma"
    dcc_iss_module_def.h  typedef struct {
                              int16_t matrix[3][4];   /* Q8, 256 = 1.0 */
                              int16_t offset[3];
                          } iss_ipipe_rgb2rgb;        /* 30 bytes */

Note matrix rows have stride FOUR, not three (the 4th column is unused and
zero) -- searching for a contiguous 3x3 finds nothing, which is what sent the
first attempt at this down a blind alley.

In TI's imx219 dcc_viss_10b_1920x1080.bin the four colour-temperature entries
sit at byte 11484, stride 30, every row summing to exactly 256, and the next
block header (sensor id 219) begins at 11604 -- so the array is exactly four
structs and nothing else is disturbed.

We keep the file's sensor id as 219 and keep passing
sensor-name=SENSOR_SONY_IMX219_RPI: the pipeline already declares IMX219 for an
IMX708, and the DCC descriptor id has to match what the library looks up.  Only
the colour matrices change.

All four CT slots get the same matrix.  Selecting between them needs a colour
temperature estimate from 2A, and 2A demonstrably has no effect on this
pipeline, so a CT-adaptive set would be untestable here; one matrix that is
right for indoor light beats four that are wrong.  Revisit if AWB is ever
working.
"""
import argparse, struct, sys

CCM_OFFSET, CCM_STRIDE, CCM_COUNT = 11484, 30, 4
EXPECT_SENSOR_ID = 219

# RPi's calibrated IMX708 4640K CCM.  Rows sum to exactly 1.0, so Q8 rounds to
# exactly 256 with no white-point drift.
IMX708_CCM = [[1.530, -0.352, -0.178],
              [-0.283, 1.671, -0.388],
              [0.017, -0.572, 1.555]]


def q8(m, row_gain=(1.0, 1.0, 1.0)):
    """Q8-encode the CCM, optionally scaling each output row.

    Row gains bake a fixed white balance INTO the CCM.  That is a workaround,
    not tuning: TI's 2A never adapts on this camera (proven -- the output
    ratios are constant to 0.5% over a minute, `bypass-dwb` changes nothing,
    and removing the 2A DCC changes nothing), because its white-patch
    references in dcc_2a are IMX219's and IMX708's raw ratios never fall
    inside them.  With no working AWB, a fixed correction for the deployment's
    illuminant is the best available, and the CCM is the last colour stage
    before gamma, so it is the right place to put it.

    Consequence to be honest about: colour is then correct for ONE illuminant.
    A real fix needs IMX708 grey-point references in the 2A DCC, which needs a
    colour target under several illuminants.

    With gains != 1 the rows deliberately no longer sum to 256.
    """
    out = []
    for row, g in zip(m, row_gain):
        r = [int(round(v * 256 * g)) for v in row]
        if g == 1.0 and sum(r) != 256:       # keep white exactly neutral
            r[max(range(3), key=lambda i: abs(r[i]))] += 256 - sum(r)
        out.append(r)
    return out


def read_ccms(b):
    got = []
    for k in range(CCM_COUNT):
        o = CCM_OFFSET + k * CCM_STRIDE
        w = struct.unpack_from("<15h", b, o)
        got.append(([list(w[0:3]), list(w[4:7]), list(w[8:11])], list(w[12:15])))
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", help="TI imx219 dcc_viss_10b_1920x1080.bin")
    ap.add_argument("dst", help="output IMX708 tuning file")
    ap.add_argument("--check", action="store_true",
                    help="only print what is in the source file")
    ap.add_argument("--row-gain", default="1,1,1",
                    help="per-output-row gains R,G,B applied to the CCM to bake "
                         "in a fixed white balance (see q8()); default 1,1,1")
    a = ap.parse_args()

    b = bytearray(open(a.src, "rb").read())

    sid = struct.unpack_from("<I", b, 0)[0]
    if sid != EXPECT_SENSOR_ID:
        sys.exit("refusing: %s has DCC sensor id %d, expected %d (not TI's "
                 "imx219 VISS DCC?)" % (a.src, sid, EXPECT_SENSOR_ID))

    # Refuse to patch a file whose CCM array is not where we think it is: every
    # row must sum to 256 and the 4th column and offsets must be zero.  A
    # future SDK that moves the block must fail loudly, not corrupt tuning.
    for k, (m, off) in enumerate(read_ccms(b)):
        for r in m:
            if sum(r) != 256:
                sys.exit("refusing: CCM[%d] row %s does not sum to 256 -- the "
                         "block moved in this SDK; re-locate it before patching" % (k, r))
        if any(off):
            sys.exit("refusing: CCM[%d] has non-zero offsets %s" % (k, off))

    print("source CCMs (Q8 /256):")
    for k, (m, _) in enumerate(read_ccms(b)):
        print("  [%d] %s" % (k, m))

    if a.check:
        return

    rg = tuple(float(x) for x in a.row_gain.split(","))
    if len(rg) != 3:
        sys.exit("--row-gain needs three comma-separated numbers")
    new = q8(IMX708_CCM, rg)
    if max(abs(v) for row in new for v in row) > 2047:
        sys.exit("refusing: a coefficient exceeds the VISS CCM's 12-bit signed "
                 "field (+-2047); lower --row-gain")
    print("\nwriting IMX708 CCM (row gains %s) to all %d CT slots "
          "(Q8, rows sum %s):" % (list(rg), CCM_COUNT, [sum(r) for r in new]))
    for r in new:
        print("   ", r)

    for k in range(CCM_COUNT):
        o = CCM_OFFSET + k * CCM_STRIDE
        for row in range(3):
            for col in range(3):
                struct.pack_into("<h", b, o + (row * 4 + col) * 2, new[row][col])

    open(a.dst, "wb").write(bytes(b))
    # read back from what we actually wrote
    rb = bytearray(open(a.dst, "rb").read())
    for k, (m, _) in enumerate(read_ccms(rb)):
        if m != new:
            sys.exit("verify FAILED at slot %d: %s" % (k, m))
    if len(rb) != len(open(a.src, "rb").read()):
        sys.exit("verify FAILED: output size changed")
    print("\nwrote %s (%d bytes, size unchanged, all %d slots verified)"
          % (a.dst, len(rb), CCM_COUNT))


if __name__ == "__main__":
    main()
