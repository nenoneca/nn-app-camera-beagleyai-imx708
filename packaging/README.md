# packaging — how a byai card gets built

> Named `br2-external/`, not `buildroot/`: the repo's `.gitignore` has
> `build*/`, which silently swallows a directory called `buildroot`.

Two routes to the same board, kept side by side because they answer
different questions.

## `br2-external/` — the image (product artifact)
A `BR2_EXTERNAL` tree for Buildroot **2025.08**. Point Buildroot at it:

    make BR2_EXTERNAL=<this>/br2-external O=<out> nn_beagley_ai_612bt_defconfig
    make BR2_EXTERNAL=<this>/br2-external O=<out>

Two defconfigs:
* `nn_beagley_ai_612bt_defconfig` — **the one to use.** TI 6.12.57-ti-arm64-r64bt
  with `btti_sdio`, bluez + iwd + lxc, boot chain 2026.01. 6.12 is the build
  where `hci0` came up and LE advertising worked.
* `nn_beagley_ai_vendork_defconfig` — TI 6.1.83-ti-arm64-r72 (+ the C7x cdev
  backport). Kept because it matches what cam3 runs today; on that kernel the
  BT is on UART and did not register an HCI index on our card.

Sources not in git: the kernel tarballs (multi-GB — regenerate with
`board/nn/beagley-ai/mk-kernel-tarball.sh`) and the TI cc33xx firmware.

### Things that will bite you
* **`BR2_KERNEL_HEADERS_AS_KERNEL` cannot infer a version from a custom
  kernel** — it silently falls back to headers "2.6", which makes glibc
  unavailable, so you get uclibc, and lxc then disappears. A whole cascade,
  no error. Both defconfigs pin `BR2_KERNEL_HEADERS_*` explicitly.
* **kconfig ignores unknown symbols silently.** `BR2_TARGET_UBOOT_NEEDS_OPTEE_TEE_RAW_BIN`
  exists only in Buildroot master; copied into a 2025.08 defconfig it looks
  applied and does nothing. Always verify the generated `.config`.
* **gcc 14 made `-Wincompatible-pointer-types` an error**, which breaks
  pre-6.8 kernels — hence `BR2_GCC_VERSION_13_X`.
* **`BR2_ROOTFS_POST_BUILD_SCRIPT` replaces upstream's script**, it does not
  append. Dropping upstream's one line means no `extlinux.conf` in the images
  dir and genimage fails at the very last step.
* **`btmgmt` is `noinst_PROGRAMS` in bluez** — upstream builds it and never
  installs it, so no Buildroot option ships it. `post-build.sh` copies it out
  of the build dir. It is the command that says whether the controller can
  advertise, so an image without it cannot answer the question it exists for.
* `buildroot-patches/` holds one backport we need against 2025.08; see its
  README.

### The boot gate
`check-boot-order.py` runs as a post-image script and fails the build unless
both AM67A ROM invariants hold: `tiboot3.bin` is the FIRST root-directory
entry, and **BPB hidden sectors is 0**. Both are necessary; a card satisfying
only the first is silently unbootable — no SPL, no console output. Proven on
hardware. genimage happens to satisfy both by construction, so this guards
against regression rather than fixing anything.

## `devdrop/` — installing onto a RUNNING card (iteration)
`install.sh` puts a 6.12 kernel + `nn-setupd` onto a card that is already
running Debian, alongside what is there. Idempotent; `--default` also makes
6.12 the boot default.

Two things it does deliberately:
* The cc33xx firmware goes in its **own directory**, with only the 6.12 entry
  pointing at it via `firmware_class.path=`. 6.12 needs the 1.0.2.10 pair and
  the r72 fallback needs 1.7.0.130; mixing releases does not degrade, it kills
  the radio outright. This keeps the fallback working.
* `csi0-ov5647.dtbo` is left out of the 6.12 entry — it does not apply to the
  6.12 dtb (`FDT_ERR_NOTFOUND`) and would make the entry unbootable.

`cross-build-setupd.sh` builds `nn-setupd` for a Debian card from a
non-Debian host: glibc is backward compatible, so the host's older cross-gcc
is fine; mbedtls is linked statically so the binary does not depend on the
card's; and `--allow-shlib-undefined` is needed because the target's own
`libsystemd.so` wants glibc symbols the older sysroot lacks.
