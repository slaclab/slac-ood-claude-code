# TODO #002 — Patch ttyd to support password file auth

> **Priority:** 🔵 P3 — Low
> **Status:** ✅ Merged
> **Branch:** —
> **PR:** —
> **Created:** 2026-04-15
> **Shipped:** 2026-04-15

---

## Problem Statement

ttyd's `-c user:pass` flag passes the password as a command-line argument, making
it visible in `ps aux` and `/proc/cmdline` on the node — confirmed in dev:

```
ttyd --port 12258 --base-path /node/sdfiana007.../12258/ --auth-header X-Forwarded-User -c user:lRD1K2pE852XhdTV --writable claude
```

Any user on the interactive node can read another user's ttyd password. Because
the password is exposed this way, `-c` provides no actual security benefit over
`--auth-header X-Forwarded-User` alone — so it has been dropped from the current
`bc_claude_code` app until this is resolved.

This task adds `--credential-file` support to ttyd so the password never appears
in the process list, at which point `-c`-equivalent auth can be re-enabled as a
meaningful second layer.

### What fails today

| Scenario | Current behaviour | Desired behaviour |
|----------|-------------------|-------------------|
| `ps aux` on interactive node | ttyd password visible in cmdline args | No password in process list |
| `/proc/<pid>/cmdline` | Raw `user:pass` readable by any local user | File path only, contents not exposed |

---

## Goals

1. ttyd accepts a `--credential-file <path>` flag that reads `user:pass` from a file
2. The patched ttyd binary is compiled and baked into the `slaclab/claude-code` Docker image during the normal `make build` / `make push` workflow
3. `before.sh.erb` writes the credential file with `umask 077` (owner-read only)
4. `script.sh.erb` passes `--credential-file` instead of `-c user:pass`
5. Password does not appear in `ps aux` or `/proc/*/cmdline`

## Non-Goals

- Upstream contribution to ttyd (nice to have but not required)
- Replacing `--auth-header X-Forwarded-User` — both layers stay
- Encrypting the credential file (umask 077 + tmpfs is sufficient)

---

## Design

### Architecture

The patch is a minimal addition to ttyd's C source. The existing credential path in
`main.c` / `server.c` is:

```
getopt() parses -c user:pass
  → lws_b64_encode_string(optarg, ...)  (server.c)
  → server->credential = strdup(b64_text)
```

The new `--credential-file <path>` flag follows the same path, with a file read
inserted before the base64 encode:

```
getopt() parses --credential-file /path/to/file
  → read file contents → strip trailing newline
  → lws_b64_encode_string(contents, ...)
  → server->credential = strdup(b64_text)
```

The file is read once at startup and immediately closed. The contents are only ever
held in memory as a base64 string — identical security profile to the existing `-c`
path once loaded, but the plaintext never hits the process argument list.

### Build strategy: multi-stage Docker build

Rather than pre-building the binary externally, the patch and compile step are
embedded directly in `Dockerfile` as a new build stage. This means:

- `make build` / `make push` in `/sdf/home/y/ytl/k8s/claude-code/` is the only
  workflow required — no separate build step.
- The patched binary is always in sync with the image version.
- Build tools (`cmake`, `gcc`, `libwebsockets-dev`, etc.) are in the builder stage
  only and do not inflate the final image.

```
Stage 0: ttyd-builder (ubuntu:24.04)
  → apt-get install build-essential cmake libwebsockets-dev libjson-c-dev libssl-dev libuv-dev
  → git clone --depth 1 HEAD (latest main)
  → COPY ttyd-credential-file.patch → patch -p1
  → cmake build → /usr/local/bin/ttyd

Stage 1: final (existing FROM ubuntu:24.04 image)
  → COPY --from=ttyd-builder /usr/local/bin/ttyd /usr/local/bin/ttyd
  → (removes the curl-downloaded pre-built binary step entirely)
```

### Patch — `src/main.c`

ttyd uses `getopt_long`. The patch adds one entry to the `long_options[]` array and
one case to the `switch` block. Using `NULL` (not `'C'`) as the short-option value
avoids any risk of collision with future ttyd short options (long-only flag pattern):

