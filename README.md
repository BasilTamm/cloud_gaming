# viking-rise-podman

Proof-of-concept Podman container running the native Steam client (for
Viking Rise) on the `steamdeck` host. **Not a final architecture** — kept
deliberately minimal.

`Xvfb` provides a virtual X display, `x11vnc` exposes it on the host
loopback, and Steam runs there as an unprivileged user. The operator
connects over VNC and **logs into Steam by hand**.

## Quick start

```bash
cp deploy/viking-rise.env.example deploy/viking-rise.env   # optional
x11vnc -storepasswd '<VNC password>' deploy/viking-rise-vnc.passwd
chmod 600 deploy/viking-rise-vnc.passwd
deploy/viking-rise-podman.sh
```

Then point a VNC client at `127.0.0.1:15900` and log in.

## No Steam login automation — by design

No Steam username, password, 2FA code, or token appears anywhere in this
repository, and none should ever be added. Login is manual, in the VNC
session.

## Status

The scripts are clean under `bash -n` and ShellCheck 0.10.0, and every apt
package is confirmed to exist in Ubuntu 22.04. But **nothing here has ever
been executed**: the image has never been built and the container has never
been started — `podman` and `docker` were unavailable while it was written.

Read **[`deploy/viking-rise-podman.md`](deploy/viking-rise-podman.md)** before
running it — it documents the design decisions, the Steam packaging facts
that were verified from the Ubuntu source package, and an explicit list of
what has and has not been checked.

## Steam Headless alternative

[`deploy/steam-headless/`](deploy/steam-headless/) contains a separate,
two-instance plain-Podman spike based on the maintained third-party Steam Headless
image. A small pinned derivative adds the `Xvfb` binary missing from upstream's
framebuffer path, preserves rootless render groups across the desktop privilege
drop, and enables VNC authentication. Its verdict remains **PARTIAL** until
Vulkan/Proton is tested on a real Steam Deck.

This alternative uses ordinary `podman` commands directly. It does not require
or invoke `podman compose`, Docker Compose, or `podman-compose`.
