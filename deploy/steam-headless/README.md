# Steam Headless multi-instance spike (plain Podman)

## Verdict: PARTIAL

This profile tests whether two isolated Steam + Proton sessions can run on one
Steam Deck under rootless Podman and be administered through noVNC in a browser.
It uses ordinary `podman build/run/inspect`; **Podman Compose is not required**.

The upstream Steam Headless image provides Steam, Proton support, Xfce,
supervisord and noVNC. The local derivative adds the missing `Xvfb` package,
preserves rootless GPU groups while dropping to the desktop UID, and requires
VNC authentication. Each instance has its own bridge, home volume, game volume
and loopback-only browser port. The launcher supplies an explicit recursive DNS
upstream because the physically tested SteamOS Podman/Aardvark bridge could not
resolve external names with its host-derived upstream configuration.

No container has been run in the development environment. Vulkan/DXVK through
framebuffer mode and GPU access on SteamOS remain unproved. Test one instance
before starting the second.

## Why framebuffer mode

Upstream `primary` mode starts Xorg against a DRM card. Multiple primary X
servers can contend for DRM master, including with the SteamOS desktop.
`MODE=framebuffer` uses Xvfb and only `/dev/dri/renderD128`.

Direct inspection of the pinned upstream image layer found `xserver-xorg-core`
but no `/usr/bin/Xvfb`. The derivative Containerfile installs Debian's `xvfb`,
`procps` and `util-linux` packages and verifies the required binaries.

This profile deliberately does **not** grant `/dev/dri/card0`, input devices,
host network/IPC/PID, extra capabilities, privileged mode or unconfined
security profiles. Xvfb does not provide accelerated GLX, so Proton may fail to
present or may use software rendering despite access to the render node.

## Prepare

Run as the normal SteamOS user, never with `sudo`:

```bash
cd /path/to/viking-rise-podman/deploy/steam-headless
cp .env.example .env
chmod 600 .env
id -u
id -g
openssl rand -hex 16
openssl rand -hex 16
```

The only container CLI dependency is ordinary Podman. Do **not** run
`podman compose version` and do not install `podman-compose`: this profile
does not use a Compose provider. Verify the required host tools with:

```bash
podman --version
crun --version
```

If Podman prints `No Compose provider is available through podman compose`,
then a `podman compose ...` command was invoked outside this launcher. Use the
commands in this document instead; `steam-headless.sh` calls only
`podman build`, `podman run`, `podman inspect` and related direct commands.

Set `PUID`/`PGID` to the displayed IDs and put the two generated values in
`INSTANCE_1_OS_PASSWORD` and `INSTANCE_2_OS_PASSWORD`. They protect the local
container account and VNC backend. Never put Steam credentials in `.env`.
x11vnc uses only the first eight password characters, so those prefixes must
differ. `DNS_SERVER` defaults to `1.1.1.1`; replace it with another reachable
IPv4 recursive resolver if policy requires one.

## Build and test one instance

```bash
./steam-headless.sh check
./steam-headless.sh build
./steam-headless.sh up-one
podman logs -f viking-rise-steam-1
```

Open <http://127.0.0.1:15901/> on the Steam Deck, enter the first local VNC
password, then log into Steam manually. Enable Steam Play/Proton and install
Viking Rise. VNC/noVNC transport is not encrypted; keep the endpoint on host
loopback or use an SSH tunnel from another machine.

Only after the first instance demonstrates usable Vulkan/Proton behavior:

```bash
./steam-headless.sh up-two
podman logs -f viking-rise-steam-2
```

Open <http://127.0.0.1:15902/> for the second instance.

## Launcher actions

- `check`: validates `.env`, rootless local Podman, crun, cgroup v2, resource
  ranges, loopback ports and the DRM render node. It changes nothing.
- `build`: builds `localhost/viking-rise-steam-headless:xvfb` from the pinned
  base digest. It does not read `.env` and does not start containers.
- `up-one` / `up-two`: use only direct `podman run` calls. They require the
  image to have been built explicitly and recreate only labelled containers.
- `down`: removes only correctly labelled project containers and their private
  networks. It does not need `.env` or a GPU and preserves named volumes.

The launcher refuses to remove a same-named container/network or reuse a volume
unless its project/purpose labels match. Networks are checked for foreign
members before launch.

## Persistence and cleanup

The named volumes are:

```text
viking-rise-steam-1-home
viking-rise-steam-1-games
viking-rise-steam-2-home
viking-rise-steam-2-games
```

Stop and remove managed containers while retaining those volumes:

```bash
./steam-headless.sh down
```

Deleting volumes is intentionally not automated because it destroys Steam
profiles, Proton prefixes and installed games.

## Security and compatibility boundaries

- The third-party image is pinned to
  `sha256:0d43c66ad0cf54cb0e51208b30f1f297d78264807661a581691224caa4dec0c0`.
  Pinning prevents tag drift; it does not establish provenance or remove CVEs.
- Rootless **local** Podman, `crun` and cgroup v2 are mandatory. Remote Podman
  endpoints are rejected.
- Only a canonical DRM render node (major 226, minor 128+) is accepted.
- Resource overrides have bounded ranges. Their actual enforcement must still
  be inspected after launch; named-volume disk growth is unbounded.
- The private bridge's Aardvark DNS proxy forwards external queries to the
  configured `DNS_SERVER` instead of its broken host-derived upstream. This
  does not expose a host port or grant a host network namespace.
- The VNC password is passed to Podman through a temporary mode-600 env file,
  not as a command-line value. It remains visible to the invoking user through
  container inspection because the upstream image consumes `USER_PASSWORD`.
- Other local host users can reach loopback and attempt VNC authentication.
  The container account has passwordless sudo inside the rootless user
  namespace; that is not host root, but it can access the mapped volumes and
  render node.
- `--group-add keep-groups` plus the derivative desktop wrapper is intended to
  preserve render-node access after UID/GID drop. This requires physical
  verification from the final Steam process on SteamOS.
- Both instances share one physical APU and unified memory. Container isolation
  does not create separate GPUs or guarantee protection from kernel/GPU bugs.

## Acceptance checklist

Before `up-two`, verify:

1. `up-one` becomes healthy and `podman logs` shows no Xvfb/x11vnc failures.
2. noVNC rejects a wrong password and accepts the configured one.
3. Steam starts without render-node `EACCES` or llvmpipe fallback.
4. Proton downloads and Viking Rise launches.
5. `podman inspect viking-rise-steam-1` shows only renderD128, a private bridge,
   loopback port 15901, the expected volumes and requested limits.
6. Recreating the container preserves Steam state and installed game data.

If it fails, keep logs and treat that as a blocker. Do not add privileged
mode, DRM card/input devices, host namespaces, broad capabilities or
unconfined profiles as a compatibility shortcut.

## Verification evidence

Development-side checks cover shell syntax/lint, direct-command mock scenarios,
exact option construction, env-parser failures, label guards and static package
evidence. They do **not** cover a real Podman build/run, GPU, VNC/noVNC, audio,
Proton, Viking Rise, persistence or concurrent sessions.
