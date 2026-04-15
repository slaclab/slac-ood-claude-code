# TODO #002 — Patch ttyd to support password file auth

> **Priority:** 🔵 P3 — Low
> **Status:** 📋 Preparing
> **Branch:** —
> **PR:** —
> **Created:** 2026-04-15
> **Shipped:** —

---

## Problem Statement

ttyd's `-c user:pass` flag passes the password as a command-line argument, making
it visible in `/proc/cmdline` and `ps aux` output on the node. Any user with access
to the interactive node can read another user's ttyd password.

The current `bc_claude_code` app uses `-c` as a secondary auth layer (in addition
to `--auth-header X-Forwarded-User`) and accepts this risk. This task eliminates
the exposure by patching ttyd to support reading credentials from a file (e.g.
`--credential-file /path/to/creds`) so the password never appears in the process list.

### What fails today

| Scenario | Current behaviour | Desired behaviour |
|----------|-------------------|-------------------|
| `ps aux` on interactive node | ttyd password visible in cmdline args | No password in process list |
| `/proc/<pid>/cmdline` | Raw `user:pass` readable by any local user | File path only, contents not exposed |

---

## Goals

1. ttyd accepts a `--credential-file <path>` flag (or equivalent) that reads `user:pass` from a file
2. `before.sh.erb` writes the credential file with `umask 077` (owner-read only)
3. `script.sh.erb` passes `--credential-file` instead of `-c user:pass`
4. Password does not appear in `ps aux` or `/proc/*/cmdline`

## Non-Goals

- Upstream contribution to ttyd (nice to have but not required)
- Replacing `--auth-header X-Forwarded-User` — both layers stay

---

## Design

Build a patched ttyd SIF image (or patch the existing `slaclab/claude-code` image)
that adds `--credential-file` support to ttyd. The patch is a small addition to
`server.c` — read the file at startup, populate `server->credential`, then proceed
as normal.

Alternatively, wrap ttyd with a small shim script inside the SIF that reads the
file and execs ttyd with `-c $(cat $CREDENTIAL_FILE)` — simpler but the password
still briefly appears in the exec args. A proper patch is cleaner.

---

## Implementation Plan

### Step 1 — Fork / patch ttyd
Add `--credential-file` flag to ttyd `server.c`. Read file at startup, set
`server->credential`. Build patched binary.

### Step 2 — Rebuild claude-code SIF
Include patched ttyd in `slaclab/claude-code` Docker image. Push new SIF.

### Step 3 — Update bc_claude_code
- `before.sh.erb`: write credential file with `umask 077`, export path
- `script.sh.erb`: replace `-c "${TTYD_USER}:${TTYD_PASS}"` with `--credential-file "${CREDENTIAL_FILE}"`

### Step 4 — Verify
- `ps aux | grep ttyd` — no password in args (AC-6)
- `/proc/<pid>/cmdline` — no password visible

---

## Implementation Checklist

- [ ] ttyd patched to support `--credential-file`
- [ ] Patched ttyd built and included in claude-code SIF
- [ ] `before.sh.erb` updated to write credential file
- [ ] `script.sh.erb` updated to use `--credential-file`
- [ ] AC-6 verified: no password in `ps aux` output

---

## Relationship to Other Tasks

- **#001 (OOD App):** This task improves the security posture of #001. #001 ships
  with the `-c user:pass` accepted risk; this task eliminates it.
