# Local patches to the Buildroot 2025.08 checkout
> Named `br-patches/`, not `buildroot-patches/`: the repo .gitignore has `build*/`,
> which silently swallows any directory starting with "build" — it ate this one once.

Applied by hand to `../buildroot`; re-apply if that tree is re-cloned.

## 0001-uboot-dont-copy-COPYING-onto-itself.patch
U-Boot **2026.01** ships `COPYING` as a *symlink* to `Licenses/gpl-2.0.txt`.
Buildroot's `UBOOT_COPY_OLD_LICENSE_FILE` post-extract hook (a shim for
pre-2013.10 U-Boot, where the license lived in COPYING) then runs
`install -D COPYING Licenses/gpl-2.0.txt` — copying a file onto itself. Its
`[ -f COPYING ]` guard follows the symlink, so it does not catch this, and
`install` fails the extract step:

    install: '.../COPYING' and '.../Licenses/gpl-2.0.txt' are the same file

We need U-Boot 2026.01 because that is the boot chain proven on this silicon
(hardware console capture: SPL 2026.01 + SYSFW 11.2.8), whereas 2025.08 pins
2025.07. This is a straight **backport of the upstream fix** (Buildroot
master: only copy when the destination does not already exist) — not a local
invention. Drop it whenever we move to a Buildroot release that carries it.
