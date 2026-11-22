# Security Policy

## Reporting a vulnerability

If you find a security issue in this project, please report it privately to
**security@iamnexa.us** — do not open a public issue for vulnerabilities.

- Include reproduction steps and, when possible, the exact commit affected.
- We will respond as soon as possible and credit reporters when the fix ships
  (unless you prefer to remain anonymous).

## Design notes you can rely on

- The installer only downloads from **official sources** (the project's own
  release artifacts), with SHA-256 verification whenever the release API
  provides a digest.
- The **GLIBC gate** inspects binaries *before* installing them, refusing
  releases that would not load on the target system.
- The internal auto-updater is **neutralized by default** — updates happen only
  when the operator runs them, through the gate.

## Scope

This policy covers `install.sh` and `pinokiocontrol` from this repository.
Vulnerabilities in Pinokio itself should be reported upstream to
[pinokiocomputer/pinokio](https://github.com/pinokiocomputer/pinokio).
