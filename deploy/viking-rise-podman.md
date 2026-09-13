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

- `Dockerfile.viking-rise` (repo root) - builds the image. `podman build -f`
  is explicit about the file, so the `Dockerfile.*` name is kept rather than
  renamed to `Containerfile`; it carried over from the repository this
  started in and there is no reason to churn it.
- `viking-rise-entrypoint.sh` (repo root) - container entrypoint: machine-id
  initialization, Xvfb, x11vnc, then Steam.
- `deploy/viking-rise-podman.sh` - build + run script.
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

## Expected experience and its limits

This stack is remote *desktop*, not game streaming, and that ceiling is
structural rather than a tuning problem:

- **No audio at all.** `x11vnc` carries framebuffer updates and input
  events; it has no audio channel, and no sound server is installed in the
  image. Expect a silent game.
- **Input lag.** Every action is a round trip through the VNC protocol.
  Fine for clicking menus, poor for anything reflex-driven.
- **Not a smooth 60 FPS.** VNC transmits changed screen regions, so a
  full-screen animated 3D scene is close to its worst case.

For Viking Rise specifically - a strategy/management game driven by
discrete clicks rather than reflexes, and playable muted - these limits are
mostly tolerable, which is what makes the MVP worth trying at all.

If the experience turns out to be insufficient after a real test, the
natural next step is to stop using VNC for the game itself: **Sunshine +
Moonlight** (hardware-encoded H.264/HEVC with audio and far lower latency)
or **Steam Remote Play**, keeping this container as the thing that hosts
the session. Both are out of scope here and neither has been tried.

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

The image does not contain a pre-generated `/etc/machine-id`. On the first
start of a container, the entrypoint initializes it via
`dbus-uuidgen --ensure=/etc/machine-id` and links
`/var/lib/dbus/machine-id` to it. Subsequent restarts of that same
container keep the ID stable. Removing and recreating the container creates
a new ID, which is appropriate for this PoC because that is a new container
instance.

If machine identity ever needs to survive container recreation, persist
`/etc/machine-id` separately. It is intentionally not stored in the Steam
home volume because machine identity and application data have different
lifecycles. This container has no systemd as PID 1, so
`systemd-machine-id-setup` isn't used; the `dbus` package provides
`dbus-uuidgen`.

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

