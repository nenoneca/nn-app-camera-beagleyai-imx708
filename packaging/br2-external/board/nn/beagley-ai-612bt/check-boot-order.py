#!/usr/bin/env python3
"""Assert tiboot3.bin is the FIRST file in a FAT boot partition.

The AM67A boot ROM has a minimal FAT reader that gives up before walking a
long root directory.  A boot partition can therefore be byte-for-byte
correct -- right files, right md5s, right cluster size -- and still be
silently unbootable (no SPL, no console output at all) purely because
tiboot3.bin was written late.  An alphabetical rsync does exactly that:
it lands tiboot3.bin behind Image.gz, initrd and 400+ overlays, ~42 MB in,
and the ROM never reaches it.

genimage mcopies `files` one at a time in the order given in genimage.cfg
(vfat_parse uses list_add_tail, so order is preserved), so listing
tiboot3.bin first is what keeps us correct.  This asserts it stayed that
way, because nothing else in the build would notice if it didn't.

Usage: check-boot-order.py <boot.vfat|sdcard.img>
"""
import struct
import sys


def read_bpb(f, off):
    f.seek(off)
    b = f.read(512)
    if b[510:512] != b"\x55\xaa":
        raise SystemExit("not a FAT boot sector (no 0x55AA signature)")
    bps = struct.unpack_from("<H", b, 11)[0]      # bytes/sector
    spc = b[13]                                    # sectors/cluster
    rsvd = struct.unpack_from("<H", b, 14)[0]
    nfat = b[16]
    rootent = struct.unpack_from("<H", b, 17)[0]   # 0 => FAT32
    spf16 = struct.unpack_from("<H", b, 22)[0]
    spf32 = struct.unpack_from("<I", b, 36)[0]
    spf = spf16 or spf32
    root_clus = struct.unpack_from("<I", b, 44)[0] if rootent == 0 else 0
    hidden = struct.unpack_from("<I", b, 28)[0]    # BPB_HiddSec
    secs16 = struct.unpack_from("<H", b, 19)[0]
    secs32 = struct.unpack_from("<I", b, 32)[0]
    heads = struct.unpack_from("<H", b, 26)[0]
    spt = struct.unpack_from("<H", b, 24)[0]
    return dict(bps=bps, spc=spc, rsvd=rsvd, nfat=nfat, rootent=rootent,
                spf=spf, root_clus=root_clus, hidden=hidden,
                secs=secs16 or secs32, heads=heads, spt=spt)


def find_fat_offset(f):
    """Accept either a bare FAT image or a partitioned sdcard.img."""
    f.seek(510)
    if f.read(2) == b"\x55\xaa":
        f.seek(0)
        if f.read(1) not in (b"\xeb", b"\xe9"):        # not a BPB jump => MBR
            f.seek(446)
            for _ in range(4):
                e = f.read(16)
                ptype, lba = e[4], struct.unpack_from("<I", e, 8)[0]
                if ptype in (0x0b, 0x0c, 0x0e, 0x06, 0x04, 0x01) and lba:
                    return lba * 512
            raise SystemExit("no FAT partition found in MBR")
    return 0


def root_entries(path, want_bpb=False):
    with open(path, "rb") as f:
        base = find_fat_offset(f)
        p = read_bpb(f, base)
        if p["rootent"]:                              # FAT12/16 fixed root
            start = base + (p["rsvd"] + p["nfat"] * p["spf"]) * p["bps"]
            size = p["rootent"] * 32
            f.seek(start)
            raw = f.read(size)
        else:
            # FAT32: the root directory is a CLUSTER CHAIN, not one cluster.
            # Reading only the first cluster silently truncates the listing
            # (and hides where tiboot3.bin really landed), so follow the FAT.
            csz = p["spc"] * p["bps"]
            fat0 = base + p["rsvd"] * p["bps"]
            first_data = base + (p["rsvd"] + p["nfat"] * p["spf"]) * p["bps"]
            raw = b""
            clus = p["root_clus"]
            seen = set()
            while 0x2 <= clus < 0x0FFFFFF8 and clus not in seen:
                seen.add(clus)
                f.seek(first_data + (clus - 2) * csz)
                raw += f.read(csz)
                f.seek(fat0 + clus * 4)
                clus = struct.unpack("<I", f.read(4))[0] & 0x0FFFFFFF

    out = []
    for i in range(0, len(raw), 32):
        e = raw[i:i + 32]
        if not e or e[0] == 0x00:
            break
        if e[0] == 0xE5 or e[11] == 0x0F:              # deleted / LFN slot
            continue
        if e[11] & 0x08:                               # volume label
            continue
        name = e[0:8].decode("ascii", "replace").strip()
        ext = e[8:11].decode("ascii", "replace").strip()
        clus = (struct.unpack_from("<H", e, 26)[0]
                | struct.unpack_from("<H", e, 20)[0] << 16)
        out.append((f"{name}.{ext}" if ext else name, clus))
    return (out, p) if want_bpb else out


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    entries, bpb = root_entries(sys.argv[1], want_bpb=True)

    # BPB_HiddSec must be 0.  mkfs.vfat run on a PARTITION DEVICE stamps the
    # partition's start LBA here (2048); run on a bare file (what genimage
    # does, then dd's it in) it stays 0.  The AM67A ROM appears to ADD this
    # to the partition LBA, so a "correct" 2048 sends it 1 MB past the real
    # filesystem and the board is silent even with tiboot3.bin placed first.
    # Boot order is necessary but NOT sufficient -- both must hold.
    print(f"  BPB: hidden={bpb['hidden']} secs={bpb['secs']} "
          f"spt={bpb['spt']} heads={bpb['heads']} bps={bpb['bps']} "
          f"spc={bpb['spc']}")
    if bpb["hidden"] != 0:
        raise SystemExit(
            f"FAIL: BPB hidden sectors = {bpb['hidden']}, expected 0.\n"
            "      Format a bare FILE and dd it into the partition, or use\n"
            "      mkfs.vfat -F32 -h 0 -- not mkfs.vfat on /dev/...p1.")
    if not entries:
        raise SystemExit("FAIL: no root directory entries")

    print("  root dir order: " + ", ".join(n for n, _ in entries[:6])
          + (" ..." if len(entries) > 6 else ""))
    first, first_clus = entries[0]
    if first.upper() != "TIBOOT3.BIN":
        raise SystemExit(
            f"FAIL: first root entry is {first!r}, not TIBOOT3.BIN.\n"
            "      The AM67A ROM will not find the bootloader -- the board\n"
            "      will be silent (not even SPL). Write tiboot3.bin FIRST.")
    print(f"  OK: TIBOOT3.BIN is first, start cluster {first_clus}")
    if first_clus > 64:
        raise SystemExit(f"FAIL: TIBOOT3.BIN starts at cluster {first_clus}, "
                         "far into the volume; ROM may not reach it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
