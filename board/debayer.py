#!/usr/bin/env python3
"""Quick-look debayer for IMX708 RAW10-in-16 (RG10) frames from ti-csi2rx.

Layout: 2304x1296, 2 bytes/pixel little-endian, 10 valid bits.
Bayer order per the driver: SRGGB10 (R at 0,0).
Simple half-res demosaic: each 2x2 {R,G,G,B} -> one RGB pixel (1152x648).
"""
import sys
import numpy as np
from PIL import Image

path, out = sys.argv[1], sys.argv[2]
W, H = 2304, 1296
frame_bytes = W * H * 2
raw = open(path, 'rb').read()
n = len(raw) // frame_bytes
if n == 0:
    sys.exit(f"file too small: {len(raw)} < {frame_bytes}")
# use the last complete frame (first can be dark while AGC settles)
a = np.frombuffer(raw[(n - 1) * frame_bytes:n * frame_bytes], '<u2').reshape(H, W)
a = (a & 0x3FF).astype(np.float32)

r  = a[0::2, 0::2]
g1 = a[0::2, 1::2]
g2 = a[1::2, 0::2]
b  = a[1::2, 1::2]
g = (g1 + g2) / 2

def stretch(c):
    lo, hi = np.percentile(c, 1), np.percentile(c, 99.5)
    return np.clip((c - lo) / max(hi - lo, 1) * 255, 0, 255)

# grey-world white balance before the stretch
means = [c.mean() for c in (r, g, b)]
tgt = means[1]
rgb = np.dstack([stretch(c * (tgt / max(m, 1))) for c, m in
                 zip((r, g, b), means)]).astype(np.uint8)
Image.fromarray(rgb).save(out)
print(f"frames={n} last-frame mean={a.mean():.1f} -> {out}")
