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

- Uses `/dev/dri/renderD128` only, and expects it to be world-readable/
  writable (`crw-rw-rw-`) on `steamdeck`. This was **not** re-verified while
  preparing this change - the environment it was written in has no `/dev/dri`
  at all - so the deploy script checks for the node and its permissions at
  runtime rather than assuming them. `/dev/dri/card0` is intentionally not touched
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

## Steam packaging notes

Verified against the Ubuntu 22.04 `steam` source package
(`steam_1.0.0.74-1ubuntu2`):

- `steam-installer` is an architecture-independent shim that depends on the
  real `steam` package, which jammy ships **for i386 only**. That is why the
  image enables the i386 architecture before installing.
- The launcher is installed as **`/usr/games/steam`**
  (`debian/steam.install`). `/usr/games` is not on the default container
  `PATH`, so the entrypoint calls it by absolute path.
- The debconf preseed uses real templates: `steam/question` is a `select`
  whose choices are `I DECLINE, I AGREE`, and `steam/license` is a `note`
  (`debian/scripts/templates-helper`). No maintainer script in this version
  prompts via `db_input`, so the preseed is defensive rather than strictly
  required - it is kept so the build cannot become interactive.
- `--no-install-recommends` is used, so `steam`'s Recommends are dropped
  except the ones added back explicitly (Mesa drivers, `fontconfig`,
  `fonts-liberation`). If a real run shows a broken Steam UI, `libegl1`,
  `libgbm1`, `zenity`, `xdg-utils`, and `libxss1` are the first things to add.

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

This was prepared in an environment with **no `podman`, no `docker`, no
`shellcheck`, and no `/dev/dri`**. Be precise about what that means.

Actually verified:

- `bash -n` (syntax-only parse) passes for `viking-rise-entrypoint.sh` and
  `deploy/viking-rise-podman.sh`.
- The Steam packaging facts in "Steam packaging notes" above, read directly
  from the Ubuntu `steam` source package and the jammy package file lists:
  the `/usr/games/steam` path, the i386-only `steam` package, the
  `steam-installer` dependency shim, and the debconf template names/types.
- `dbus-uuidgen` is shipped by the `dbus` package on jammy
  (`/usr/bin/dbus-uuidgen`).
- No Steam credentials, tokens, or 2FA material appear anywhere in these
  files.

Not verified - never executed, by anyone, yet:

- The image has never been built. `podman build` has not run once.
- The container has never been started; no `podman run`, no logs.
- `/dev/dri/renderD128` passthrough, and whether Mesa inside the container
  matches the host `amdgpu` kernel module.
- Any VNC connection to port `15900`, and whether the Steam window actually
  appears on the Xvfb display.
- Steam itself: first-run bootstrap, the login screen, login, and whether
  Viking Rise launches or is playable at any framerate.
- Whether `apt-get` resolves every listed package on a real jammy image
  (package *existence* was checked; a full dependency solve was not).

Test on `steamdeck` before relying on this.
