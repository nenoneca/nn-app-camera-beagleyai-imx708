# rootfs-overlay — operator-supplied files

Copied verbatim over the target filesystem at image build time, permissions
preserved. **Nothing secret is committed here.**

## Getting SSH into a flashed card
Root has no password (Buildroot default), and dropbear refuses an
empty-password login — so the image ships with **no network access at all**
until you put a public key here:

    cp ~/.ssh/id_ed25519.pub  root/.ssh/authorized_keys
    chmod 700 root/.ssh ; chmod 600 root/.ssh/authorized_keys

then rebuild. eth0 already does DHCP, so the board is reachable over
Ethernet as soon as it boots.

This matters more than it looks: the serial console is the only other way
in, and a wedged console (or a debug probe that cannot send a BREAK) leaves
no route back to a running board. The hardware watchdog covers a *hard*
hang, not a hung userspace process.
