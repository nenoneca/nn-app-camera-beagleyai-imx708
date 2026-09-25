#!/usr/bin/env python3
"""Compute the ELF dependency closure of the TI edgeai camera pipeline and
(optionally) stage it into a directory.

The point of this script is that the TI platform rootfs is 2.7 GB and we need
about 65 MB of it.  Rather than extract the lot, it reads DT_NEEDED straight
out of the ELF headers and pulls each file it actually needs out of the ext4
image on demand with debugfs -- no root, no loop mount, and /usr/lib (1.4 GB)
never gets touched.

    edgeai-closure.py --image plat.ext4 --cache DIR [--stage OUT] ROOT...
    edgeai-closure.py --root DIR ROOT...

WHAT IT CANNOT SEE.  DT_NEEDED covers what is *linked*.  It does not cover
dlopen(), which is exactly how GStreamer loads plugins and how ONNX Runtime
loads the TIDL delegate -- so those are passed in as explicit roots, and
anything still missing shows up at runtime, not here.  Treat a clean run as
"the linked set is complete", never as "the pipeline will work".
"""
import argparse, os, struct, subprocess, sys, collections

LIBDIRS = ["/usr/lib", "/lib", "/usr/lib/aarch64-linux-gnu", "/lib/aarch64-linux-gnu"]
ELF_MAGIC = b"\x7fELF"


class Source:
    """Where files come from: an extracted tree, or the ext4 image itself."""

    def __init__(self, root=None, image=None, cache=None):
        self.root, self.image, self.cache = root, image, cache
        self.fetched = {}
        if cache:
            os.makedirs(cache, exist_ok=True)

    def _link_target(self, path):
        """The destination of <path> if it is a symlink, else None.

        Needed because `debugfs dump` on a symlink writes an EMPTY file rather
        than either the link text or the target's contents -- so every
        libfoo.so.0 -> libfoo.so.0.1.2 in the rootfs reads as "missing", which
        is most of them.  debugfs `stat` is the only thing that tells the
        truth here.
        """
        r = subprocess.run(["debugfs", "-R", "stat %s" % path, self.image],
                           capture_output=True, text=True)
        for line in r.stdout.splitlines():
            line = line.strip()
            for key in ("Fast link dest: ", "Symlink destination: "):
                if line.startswith(key):
                    return line[len(key):].strip().strip('"')
        return None

    def get(self, path):
        """Return a local path holding <path> from the target rootfs, or None."""
        path = os.path.normpath(path)
        if self.root:
            p = os.path.join(self.root, path.lstrip("/"))
            return os.path.realpath(p) if os.path.exists(p) else None
        if path in self.fetched:
            return self.fetched[path]
        self.fetched[path] = None          # guard against a symlink cycle
        out = os.path.join(self.cache, path.lstrip("/").replace("/", "__"))
        if not os.path.exists(out) or os.path.getsize(out) == 0:
            subprocess.run(["debugfs", "-R", "dump %s %s" % (path, out), self.image],
                           capture_output=True)
        if os.path.exists(out) and os.path.getsize(out) > 0:
            self.fetched[path] = out
            return out
        target = self._link_target(path)
        if target:
            if not target.startswith("/"):
                target = os.path.normpath(os.path.join(os.path.dirname(path), target))
            real = self.get(target)
            self.fetched[path] = real
            return real
        if os.path.exists(out):
            os.remove(out)
        return None


def dynamic(local):
    """(DT_NEEDED list, RPATH list) from an ELF64 LE file."""
    try:
        with open(local, "rb") as f:
            data = f.read()
    except OSError:
        return [], []
    if len(data) < 64 or data[:4] != ELF_MAGIC or data[4] != 2:
        return [], []
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum = struct.unpack_from("<HH", data, 0x3A)
    secs, dyn = [], None
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        if off + e_shentsize > len(data):
            return [], []
        sh_type, = struct.unpack_from("<I", data, off + 4)
        sh_offset, = struct.unpack_from("<Q", data, off + 0x18)
        sh_size, = struct.unpack_from("<Q", data, off + 0x20)
        sh_link, = struct.unpack_from("<I", data, off + 0x28)
        secs.append((sh_type, sh_offset, sh_size, sh_link))
        if sh_type == 6:
            dyn = (sh_offset, sh_size, sh_link)
    if not dyn:
        return [], []
    dyn_off, dyn_size, dyn_link = dyn
    strtab = secs[dyn_link][1]

    def s(idx):
        end = data.index(b"\0", strtab + idx)
        return data[strtab + idx:end].decode("utf-8", "replace")

    needed, rpath, soname = [], [], None
    for off in range(dyn_off, dyn_off + dyn_size, 16):
        if off + 16 > len(data):
            break
        tag, val = struct.unpack_from("<qQ", data, off)
        if tag == 0:
            break
        if tag == 1:
            needed.append(s(val))
        elif tag == 14:
            soname = s(val)
        elif tag in (15, 29):
            rpath.extend(s(val).split(":"))
    return needed, rpath, soname


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image")
    ap.add_argument("--cache")
    ap.add_argument("--root")
    ap.add_argument("--stage", help="assemble the closure into this directory")
    ap.add_argument("roots", nargs="+")
    a = ap.parse_args()
    if not a.root and not (a.image and a.cache):
        ap.error("give --root DIR, or --image IMG together with --cache DIR")
    src = Source(root=a.root, image=a.image, cache=a.cache)

    seen, missing, sonames = {}, set(), {}
    queue = collections.deque(a.roots)
    while queue:
        path = queue.popleft()
        if path in seen:
            continue
        local = src.get(path)
        if local is None:
            missing.add(path)
            continue
        seen[path] = local
        needed, rpath, soname = dynamic(local)
        if soname:
            sonames[path] = soname
        for n in needed:
            dirs = [d for d in rpath if d.startswith("/")] + LIBDIRS
            for d in dirs:
                cand = os.path.join(d, n)
                if cand in seen:
                    break
                if src.get(cand) is not None:
                    queue.append(cand)
                    break
            else:
                missing.add(n)

    total = sum(os.path.getsize(p) for p in seen.values())
    print("closure: %d files, %.1f MB" % (len(seen), total / 1e6))
    for path in sorted(seen):
        print("    %s  %.1f MB" % (path, os.path.getsize(seen[path]) / 1e6))
    if missing:
        print("UNRESOLVED (%d): %s" % (len(missing), ", ".join(sorted(missing))),
              file=sys.stderr)

    if a.stage:
        # Stage under the name the LOADER will look for.  ld.so resolves a
        # DT_NEEDED entry by that exact string, and DT_NEEDED carries the
        # SONAME (libonnxruntime.so.1), not whatever path we happened to ask
        # for (libonnxruntime.so, a symlink).  Writing the bytes under the
        # requested name alone leaves the soname unresolvable -- a failure
        # that shows up only when the container runs.
        for path, local in seen.items():
            names = {os.path.basename(path)}
            if path in sonames:
                names.add(sonames[path])
            names = sorted(names, key=len, reverse=True)
            real = names[0]                       # longest = most versioned
            d = os.path.join(a.stage, os.path.dirname(path).lstrip("/"))
            os.makedirs(d, exist_ok=True)
            dst = os.path.join(d, real)
            with open(local, "rb") as fi, open(dst, "wb") as fo:
                fo.write(fi.read())
            os.chmod(dst, 0o755)
            for alias in names[1:]:
                link = os.path.join(d, alias)
                if os.path.lexists(link):
                    os.remove(link)
                os.symlink(real, link)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
