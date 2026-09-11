# Viking Rise Steam client (Podman MVP)

Proof-of-concept container running the Steam client (for Viking Rise) on
host `steamdeck` under Podman. **Not a final architecture** - kept as
simple as possible on purpose.

## What this is

- A container with the native Steam client plus Mesa userspace drivers,
  rendering through the host's AMD GPU render node.
- `Xvfb` (virtual X display) starts first; Steam runs on it. `x11vnc`
  exposes that same display for remote viewing/input.
- The VNC port is published to `127.0.0.1` on the host only.
- Steam session data (login, library metadata, etc.) persists in a named
  Podman volume mounted at `steamuser`'s home directory, so it survives
  container restarts.

## Files

- `Dockerfile.viking-rise` (repo root) - builds the image. Named to match
  the existing top-level `Dockerfile.router-web` convention rather than
  `Containerfile.viking-rise`, for consistency within this repo.
- `viking-rise-entrypoint.sh` (repo root) - container entrypoint: machine-id
  regeneration, Xvfb, x11vnc, then Steam.
- `deploy/viking-rise-podman.sh` - build + run script, modeled on
  `deploy/router-web-podman.sh`.
- `deploy/viking-rise.env.example` - documents the overridable variables.
  Copy to `deploy/viking-rise.env` for local overrides (gitignored). None of
  these values are secrets.

## Base image choice

Ubuntu 22.04. Valve officially supports and QA-tests the desktop Steam
client against Ubuntu, and Ubuntu's `multiverse` component carries the same
`steam-installer` package Debian ships in `contrib`/`non-free` - on Ubuntu
it only takes one `add-apt-repository multiverse` call, instead of
hand-editing apt sources to enable `contrib`+`non-free` on Debian. That made
Ubuntu the simpler, more reliably reproducible choice for a Containerfile.

`steam-installer` (native `.deb`) was chosen over the Flatpak build because
it installs cleanly with plain `apt-get` in a container build (no Flatpak
daemon/sandbox layer needed inside an already-containerized environment),
and it's the same package family already referenced in Valve/Debian/Ubuntu
documentation for this use case.

## GPU / rendering

- Uses `/dev/dri/renderD128` only (confirmed world-readable/writable on
  `steamdeck`: `crw-rw-rw-`). `/dev/dri/card0` is intentionally not touched
  - it's root/video-restricted and not needed for render-only access.
  `mesa-vulkan-drivers`, `mesa-va-drivers`, and `libgl1-mesa-dri` (amd64 +
  i386, since the Steam client itself is a 32-bit binary) are installed to
  match the host's kernel `amdgpu` module.
- Plain `--device /dev/dri/renderD128:/dev/dri/renderD128` is used - Podman
  CDI is not visible in `podman info` on this host, so no CDI syntax is
  used anywhere.
- **Known limitation:** `Xvfb` is a pure software X server; it does not do
  hardware-accelerated GLX itself. Client apps that render straight to
  `/dev/dri/renderD128` via EGL/Vulkan (bypassing GLX) can still use the
  real GPU, but getting a *displayed, in-VNC* 3D game window fully
  GPU-accelerated typically needs an extra bridging layer (e.g. VirtualGL)
  on top of this. That's out of scope for this MVP - flagging it here
  instead of silently pretending it's solved. Confirm actual in-game
  performance after a real deploy, and treat this as a likely next
  iteration.

## Machine-id

The entrypoint removes and regenerates `/etc/machine-id` (and the
`/var/lib/dbus/machine-id` symlink) on every container start via
`dbus-uuidgen --ensure=/etc/machine-id`. This container has no systemd as
PID 1, so `systemd-machine-id-setup` isn't used; `dbus-uuidgen` is the
documented way to (re)initialize `/etc/machine-id` without a running
systemd instance, and the `dbus` package is installed specifically to
provide it.

## Steam login - manual only

**No automated Steam login of any kind exists in this project.** No
username, password, 2FA, or Steam token appears in the Containerfile, the
entrypoint script, the deploy script, or any env file - by design, and this
must not change. After the container starts:

1. Connect a VNC client to `127.0.0.1:<VIKING_RISE_VNC_PORT>` on
   `steamdeck` (default port below), or tunnel it from another machine,
   e.g. `ssh -L 15900:127.0.0.1:15900 steamdeck`.
2. The Steam client window appears on the virtual display.
3. Log into Steam by hand (including any 2FA prompt) directly in that VNC
   session.

VNC currently has no password (`x11vnc -nopw`) and relies entirely on the
`127.0.0.1`-only publish for protection. Do not change the bind address to
`0.0.0.0`/a LAN address without adding real VNC authentication first.

## Build and run

```bash
cd /path/to/yolostaff   # repository root
cp deploy/viking-rise.env.example deploy/viking-rise.env   # optional, to override defaults
deploy/viking-rise-podman.sh
```

The script:

- Checks that `/dev/dri/renderD128` exists and is readable/writable.
- Creates the `yolostaff-net` Podman network if missing (same network
  `router-web-podman.sh` uses).
- Creates the `viking-rise-steam-data` named volume if missing.
- Builds `Dockerfile.viking-rise`.
- Runs the container, publishing VNC to `127.0.0.1:15900` (host) ->
  `5900` (container), with `--device /dev/dri/renderD128:/dev/dri/renderD128`
  and the data volume mounted at `/home/steamuser`.

## Session persistence

`/home/steamuser` (covering `~/.steam` and `~/.local/share/Steam`, where
the native Steam install keeps login state and library metadata) is
mounted from the `viking-rise-steam-data` named volume. As long as that
volume isn't deleted (`podman volume rm`), a logged-in Steam session
survives `podman rm`/recreate and host reboots.

## Port choice

`15900` was chosen for the VNC publish:

- It doesn't collide with existing project ports 8080 (label-studio) or
  18790 (router-web).
- It keeps the recognizable VNC `5900` suffix while sitting in the same
  high `1xxxx` range as `18790`, so it reads as "belongs to this project"
  at a glance.
- It avoids clashing with a real VNC server that might already be running
  on the conventional `5900` port on the host itself.

## What has and hasn't been verified

This was prepared without access to a real Podman/GPU/display environment.
See the PR description and session report for the exact list of what was
checked (shellcheck/Containerfile syntax) versus what was not run
physically (image build, container start, `/dev/dri` access, VNC connect,
Steam/game behavior). Test on `steamdeck` before relying on this.
