# pinokiocontrol — headless-first installer & control CLI for Pinokio

[![version](https://img.shields.io/badge/version-261126a--pub1-766b90)](https://github.com/iamnexa-us/pinokiocontrol)
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
  disk, so the installer restarts the app when it was running (only the
  processes of its own install are touched). No more "upgrade done" with the
  old build still in the air.
- **Auto-updater neutralized by default** — updates happen only when YOU run
  them, through the gate. No more silent self-destruction at 3 a.m.
- **Self-healing health checks** — binary, desktop entry, icons, permissions,
  launcher: anything broken is detected and repaired on the next run. Verdicts
  are always honest (`OK`, `OK with warnings`, or a clear failure — never a
  silent success).
- **Idempotent under torture** — run it 10× just to see if it breaks: nothing
  re-downloads, nothing breaks. A single-instance lock prevents concurrent runs.
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
never touches other session apps.

## What the installer decides (all honest, all logged)

| Machine state | Action |
|---|---|
| No Pinokio | **INSTALL** best compatible candidate |
| Older, latest compatible | **UPGRADE** (user data preserved; restarted if it was running) |
| Already best & healthy | **SKIP** — audits, downloads nothing |
| Critical file damage | **REINSTALL** same version (restarted if it was running) |
| Installed binary incompatible (GLIBC) | **REPAIR** — auto-downgrade to known-good |
| Latest incompatible | **PINNED** — keep known-good, explicit note |
| All candidates rejected, install healthy | **ADOPTION** — keep current, protect it |

## Variables (sandbox/testing)

`PINOKIO_INSTALLER_ROOT` (relocates ALL system paths), `PINOKIO_INSTALLER_REPO`,
`PINOKIO_INSTALLER_STATE_DIR`, `PINOKIO_INSTALLER_DL_DIR`,
`PINOKIO_INSTALLER_VERSION` (exact pin), `PINOKIO_INSTALLER_KNOWN_GOODS`,
`PINOKIO_ALLOW_AUTOUPDATE`, `PINOKIO_SKIP_AUTOSTART`, `PINOKIOCONTROL_BIN_DIR`,
`PINOKIOCONTROL_LINK_DIR`, `PINOKIO_GATE_CACHE_TTL`, `GITHUB_TOKEN`.

## License

**MIT** — Author: **Louise**, in partnership with **Marco**.
The installer and CLI are MIT; Pinokio and its binaries belong to their
respective authors ([pinokiocomputer/pinokio](https://github.com/pinokiocomputer/pinokio)).

Issues and PRs are welcome! 💙

---

Our content is made by a family with much love, people like you. Visit
https://iamnexa.us/
