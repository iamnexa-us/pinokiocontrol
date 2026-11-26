# pinokiocontrol — headless-first installer & control CLI for Pinokio

[![version](https://img.shields.io/badge/version-261126c--pub1-766b90)](https://github.com/iamnexa-us/pinokiocontrol)
[![platform](https://img.shields.io/badge/platform-Linux-informational?logo=linux&logoColor=white)](https://github.com/iamnexa-us/pinokiocontrol)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![GitHub repo](https://img.shields.io/badge/github-pinokiocontrol-181717?logo=github&logoColor=white)](https://github.com/iamnexa-us/pinokiocontrol)

**English** | [Português](README.pt-BR.md)

Pinokio is a wonderful app — on a desktop. On **servers and headless machines**,
installing it, keeping it updated, and recovering it when an update goes wrong is
hard: there is no desktop to click, an auto-updater that installs a broken build
takes the machine down, and a crash on a mature distro (Debian, Ubuntu LTS, Mint)
leaves you with a service that dies on launch.

That is the pain we lived — so we built the cure. One line installs Pinokio from
the **official source**; after that, `pinokiocontrol` keeps it healthy, safely
updated, and fully manageable **from the terminal**.

```bash
curl -fsSL https://raw.githubusercontent.com/iamnexa-us/pinokiocontrol/main/install.sh | sudo bash
```

## Why you want this on a server

- **GLIBC gate** — before installing any release, the installer opens the `.deb`
  and checks the native binaries against your system's glibc. A release that
  would crash on launch is refused, with automatic fallback to the last
  known-good version. (Born from a real incident: upstream 8.4.0 was built on a
  rolling CI image requiring `GLIBC_2.42` and took down whole fleets on
  Debian 12/13 and Ubuntu LTS.) The gate's cache is tied to the **identity of
  the asset** it evaluated (sha256): if upstream replaces a `.deb` under the
  same tag — as it did with 8.4.1 on 2026-11-25 — the installer re-evaluates
  it by itself instead of trusting a stale verdict.
- **Restarts after an upgrade** — UPGRADE/REPAIR/REINSTALL swap the files on
  disk, so the installer restarts the app when it was running. Expect about
  one minute without the UI and without SearXNG. Only the processes whose
  executable lives in `/opt/Pinokio` are touched; the relaunch runs in its
  own systemd scope (never in the cgroup of whoever ran the installer); and
  the verdict checks that the app — and the SearXNG that was up before —
  actually came back. `PINOKIO_SKIP_AUTOSTART=1` skips the restart (the old
  build keeps running; the installer says so). If the isolated launch cannot
  start, it tries once more without isolation and says so. And a `/proc` scan
  that fails is never read as "the app is stopped": the installer and
  `pinokiocontrol` refuse (rc=1) instead of acting on a guess.
- **Never downgrades a healthy install** — when the latest release is
  refused, the installer only moves to a known-good that is *newer* than
  what is installed. A healthy install above the known-good stays where it
  is. (Until v.261126a the one-liner silently downgraded it.) An explicit
  `PINOKIO_INSTALLER_VERSION` can still roll back on purpose. Critical file
  damage on that install is still repaired (REINSTALL of the same version),
  and `pinokiocontrol --update` notices when the app binary is missing.
- **`PINOKIO_INSTALLER_KNOWN_GOODS` is validated first** — the list is
  injected into the generated `pinokiocontrol`, so anything other than
  space-separated versions (quotes, newlines, shell syntax) stops the
  installer before it touches the machine.
- **Auto-updater neutralized by default** — updates happen only when YOU run
  them, through the gate. No more silent self-destruction at 3 a.m.
- **Self-healing health checks** — binary, desktop entry, icons, permissions,
  launcher: anything broken is detected and repaired on the next run. Verdicts
  are always honest (`OK`, `OK with warnings`, or a clear failure — never a
  silent success).
- **Idempotent under torture** — run it 10× just to see if it breaks: nothing
  re-downloads (at most once every 24 h when the GitHub API does not report
  the asset digest), nothing breaks. A single-instance lock prevents
  concurrent runs.
- **Full terminal control** — no desktop required, ever.

## pinokiocontrol

```
pinokiocontrol --status               # versions (local + upstream), running?,
                                      # port, GLIBC compatibility, persistence
pinokiocontrol --update               # update script and/or Pinokio (gated)
pinokiocontrol --start | --stop | --restart
pinokiocontrol --persistent ON|OFF    # whether it comes back on next boot
pinokiocontrol --help | --version
```

`--stop` escalates gracefully (TERM → up to 10 s → KILL) and waits for real
death before returning. `--persistent` only manages its own registration and
never touches other session apps. `--status` does not need root; without
root it answers `ativo: n/d` instead of a wrong "not running" (it cannot
read `/proc/<pid>/exe` of other users' processes). `--start`, `--stop` and
`--restart` refuse (rc=1) when the `/proc` scan fails, rather than act on
a guess.

## What the installer decides (all honest, all logged)

| Machine state | Action |
|---|---|
| No Pinokio | **INSTALL** best compatible candidate |
| Older, latest compatible | **UPGRADE** (user data preserved; restarted if it was running) |
| Already best & healthy | **SKIP** — audits, downloads nothing |
| Critical file damage | **REINSTALL** same version (restarted if it was running) |
| Installed binary incompatible (GLIBC) | **REPAIR** — auto-downgrade to known-good |
| Latest incompatible | **PINNED** — keeps the newest compatible version (never a silent downgrade), explicit note |
| All candidates rejected, install healthy | **ADOPTION** — keep current, protect it |

## Variables (sandbox/testing)

`PINOKIO_INSTALLER_ROOT` (relocates ALL system paths), `PINOKIO_INSTALLER_REPO`,
`PINOKIO_INSTALLER_STATE_DIR`, `PINOKIO_INSTALLER_DL_DIR`,
`PINOKIO_INSTALLER_VERSION` (exact pin), `PINOKIO_INSTALLER_KNOWN_GOODS`,
`PINOKIO_ALLOW_AUTOUPDATE`, `PINOKIO_SKIP_AUTOSTART`, `PINOKIOCONTROL_BIN_DIR`,
`PINOKIOCONTROL_LINK_DIR`, `PINOKIO_GATE_CACHE_TTL`, `PINOKIO_SEARX_WAIT`, `GITHUB_TOKEN`.

## License

**MIT** — Author: **Louise**, in partnership with **Marco**.
The installer and CLI are MIT; Pinokio and its binaries belong to their
respective authors ([pinokiocomputer/pinokio](https://github.com/pinokiocomputer/pinokio)).

Issues and PRs are welcome! 💙

---

Our content is made by a family with much love, people like you. Visit
https://iamnexa.us/