```c
// In long_options[]:
{"credential-file", required_argument, NULL, 0},

// In switch(c) — case 0 with option_index check:
case 0:
    if (strcmp(long_options[option_index].name, "credential-file") == 0) {
        FILE *f = fopen(optarg, "r");
        if (!f) { lwsl_err("Cannot open credential file: %s\n", optarg); return 1; }
        char buf[512];
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        int read_err = ferror(f);
        fclose(f);
        if (read_err) { lwsl_err("Error reading credential file\n"); return 1; }
        if (n == 0) { lwsl_err("Credential file is empty\n"); return 1; }
        buf[n] = '\0';
        // Reject embedded null bytes
        if (strlen(buf) != n) {
            lwsl_err("Credential file contains null bytes\n");
            explicit_bzero(buf, sizeof(buf));
            return 1;
        }
        // Strip trailing newline/carriage return
        while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r')) buf[--n] = '\0';
        if (n == 0) { lwsl_err("Credential file empty after stripping\n"); return 1; }
        // Reuse existing credential encoding path
        char b64[768];
        int b64_len = lws_b64_encode_string(buf, (int)n, b64, sizeof(b64));
        explicit_bzero(buf, sizeof(buf));
        if (b64_len < 0) { lwsl_err("Base64 encoding failed\n"); return 1; }
        server->credential = strdup(b64);
        explicit_bzero(b64, sizeof(b64));
    }
    break;
```

Changes vs. original design: `ferror` check, null-byte rejection, `\r` stripping,
`explicit_bzero` on both stack buffers, `lws_b64_encode_string` return value check,
long-only flag (no short-option collision risk).

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Patch delivery | `COPY ttyd-credential-file.patch` + `patch -p1` in builder stage | Reviewable diff alongside Dockerfile; no escaping fragility |
| Build stage base | `ubuntu:24.04` (same as final) | Consistent glibc version; no compatibility issues |
| ttyd version | `git clone` + `git checkout 1.7.7` (pinned tag) | Supply-chain safety: reproducible builds, no poisoned-HEAD risk (security review HIGH finding) |
| Credential file location | `$OUTPUT_DIR/ttyd.cred` | OOD session output dir is per-session, user-owned, already used for other session artefacts |
| Credential file ownership | `umask 077` in `before.sh.erb` | Readable only by the session owner |
| File read timing | Once at startup, then closed | Minimises exposure window |

---

## Implementation Plan

### Step 1 — Write the patch file (`ttyd-credential-file.patch`)

Produce a unified diff against ttyd `1.7.7` that adds `--credential-file` to
`long_options[]` and the corresponding `case 'C'` handler (hardened version — see
Patch section above). Save as `ttyd-credential-file.patch` alongside the Dockerfile
in `/sdf/home/y/ytl/k8s/claude-code/`.

### Step 2 — Update `Dockerfile` (`/sdf/home/y/ytl/k8s/claude-code/Dockerfile`)

Prepend a `ttyd-builder` stage before the existing `FROM ubuntu:24.04` line, and
replace the `curl`-based ttyd install block with a `COPY --from`:

```dockerfile
# ── Stage 0: build patched ttyd ──────────────────────────────────────────────
FROM ubuntu:24.04 AS ttyd-builder
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    libwebsockets-dev \
    libjson-c-dev \
    libssl-dev \
    libuv-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG TTYD_VERSION=1.7.7
RUN git clone https://github.com/tsl0922/ttyd.git /ttyd \
    && git -C /ttyd checkout ${TTYD_VERSION}

COPY ttyd-credential-file.patch /ttyd-credential-file.patch
RUN patch -p1 -d /ttyd < /ttyd-credential-file.patch

RUN cmake -S /ttyd -B /ttyd/build \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /ttyd/build --parallel \
    && cmake --install /ttyd/build
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: final image (existing FROM line, unchanged) ─────────────────────
FROM ubuntu:24.04
...
# Replace the curl ttyd block with:
COPY --from=ttyd-builder /usr/local/bin/ttyd /usr/local/bin/ttyd
```

