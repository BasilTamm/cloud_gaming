# Steam Headless multi-instance spike

## Verdict: PARTIAL

**Question:** can two isolated Steam + Proton sessions run on one Steam Deck
under rootless Podman and be administered in a browser without installing a
VNC client on the host?

The upstream Steam Headless image contains Steam, Proton support, Xfce,
supervisord, and noVNC with audio. This spike builds a small derivative from a
pinned upstream digest, adds the missing `Xvfb` package, preserves rootless GPU
groups while dropping to the desktop UID, and requires VNC authentication.
The Compose file describes two instances with separate homes, game libraries,
bridge networks, local ports, and resource limits.

This environment has no Podman, Docker, Steam Deck GPU, or `/dev/dri`, so no
container was built or started. Most importantly, Vulkan/DXVK presentation
through framebuffer mode and GPU access after the final privilege drop remain
unproved. Treat the first launch as a feasibility test, not a deployment.

## Why framebuffer mode

Upstream's normal `primary` mode starts Xorg against a DRM card. Multiple
primary X servers can contend for DRM master on the single Steam Deck GPU,
and an already-running SteamOS desktop may also own it. `MODE=framebuffer`
starts upstream's Xvfb path instead, allowing independent displays and using
only `/dev/dri/renderD128` for the experiment.

Inspection of the pinned image's X-server layer found `xserver-xorg-core` but
no `/usr/bin/Xvfb` and no installed `xvfb` package, while its supervisor config
calls `/usr/bin/Xvfb`. `Containerfile` therefore installs Debian's `xvfb`
package and verifies the binary during build. This finding is about the pinned
image contents; it is not inferred only from a possibly unrelated source tree.

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
- generate two different local OS/VNC passwords with `openssl rand -hex 16`;
- never put Steam usernames, passwords, 2FA secrets, or tokens there.

The derivative image also configures x11vnc authentication from each local
password. noVNC will prompt for it. x11vnc's legacy authentication uses only
the first eight characters, so ensure those differ. The transport is still
plain HTTP/VNC; authentication does not add encryption.

## Check and start

```bash
./steam-headless.sh check
./steam-headless.sh build
./steam-headless.sh up-one
```

Open <http://127.0.0.1:15901/> in the Steam Deck browser. Log into Steam by
hand, enable Steam Play/Proton, install Viking Rise, and inspect logs:

```bash
podman compose -f compose.yaml logs -f steam-1
```

Only after the first instance demonstrates usable Vulkan/Proton behavior:

```bash
./steam-headless.sh up-two
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
- noVNC is published only to host loopback and its VNC backend now requires a
  password. Other local users can still reach the TCP endpoint and attempt
  authentication. noVNC is plain HTTP and VNC is unencrypted; use an SSH
  tunnel from another machine and never expose these ports directly to a LAN.
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
- `steam-headless.sh` accepts only documented `.env` keys, rejects symlinks,
  duplicate keys, wrong ownership/mode, non-DRM devices, rootful Podman,
  non-crun runtimes, and non-cgroup-v2 hosts. It validates and launches with
  the same explicitly exported values, preventing parent-shell overrides from
  changing the checked model. `.containerignore` and `.dockerignore` keep the
  password-bearing `.env` outside the derivative image build context.
- CPU, RAM, PID, and shared-memory limits are requested. Their actual cgroup
  enforcement must be inspected after start. Named-volume disk growth is not
  bounded; monitor free space on the Steam Deck.

## Compatibility notes

- Target architecture is x86_64/amd64, matching Steam Deck.
- `group_add: keep-groups` is Podman/crun-specific. The derivative replaces
  upstream supervisord's `user=default` transition (which calls `setgroups`)
  with `setpriv --keep-groups`, then checks render-node access from the final
  desktop UID before Xfce starts. This is not portable Docker Compose.
- SteamOS remains the host; the container currently uses Debian Trixie. Steam
  Runtime and Proton are managed inside Steam by the upstream image.
- The image may require omitted capabilities. Diagnose logs before widening
  privileges.
- Both containers share one physical APU and unified memory. CPU/RAM limits do
  not reserve or isolate GPU capacity.

## Verification evidence

Statically verified in the development environment:

- the pinned OCI index resolves to a Linux/amd64 child and declares
  `/entrypoint.sh`;
- direct inspection of its X-server layer found `xserver-xorg-core` but no
  `/usr/bin/Xvfb`;
- Debian Trixie package file lists map `xvfb` to `/usr/bin/Xvfb`, `procps` to
  `/usr/bin/pgrep`, and `util-linux` to `/usr/bin/setpriv`;
- `compose.yaml` parses with merge anchors and retains separate loopback ports,
  networks, and volumes without privileged/host namespace grants;
- every tracked shell script passes `bash -n` and ShellCheck 0.10.0, and the
  launcher failure tests reject unknown/duplicate `.env` keys and inherited
  device overrides.

Not physically verified:

- building the derivative image or resolving its apt dependencies;
- the installed SteamOS Podman Compose provider, crun, cgroup delegation, and
  actual enforcement of requested limits;
- noVNC/VNC authentication, audio, health checks, signals, and persistence;
- render-node access after privilege drop, Vulkan/DXVK, Proton, Viking Rise,
  or two simultaneous sessions.

The derivative build uses the Debian repositories configured in the pinned
base image. Those apt packages are not snapshot-pinned, so rebuilding later may
produce a different derivative even while the upstream base digest is fixed.

## Stop and preserve data

```bash
./steam-headless.sh down
```

This keeps named volumes. Do not use `down -v` unless deleting both Steam
profiles, installed games, and Proton prefixes is intentional.

## Physical acceptance gate on Steam Deck

The first `up-one` run must demonstrate all of the following before `up-two`:

1. the derivative image builds and `/usr/bin/Xvfb` exists;
2. the container becomes healthy without adding privileges or DRM card/input;
3. the browser prompts for the VNC password and rejects a wrong password;
4. Steam starts, downloads Proton, and the final desktop process can use
   `/dev/dri/renderD128` without `EACCES` or llvmpipe fallback;
5. Viking Rise launches through Proton and remains usable;
6. CPU/RAM/PID limits and named mounts match the Compose model reported by
   `podman inspect`.

If any item fails, preserve logs and treat it as a blocker. Do not recover by
adding `privileged`, host namespaces, `/dev/dri/card0`, input devices, broad
capabilities, or unconfined security profiles.