VNC password authentication is required by default. See
[VNC authentication](#vnc-authentication). An explicit unauthenticated
mode exists only for loopback-only local testing; the deploy script refuses
to combine it with a non-loopback bind.

## Build and run

```bash
cd /path/to/viking-rise-podman   # repository root
cp deploy/viking-rise.env.example deploy/viking-rise.env   # optional, to override defaults
x11vnc -storepasswd '<VNC password>' deploy/viking-rise-vnc.passwd
chmod 600 deploy/viking-rise-vnc.passwd
deploy/viking-rise-podman.sh
```

The script:

- Checks that `/dev/dri/renderD128` exists and is readable/writable.
- Creates the `viking-rise-net` Podman bridge network if missing. If it
  already exists, the script refuses non-bridge networks and any foreign
  attached container (see [Network isolation](#network-isolation)).
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

The image, deploy script, and entrypoint deliberately fix the account and
home to `steamuser` and `/home/steamuser`. They are not configurable in
this MVP, which prevents the volume mount point from diverging from the
HOME Steam actually uses. On first start the entrypoint chowns the volume
to that user once; later starts detect correct ownership and skip the
recursive pass.

## Privilege drop

The container starts as root only long enough to initialize
`/etc/machine-id` when needed, fix volume ownership, and start `Xvfb` and
`x11vnc`. It
then `exec`s Steam through `runuser` as the unprivileged user, because
Steam refuses to run as root.

One consequence is easy to miss: GPU access is evaluated as *that* user,
not root. If `/dev/dri/renderD128` is passed through but is not
readable/writable by it, the only symptom is a silently software-rendered
(llvmpipe) game. The entrypoint therefore probes the device as the target
user and warns explicitly instead of leaving it unexplained.

## Port choice

`15900` was chosen for the VNC publish:

- It doesn't collide with services already running on `steamdeck`: 8080
  (label-studio) or 18790 (router-web).
- It keeps the recognizable VNC `5900` suffix while sitting in the same
  high `1xxxx` range as the other services on that host.
- It avoids clashing with a real VNC server that might already be running
  on the conventional `5900` port on the host itself.

## VNC authentication

Required by default. Create a password file on the host:

```bash
x11vnc -storepasswd '<password>' deploy/viking-rise-vnc.passwd
chmod 600 deploy/viking-rise-vnc.passwd
```

The deploy script mounts it read-only and `x11vnc` runs with `-rfbauth`.
With `VIKING_RISE_VNC_AUTH=password` (the default), a missing, non-regular,
unreadable, or incorrectly permissioned file is fatal. The entrypoint also
fails closed if the expected bind mount is unavailable inside the
container.

For deliberate loopback-only local testing, set
`VIKING_RISE_VNC_AUTH=none`. The deploy script rejects that mode unless
`VIKING_RISE_VNC_BIND=127.0.0.1`; selecting a non-loopback bind requires
password mode. VNC authentication does not encrypt the transport.

This is a **VNC password only**. No Steam credential belongs in it, or
anywhere else in this project - the Steam login stays manual.

Treat it as a second layer, never the primary one. VNC's built-in scheme is
DES-based, silently truncates the password to 8 characters, and runs over
an unencrypted transport; anyone who can see the traffic can see the
session. The loopback publish and the dedicated network remain the real
controls.

In explicit `none` mode, any local process on the host can reach
`127.0.0.1:15900` and take over a logged-in Steam session.

## Network isolation

**Rule: this container gets a Podman bridge network of its own and never
shares one.** `viking-rise-net` exists for that and holds nothing else.
Before starting, the deploy script inspects an existing network and refuses
it if its driver is not `bridge` or if any container other than the named
Viking Rise container is attached. A newly created network is labelled
`io.viking-rise.network=dedicated` for identification; the attachment check,
not the label, enforces the rule.

Why: `x11vnc` listens on `0.0.0.0:5900` inside the container. The
`--publish 127.0.0.1:15900:5900` bind restricts access arriving through the
*host* only - it does nothing about traffic between containers on the same
bridge. In explicit `none` mode, anything co-attached could get an
unauthenticated interactive session. In password mode, VNC remains an
unencrypted legacy protocol and should not be exposed to unrelated
co-tenants.

So the bar for a co-tenant is not "is this service trusted today" but "is
it acceptable for this service, at any future point, to own the Steam
account". In practice nothing clears that bar, and Steam needs only
outbound internet, so an unshared network costs nothing.

Consequences to keep in mind:

- Password authentication, the loopback publish, and network separation are
  independent layers. Explicit `none` mode retains only the latter two.
- A non-loopback bind is accepted only in password mode, but `-rfbauth`
  does not encrypt the transport; use a trusted network or an encrypted
  tunnel.
- Even with authentication, VNC's built-in scheme is DES-based and silently
  truncates passwords to 8 characters, over an unencrypted transport. Treat
  it as a second layer, never as the primary one.

## What has and hasn't been verified

This was prepared in an environment with **no `podman`, no `docker`, and no
`/dev/dri`**. Be precise about what that means.

Actually verified:

- `bash -n` (syntax-only parse) passes for `viking-rise-entrypoint.sh` and
  `deploy/viking-rise-podman.sh`.
- **ShellCheck 0.10.0 reports zero findings** on both scripts
  (`shellcheck -s bash`, exit 0). It is not installed in this environment;
  the upstream static binary was run from a temporary directory.
- Every package the image installs exists in Ubuntu 22.04 (jammy):
  `steam-installer`, `xvfb`, `x11vnc`, `dbus`, `mesa-vulkan-drivers`,
  `mesa-va-drivers`, `libgl1-mesa-dri`, `ca-certificates`, `procps`,
  `fontconfig`, `fonts-liberation`, `software-properties-common`. The two
  i386 variants the build depends on - `mesa-vulkan-drivers:i386` and
  `libgl1-mesa-dri:i386` - are also published for i386 on jammy, which
  matters because jammy ships only a whitelisted subset of i386 packages.
- The Steam packaging facts in "Steam packaging notes" above, read directly
  from the Ubuntu `steam` source package and the jammy package file lists:
  the `/usr/games/steam` path, the i386-only `steam` package, the
  `steam-installer` dependency shim, and the debconf template names/types.
- `dbus-uuidgen` is shipped by the `dbus` package on jammy
  (`/usr/bin/dbus-uuidgen`), which is why `dbus` is installed. There is no
  systemd here, so `systemd-machine-id-setup` is not an option.
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
- Whether `apt-get` actually *resolves* the full set on a real jammy image.
  Each package is confirmed to exist, but a real dependency solve - version
  conflicts, i386/amd64 co-installability, `add-apt-repository multiverse`
  succeeding in the build - was never run.

Test on `steamdeck` before relying on this.