### Step 3 — Update `before.sh.erb` (`bc_claude_code/template/`)

`$OUTPUT_DIR` is set by the OOD framework to the session's output directory
(`~/ondemand/data/sys/dashboard/batch_connect/sys/bc_claude_code/output/<uuid>/`),
which is already user-owned and session-scoped. Write the credential file there.

Do **not** `export CREDENTIAL_FILE` — the path is interpolated directly in
`script.sh.erb` to avoid leaking it into child process environments.

```bash
# Write credential file into OOD session output dir (owner-read only, no cmdline exposure)
# Not exported — interpolated directly in script.sh.erb to avoid /proc/<pid>/environ leakage
(umask 077; printf '%s:%s' "${TTYD_USER}" "${TTYD_PASS}" > "${OUTPUT_DIR}/ttyd.cred")
```

### Step 4 — Update `script.sh.erb` (`bc_claude_code/template/`)

`script.sh.erb` currently has no `-c` flag (it was dropped). Add
`--credential-file` to the `apptainer exec` / `ttyd` invocation, bind-mount
`$OUTPUT_DIR`, and delete the credential file 2 seconds after launch (ttyd only
reads it at startup — the file is dead weight after that):

```bash
apptainer exec -B /sdf,/fs,/lscratch,"${OUTPUT_DIR}" "${CLAUDE_SIF}" \
  ttyd \
    --port ${port} \
    --base-path "/node/${host}/${port}/" \
    --auth-header X-Forwarded-User \
    --credential-file "${OUTPUT_DIR}/ttyd.cred" \
    --writable \
    claude &
TTYD_PID=$!

# Give ttyd time to read the credential file, then scrub it from disk.
# The file is only needed at startup; deleting it limits the exposure window.
sleep 2
rm -f "${OUTPUT_DIR}/ttyd.cred"

wait ${TTYD_PID}
```

### Step 5 — Rebuild and push image

```bash
make -C /sdf/home/y/ytl/k8s/claude-code/ build push
```

Convert new image to SIF via the usual workflow.

### Step 6 — Verify

```bash
# On an interactive node, after launching a session:
ps aux | grep ttyd              # must show --credential-file …/output/<uuid>/ttyd.cred, no password
cat /proc/<ttyd-pid>/cmdline | tr '\0' '\n'   # same check
ls -la ~/ondemand/data/sys/dashboard/batch_connect/sys/bc_claude_code/output/*/ttyd.cred
# must be -rw------- (600), owned by session user
```

---

## Implementation Checklist

- [x] Write `ttyd-credential-file.patch` (unified diff against ttyd `1.7.7`)
- [x] Add `ttyd-builder` stage to `Dockerfile`; pin `ARG TTYD_VERSION=1.7.7`; add `COPY ttyd-credential-file.patch`; remove curl-based ttyd install
- [x] Verify `cmake` build succeeds locally
- [x] Update `before.sh.erb` to write `$OUTPUT_DIR/ttyd.cred` with `umask 077` (no `export`)
- [x] Update `script.sh.erb`: bind-mount `$OUTPUT_DIR`, pass `--credential-file "${OUTPUT_DIR}/ttyd.cred"`, background ttyd, `sleep 2 && rm -f` the cred file, `wait`
- [x] `make build push` — new `slaclab/claude-code` image published
- [x] Convert to SIF; deploy to test session
- [x] AC-6 verified: `ps aux` shows `--credential-file …/ttyd.cred`, no password; file is mode 600 and deleted within ~2s of session start

### Problem: `failed to load evlib_uv` even after building libwebsockets from source
**Encountered:** 2026-04-15
**Root cause:** Even though libwebsockets was statically linked into the ttyd binary
(`ldd` shows no `libwebsockets.so`), libwebsockets still tries to `dlopen()` the uv
event loop as a **plugin** (`libwebsockets-evlib_uv.so`) at runtime. This plugin file
doesn't exist anywhere in the image, so context creation fails.
**Solution:** Build libwebsockets with `-DLWS_WITH_EVLIB_PLUGINS=OFF`. This compiles
the uv event loop directly into the static library rather than as a loadable plugin.
No plugin file needed at runtime.
**Lesson:** libwebsockets' plugin architecture is separate from static vs dynamic
linking. `-DLWS_WITH_EVLIB_PLUGINS=OFF` is required any time you want a self-contained
binary without external plugin files.

