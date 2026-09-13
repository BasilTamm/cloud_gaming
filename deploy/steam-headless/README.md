# Steam Headless multi-instance spike

## Verdict: PARTIAL

**Question:** can two isolated Steam + Proton sessions run on one Steam Deck
under rootless Podman and be administered in a browser without installing a
VNC client on the host?

The upstream Steam Headless image contains Steam, Proton support, Xfce,
supervisord, noVNC with audio, and a framebuffer mode suitable for independent
browser sessions. This Compose file describes two instances with separate
homes, game libraries, bridge networks, local ports, and resource limits.

This environment has no Podman, Docker, Steam Deck GPU, or `/dev/dri`, so no
container was pulled or started. Most importantly, Vulkan/DXVK presentation
through framebuffer mode is unproved. Treat the first launch as a feasibility
test, not a deployment.

## Why framebuffer mode

Upstream's normal `primary` mode starts Xorg against a DRM card. Multiple
primary X servers can contend for DRM master on the single Steam Deck GPU,
and an already-running SteamOS desktop may also own it. `MODE=framebuffer`
starts upstream's Xvfb path instead, allowing independent displays and using
only `/dev/dri/renderD128` for the experiment.

This avoids `/dev/dri/card0`, `/dev/uinput`, `/dev/input`, host IPC, host
network, `SYS_ADMIN`, `NET_ADMIN`, `SYS_NICE`, `privileged`, and unconfined
seccomp/AppArmor. The trade-off is serious: Xvfb does not provide accelerated
GLX, so a Proton game may fail to present or fall back to software rendering
even when the render node is available.

## Prepare

Run as the normal SteamOS user, not with `sudo`:

```bash
cd /path/to/viking-rise-podman/deploy/steam-headless
cp .env.example .env
chmod 600 .env
```

Edit `.env`:

- set `PUID` and `PGID` to `id -u` and `id -g` on the Steam Deck;
- generate two different local OS passwords with `openssl rand -hex 16`;
- never put Steam usernames, passwords, 2FA secrets, or tokens there.

The local passwords are consumed by the image for its `default` and root
accounts. They do **not** protect noVNC.

## Check and start

```bash
./preflight.sh
podman compose pull
podman compose up -d steam-1
```

Open <http://127.0.0.1:15901/> in the Steam Deck browser. Log into Steam by
hand, enable Steam Play/Proton, install Viking Rise, and inspect logs:

```bash
podman compose logs -f steam-1
```

Only after the first instance demonstrates usable Vulkan/Proton behavior:

```bash
podman compose up -d steam-2
```

Open <http://127.0.0.1:15902/> for the second instance. Each instance has its
own Steam home and game library; do not share those writable volumes.

## Security assessment

- The image is pinned to Docker Hub digest
  `sha256:0d43c66ad0cf54cb0e51208b30f1f297d78264807661a581691224caa4dec0c0`
  (reported for amd64 `latest` on 2026-09-13; Docker Hub says it was updated
  2026-09-05). Updating is an explicit reviewable change.
- The upstream repository is active, not archived, GPL-2.0 licensed, and its
  inspected revision was `096fc4b` from 2026-04-20. Docker Hub does not prove
  that the pinned image was built from that exact revision.
- noVNC is published only to host loopback. The checked upstream VNC/noVNC
  path has no authentication; `USER_PASSWORD` is not a noVNC password. Any
  process running as the same host user can therefore control the desktop.
- noVNC is plain HTTP and VNC is unencrypted. For another machine, use an SSH
  tunnel to loopback; never expose these ports directly to a LAN.
- Each container gets its own bridge, so the second Steam container cannot
  reach the first one's internal VNC listener unless an operator later joins
  the networks manually.
- Rootless Podman is mandatory in `preflight.sh`. Root in the container maps
  to the invoking host user, but still accesses its volumes and render node.
- The official AMD template grants host network/IPC, `SYS_ADMIN`, `NET_ADMIN`,
  `SYS_NICE`, unconfined seccomp/AppArmor, uinput, input devices, and a DRM
  card. This spike grants none. If it fails, identify the exact missing
  syscall/device and review the smallest exception instead of adding all.
- The image is about 1.0 GB compressed and is third-party code. Digest pinning
  prevents unnoticed tag changes; it does not prove provenance or remove CVEs.
- CPU, RAM, PID, and shared-memory limits are set. Named-volume disk growth is
  not bounded; monitor free space on the Steam Deck.

## Compatibility notes

- Target architecture is x86_64/amd64, matching Steam Deck.
- `group_add: keep-groups` is Podman-specific and preserves supplementary host
  groups required for rootless render-node access. This is not portable Docker
  Compose despite using the Compose file format.
- SteamOS remains the host; the container currently uses Debian Trixie. Steam
  Runtime and Proton are managed inside Steam by the upstream image.
- The image may require omitted capabilities. Diagnose logs before widening
  privileges.
- Both containers share one physical APU and unified memory. CPU/RAM limits do
  not reserve or isolate GPU capacity.

## Stop and preserve data

```bash
podman compose down
```

This keeps named volumes. Do not use `down -v` unless deleting both Steam
profiles, installed games, and Proton prefixes is intentional.