---

1. **Is `$OUTPUT_DIR` available inside the apptainer exec environment?** — It is
   exported by OOD's `before.sh.erb` framework and is in the environment when
   `script.sh.erb` runs. Because we explicitly bind-mount it with `-B "${OUTPUT_DIR}"`,
   it will be accessible inside the container at the same path. Recommendation: confirm
   in a test session that `echo $OUTPUT_DIR` resolves inside the container.

---

## Problems & Solutions

### Problem: Will deleting the credential file break session reconnects?
**Encountered:** 2026-04-15
**Root cause:** Concern that OOD's "Connect" button or browser reconnects would need
to re-read the credential file after it was deleted.
**Solution:** Not an issue. ttyd reads `--credential-file` **once at startup** into
`server->credential` (in-memory base64 string) and never touches the file again. The
file is dead weight the moment ttyd finishes parsing args. Additionally, `view.html.erb`
confirms the Connect button uses only `/node/<host>/<port>/` with no password in the
URL — reconnection auth is handled entirely by (a) `mod_ood_proxy` injecting
`X-Forwarded-User` server-side on every request, and (b) the browser's cached HTTP
Basic Auth credentials re-sent automatically on reconnect.
**Lesson:** Check `view.html.erb` and the ttyd credential flow before assuming the
file needs to persist. The 2-second delete window is correct and safe.

### Problem: `OUTPUT_DIR` is empty — credential file written to `/ttyd.cred`
**Encountered:** 2026-04-15
**Root cause:** `OUTPUT_DIR` is not an OOD batch connect framework variable. It was
assumed to exist but is never set, so `${OUTPUT_DIR}/ttyd.cred` expanded to
`/ttyd.cred` (root of the container filesystem), which is unwritable.
**Solution:** Use `${HOME}/ondemand/.ttyd-$$.cred` instead — `~/ondemand` is OOD's
own data directory, always exists, user-owned, and on `/sdf` which is already
bind-mounted. The `$$` PID suffix makes the filename session-unique. Export as
`TTYD_CRED_FILE` so `script.sh.erb` can reference and delete it.
**Lesson:** Never assume OOD provides `OUTPUT_DIR` — check actual framework variables.

### Problem: `libuv.so.1` and `libjson-c.so.5` missing in final image
**Encountered:** 2026-04-15
**Root cause:** The `ttyd-builder` stage compiles against `-dev` packages
(`libuv1-dev`, `libjson-c-dev`), but the final image only had the shared libraries
available via other installed packages. The patched `ttyd` binary links against both
at runtime.
**Solution:** Add `libjson-c5` and `libuv1t64` explicitly to the final image's
`apt-get install` block. (Ubuntu 24.04 renamed `libuv1` → `libuv1t64`.)

---

## Board Review

> *Security review run in lieu of full board review (P3 task, self-contained patch).*

**Verdict:** PASS WITH WARNINGS → CLEAR TO BUILD (all amendments accepted)
**Date:** 2026-04-15
**Rounds:** 1

| Reviewer | Result | Amended | Key findings |
|---|---|---|---|
| security-review | PASS WITH WARNINGS | Yes | HIGH: pin ttyd to 1.7.7 (done); MEDIUM: delete cred file after startup (done); MEDIUM: don't export CREDENTIAL_FILE (done); MEDIUM/LOW: harden C patch with ferror/null-check/explicit_bzero/long-only flag (done) |

**Accepted warnings:** none — all findings addressed by amendments
**ADRs written:** 0

---

## Relationship to Other Tasks

- **#001 (OOD App):** This task improves the security posture of #001. #001 ships
  with the `-c user:pass` accepted risk; this task eliminates it.
