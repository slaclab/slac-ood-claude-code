# 001 — Open OnDemand Interactive App for Claude Code

> **Priority:** 🟡 P2 — Medium
> **Status:** 🔍 Reviewed
> **Branch:** —
> **PR:** —
> **Created:** 2026-04-09
> **Shipped:** —

---

## Problem Statement

S3DF users who want to use Claude Code currently must SSH into a login node,
manage their own token lifecycle, and know how to configure
`~/.claude/settings.json` manually. There is no graphical or self-service
entry point, and users unfamiliar with the CLI face a steep onboarding curve.

Open OnDemand (OOD) is S3DF's standard portal for launching interactive
applications — JupyterLab, RStudio, and Desktop sessions all run as OOD
interactive apps. Adding Claude Code as an OOD app would give users a
browser-based terminal session with Claude Code pre-configured and
authenticated, accessible from the familiar OOD dashboard with zero CLI
setup.

### What fails today

| Scenario | Current behaviour | Desired behaviour |
|----------|-------------------|-------------------|
| New user wants Claude Code | Must SSH, install/configure manually, manage API key | Paste key in OOD form, click Launch, start coding |
| User unfamiliar with CLI | Stuck — no graphical entry point exists | Browser-based terminal via OOD dashboard |
| Token/key management | User must manually edit `~/.claude/settings.json` | OOD form injects key into settings on first launch |
| Session persistence | Terminal closed = session lost | Session resumable via OOD "Connect" while job is running |

---

## Goals

1. Users can launch Claude Code from the OOD dashboard with zero CLI setup
2. API key is injected via the OOD form into `~/.claude/settings.json` on first launch
3. Claude Code runs in a browser terminal (ttyd) with full TUI support (colors, cursor, ctrl-C)
4. Sessions are resumable via OOD "Connect" while the job is running
5. Everything runs inside the existing Apptainer image (`docker.io/slaclab/claude-code`)
6. Follows the established `slac-ood-jupyter` function-wrapper pattern

## Non-Goals

- **Slurm/batch mode** — Claude Code is lightweight; interactive-only via Linux Host Adapter
- **VS Code Server integration** — future P2 enhancement, not this task
- **Usage tracking / analytics** — future P2, correlate with LiteLLM spend logs later
- **MCP server pre-configuration** — future P2, ship default `.claude/settings.local.json` later
- **Custom branding / icon** — nice to have, not blocking launch

---

## Prior Art: `slac-ood-jupyter`

The existing [`slaclab/slac-ood-jupyter`](https://github.com/slaclab/slac-ood-jupyter)
app establishes the pattern we follow:

- **BatchConnect `basic` template** — OOD reverse-proxies an HTTP service
  back to the user's browser via `/node/${host}/${port}/`
- **Interactive mode** — OOD's Linux Host Adapter (SSH + tmux to an
  interactive node). We use Interactive mode only — Claude Code is
  lightweight and does not need a Slurm allocation.
- **`before.sh.erb`** — finds a free port, generates config/passwords
- **`script.sh.erb`** — runs user-selected setup commands, then launches
  the main process (Jupyter in their case, ttyd+Claude Code in ours)
- **`after.sh.erb`** — `wait_until_port_used` to signal OOD that the
  service is ready for reverse proxying

---

## Design

### Design Decision: Function-Wrapper Pattern (slac-ood-jupyter style)

Scripts (`before.sh.erb`, `script.sh.erb`, `after.sh.erb`) run inside the
**cluster-default** Singularity image (e.g. `slac-ml`), as managed by the
linux_host adapter. The claude-code SIF is invoked explicitly via shell
function wrappers in `script.sh.erb` — the same pattern `slac-ood-jupyter`
uses for its per-image `jupyter()` function:

```bash
# script.sh.erb — define wrappers then invoke
CLAUDE_SIF="${SINGULARITY_IMAGE_PATH}"
function claude() { apptainer exec -B /sdf,/fs,/lscratch "${CLAUDE_SIF}" claude "$@"; }
function ttyd()   { apptainer exec -B /sdf,/fs,/lscratch "${CLAUDE_SIF}" ttyd "$@"; }

cd "${WORKING_DIR}"
ttyd --port ${port} \
     --base-path "/node/${host}/${port}/" \
     --auth-header X-Forwarded-User \
     --writable \
     claude
```

OOD reverse-proxies ttyd via `/node/${host}/${port}/`. OOD's `mod_ood_proxy`
injects `X-Forwarded-User` on every proxied request server-side; ttyd checks
for header presence and rejects direct connections without it (407).

**No inner tmux session.** ttyd exec's `claude` directly as its subprocess
via PTY. Session reconnect works via the OOD "Connect" button while the job
is running (the outer OOD adapter tmux session keeps the job alive).

**Why this approach:**

| Benefit | Detail |
|---------|--------|
| Follows slac-ood-jupyter pattern | Same function-wrapper convention — no novel infra |
| No nesting | ttyd exec's claude directly — no tmux-inside-tmux |
| No credential file | `--auth-header X-Forwarded-User` delegates auth to OOD's proven session layer |
| No password in process list | Header-based auth has nothing to leak |
| Full TUI | ttyd's xterm.js renders ANSI colors, cursor movement, ctrl-C |
| Bindpath control | Function wrapper sets explicit `-B` flags, avoiding /usr overlay issues |

**Accepted risk:** `--auth-header` checks header *presence* only — a user on
the SLAC internal network who can reach `<node>:<port>` and forge the header
could bypass auth. Mitigated by SLAC network perimeter. Marked as known risk.
If stronger isolation is needed, add `-c user:pass` (Phase 0: verify
`hidepid=2` on S3DF nodes) as a secondary layer.

### Architecture — App Structure

```
bc_claude_code/
  ├── manifest.yml           ← app metadata, role: batch_connect
  ├── form.yml.erb           ← form fields (cluster, api_key, working_dir)
  ├── form.js                ← minimal — no cascading needed (interactive only)
  ├── submit.yml.erb         ← template: "basic"
  ├── view.html.erb          ← post-launch connect UI
  ├── icon.png               ← dashboard icon (P2)
  └── template/
      ├── before.sh.erb      ← find port, credential file, settings.json, SIF path
      ├── script.sh.erb      ← apptainer exec: tmux + claude, then ttyd
      └── after.sh.erb       ← wait_until_port_used
```

### Architecture — Session Flow

```
User → OOD Dashboard → "Claude Code" → Paste API key → Launch
  │
  ▼
OOD Linux Host Adapter: SSH + tmux to interactive node
  │
  ├─ script_wrapper.erb.sh (OOD's linux_host adapter):
  │    ├─ Validates hostname ∈ ssh_hosts
  │    ├─ Creates singularity_tmp_file + tmux_tmp_file
  │    └─ tmux new-session -d -s <uuid> "$tmux_tmp_file"
  │         └─ singularity exec --bind /sdf,/fs,... <SIF> /bin/bash $singularity_tmp_file
  │              │
  │              ├─ before.sh.erb (runs inside container):
  │              │    ├─ port=$(find_port ${host})
  │              │    ├─ password=$(create_passwd 16)
  │              │    ├─ echo "user:${password}" > ${CREDENTIAL_FILE}
  │              │    ├─ chmod 600 ${CREDENTIAL_FILE}
  │              │    └─ write ~/.claude/settings.json (if absent)
  │              │         with ANTHROPIC_AUTH_TOKEN from form
  │              │
  │              ├─ script.sh.erb (runs in cluster-default SIF):
  │              │    ├─ export CLAUDE_SIF="${SINGULARITY_IMAGE_PATH}"
  │              │    ├─ function claude() { apptainer exec -B /sdf,/fs,/lscratch ${CLAUDE_SIF} claude "$@"; }
  │              │    ├─ function ttyd()   { apptainer exec -B /sdf,/fs,/lscratch ${CLAUDE_SIF} ttyd "$@"; }
  │              │    ├─ cd ${WORKING_DIR:-$HOME}
  │              │    └─ exec ttyd \
  │              │         --port ${port} \
  │              │         --base-path /node/${host}/${port}/ \
  │              │         --auth-header X-Forwarded-User \
  │              │         --writable \
  │              │         claude
  │              │
  │              └─ after.sh.erb:
  │                   └─ wait_until_port_used ${host}:${port}
  │
  └─ OOD reverse-proxies ttyd via /node/${host}/${port}/
      │
      User's browser ↔ OOD proxy (injects X-Forwarded-User) ↔ ttyd (HTTP/WS) ↔ claude PTY
        │
        └─ LLM calls → ai-api.slac.stanford.edu (LiteLLM proxy)
```

### Architecture — How It Mirrors `slac-ood-jupyter`

| Aspect | `slac-ood-jupyter` | `bc_claude_code` |
|--------|-------------------|------------------|
| BatchConnect template | `basic` | `basic` |
| Interactive mode | SSH + tmux via Linux Host Adapter | Same |
| Batch mode | Slurm | None (interactive only) |
| Container | Singularity image per experiment | Apptainer `slaclab/claude-code` SIF |
| `before.sh.erb` | `find_port`, password gen, Jupyter config | `find_port`, credential file, settings.json |
| `script.sh.erb` | User commands → `function jupyter() { singularity exec $SIF jupyter "$@"; }` → `jupyter lab` | `function claude() { apptainer exec $SIF claude "$@"; }` + `function ttyd() { ... }` → `ttyd ... claude` |
| `after.sh.erb` | `wait_until_port_used` | Same |
| Service proxied | Jupyter (HTTP) on `${port}` | ttyd (HTTP/WS) on `${port}` |
| `base_url` / `base-path` | `c.NotebookApp.base_url = '/node/…/'` | `ttyd --base-path /node/…/` |
| Auth | Jupyter password (SHA1 hash) | ttyd `--auth-header X-Forwarded-User` (OOD injects header) |

### Architecture — Authentication Flow

```
OOD form: user pastes LiteLLM API key
  │
  ├─ before.sh.erb writes ~/.claude/settings.json (if absent)
  │   └─ ANTHROPIC_AUTH_TOKEN = <key from form>
  │   └─ ANTHROPIC_BASE_URL  = ai-api.slac.stanford.edu
  │
  ├─ Claude Code reads env vars from settings.json on startup
  │   └─ All API calls go to ai-api.slac.stanford.edu with the key
  │
  └─ No token refresh needed — LiteLLM API keys don't expire
```

### Key Decisions

- **Interactive-only (no Slurm)** — Claude Code is lightweight, no GPU needed.
  Slurm allocation is unnecessary overhead.
- **Function-wrapper pattern (not submit.yml.erb override)** — scripts run in
  the cluster-default SIF; `script.sh.erb` defines `claude()` and `ttyd()`
  shell functions wrapping `apptainer exec $SIF`. Mirrors `slac-ood-jupyter`.
  Nested apptainer risk is accepted and flagged for Phase 0 testing.
- **No inner tmux session** — ttyd exec's `claude` directly via PTY. No
  tmux-inside-tmux nesting. Session reconnect via OOD "Connect" button only
  (not SSH re-attachable). Simpler and avoids `/tmp` socket collisions entirely.
- **`--auth-header X-Forwarded-User`** — delegates auth to OOD's proven session
  layer. OOD's `mod_ood_proxy` injects this header server-side. No credential
  file, no password in process list. **Accepted risk:** header presence-only
  check; internal network users who can reach the port and forge the header
  bypass auth. Phase 0: evaluate adding `-c user:pass` secondary layer if
  `hidepid=2` is confirmed active on S3DF nodes.
- **`session.id` for uniqueness** — used to avoid any naming collisions if
  tmux is reintroduced in future. Phase 0: verify `<%= session.id %>` resolves
  in shell ERB templates; fallback to `$PWD` basename parsing.
- **Write settings.json only if absent** — respects existing user config.
  Downside: revoked keys require manual edit. Acceptable for initial launch.
- **Apptainer container** — all tools (ttyd, claude, node, ripgrep) inside
  the image. Function wrappers set explicit `-B` bindpath, avoiding /usr
  overlay issues from the cluster-default bindpath.

### ADR-001: Interactive-Only (No Slurm)

**Status:** Accepted
**Date:** 2026-04-09

#### Context
OOD supports both Interactive mode (SSH + tmux via Linux Host Adapter) and Batch
mode (Slurm job submission). `slac-ood-jupyter` supports both. Claude Code is a
CLI tool that makes API calls — no GPU, minimal CPU, modest RAM.

#### Options considered

| Option | Pros | Cons |
|---|---|---|
| Interactive only (linux_host) | Zero queue wait, instant start, simpler form (no slurm fields) | Limited to interactive node pool |
| Batch (Slurm) | Access to full cluster, resource guarantees | Queue wait, overkill for a CLI tool, more form complexity |
| Both (like Jupyter) | Maximum flexibility | Double the testing surface, confusing UX for a lightweight tool |

#### Decision
Interactive only. Claude Code's resource footprint (single-digit CPU%, <1GB RAM)
doesn't justify Slurm allocation. Users get instant session starts.

#### Consequences
- No `slurm_account`, `slurm_partition`, `num_cores`, `mem`, `num_gpus` form fields
- `submit.yml.erb` has no `script.native` block — just `template: "basic"`
- `form.js` is minimal — no cluster_group toggle needed
- If future demand requires GPU (e.g., local model inference), revisit as a new task

---

### ADR-002: Container Invocation Strategy

**Status:** Accepted
**Date:** 2026-04-14

#### Context
The linux_host adapter runs `before.sh.erb`, `script.sh.erb`, and `after.sh.erb`
inside the **cluster-default** Singularity image (e.g. `slac-ml@20211101.0.sif`),
not the claude-code SIF. `claude`, `ttyd`, and other tools are only in the
claude-code SIF. Two approaches were considered:

**Option A:** Override `singularity_container` in `submit.yml.erb` — all scripts
run directly in the claude-code SIF. Requires overriding `singularity_bindpath`
to exclude `/usr` (else ttyd/claude masked). Clean, no nesting.

**Option B (chosen):** Function-wrapper pattern — scripts run in the default SIF;
`script.sh.erb` defines shell functions that call `apptainer exec $SIF <cmd>`.
This mirrors exactly how `slac-ood-jupyter` invokes its per-experiment containers.

#### Decision
**Option B — function-wrapper pattern.** Chosen to stay consistent with
`slac-ood-jupyter` and avoid any per-app cluster config changes. Nested
`apptainer exec` (default SIF → claude-code SIF) must be validated in Phase 0.

#### Consequences
- `script.sh.erb` defines `claude()` and `ttyd()` wrapper functions
- `-B` bindpath set explicitly in each wrapper (`/sdf,/fs,/lscratch`) — avoids
  the cluster-default `/usr` overlay problem
- Nested singularity may fail if user namespaces or setuid are not configured
  on interactive nodes — **must test in Phase 0**
- `before.sh.erb` runs in the default SIF; only OOD helpers (`find_port`,
  `create_passwd`) and standard shell tools are needed there

---

### ADR-003: ttyd Authentication via OOD Proxy Header

**Status:** Accepted (replaces earlier --credential-file design)
**Date:** 2026-04-14

#### Context
The original plan used `--credential-file` which does not exist in ttyd.
Verified from ttyd source (`server.c`) and README. The actual auth options are:
- `-c user:pass` — password visible in `/proc/cmdline`
- `--auth-header <header-name>` — checks for presence of named HTTP header

OOD's `mod_ood_proxy` (Lua) injects `X-Forwarded-User` on every proxied
request server-side, set from the authenticated OOD session (`REMOTE_USER`).
This header cannot be injected by the browser client — it is overwritten by
the proxy.

#### Decision
**`ttyd --auth-header X-Forwarded-User`** — delegates authentication entirely
to OOD's existing session layer. No credential file needed. No password in
process list.

`view.html.erb` simply links to the ttyd URL — no POST form auth needed, as
authentication happens via the OOD proxy header automatically.

#### Consequences
- `before.sh.erb` no longer needs to generate passwords or credential files
- `view.html.erb` is a simple link/button to `/node/${host}/${port}/`
- **Accepted risk:** `--auth-header` checks header presence only (not value).
  A user on the SLAC internal network who can reach `<node>:<port>` directly
  and inject `X-Forwarded-User: anyone` bypasses auth. Mitigated by SLAC
  network perimeter. Phase 0: evaluate `-c user:pass` secondary layer if
  `hidepid=2` is confirmed active on S3DF interactive nodes.
- `--check-origin` (`-O`) flag should also be set to block WebSocket
  connections from unexpected origins as defence-in-depth

---

## Requirements

### Functional Requirements

```
FR-1: OOD BatchConnect app using the `basic` template and `linux_host`
      adapter (Interactive mode only — no Slurm). Standard structure:
      manifest.yml, form.yml.erb, form.js, submit.yml.erb, view.html.erb,
      template/{before,script,after}.sh.erb

FR-2: Form presents: cluster selector (interactive clusters only),
      API key (password field, masked), working directory (text, default
      $HOME), session walltime (bc_num_hours). No Slurm fields.

FR-3: before.sh.erb finds a free port, validates the working directory,
      and writes ~/.claude/settings.json (if absent) with the user's API
      key and SLAC LiteLLM proxy URL. Uses a randomized heredoc delimiter
      to prevent injection if the API key contains the delimiter string.

FR-4: script.sh.erb defines `ttyd()` and `claude()` shell function wrappers
      invoking `apptainer exec -B /sdf,/fs,/lscratch $SIF <cmd>` (the
      slac-ood-jupyter pattern). ttyd() is called directly (not via exec)
      so the wrapper is invoked. ttyd then runs claude as its subprocess
      inside the same SIF, where claude is on PATH naturally.

FR-4a: form.yml.erb includes a `sif_version` dropdown populated at render
       time by form.js via ERB glob of /sdf/sw/ai/claude-code/claude-code_*.sif,
       sorted newest-first. The selected SIF path is passed to before.sh.erb
       as context.sif_version and exported as SINGULARITY_IMAGE_PATH.

FR-5: after.sh.erb calls wait_until_port_used to signal OOD readiness.

FR-6: view.html.erb shows a simple "Connect to Claude Code" link to
      /node/${host}/${port}/. No POST form needed — OOD's mod_ood_proxy
      injects X-Forwarded-User automatically for authenticated users.

FR-7: The Apptainer SIF image (docker.io/slaclab/claude-code) provides
      all runtime dependencies: claude, node, ttyd, ripgrep, gh,
      kubectl, vault, uv. No host-side installs required.

FR-8: settings.json written by before.sh.erb includes:
      ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, model defaults for
      sonnet/opus/haiku, and CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1.
      If ~/.claude/settings.json already exists, it is NOT overwritten.

FR-9: Session is resumable while the OOD job is running — user can close
      the browser tab and click "Connect" again on the My Interactive
      Sessions page to reconnect to the same ttyd process (if still
      running). No tmux — session does not survive ttyd process death.

FR-10: NFR-3 compliance: ttyd password must not appear in /proc/cmdline.
       Met by --auth-header approach (no password at all).
```

### Non-Functional Requirements

```
NFR-1: App must work on all existing interactive clusters
       (iana, rubin, psana, suncat, supercdms, neutrino, mli) without
       per-cluster customization.

NFR-2: Container tools (ttyd, claude, tmux) must remain accessible
       despite the standard singularity_bindpath that overlays /usr
       and /etc from the host. (Critical — see ADR-002.)

NFR-3: Credential file must not leak the ttyd password into process
       arguments visible via `ps` or `/proc/*/cmdline`.

NFR-4: OOD's WebSocket reverse proxy must handle ttyd's WS upgrade
       for the full Claude Code TUI (ANSI colors, cursor movement,
       ctrl-C, interactive permission prompts).

NFR-5: Session startup (from Launch click to usable terminal) should
       complete within 30 seconds on a warm node.

NFR-6: SIF image must be accessible from all interactive nodes —
       stored on a shared filesystem (currently /sdf, needs a
       production path — see Open Questions #1).
```

### Acceptance Criteria

```
AC-1: Given a user with no ~/.claude/settings.json, when they paste
      an API key and click Launch, then Claude Code starts in a browser
      terminal and responds to prompts via ai-api.slac.stanford.edu.

AC-2: Given a user with an existing ~/.claude/settings.json, when they
      launch the app, then their existing settings are preserved and
      Claude Code uses whatever config was already present.

AC-3: Given a running session, when the user closes the browser tab
      and clicks "Connect" again, then the ttyd terminal reconnects
      and Claude Code is still running (session persists via the OOD
      adapter's outer tmux keeping the job alive).

AC-4: Given a running session, when the user clicks "Delete" in OOD,
      then the outer tmux session is killed, ttyd and Claude Code
      receive SIGTERM and terminate cleanly.

AC-5: Given any interactive cluster, when the app launches, then ttyd
      and claude are on PATH and functional despite the singularity
      bindpath overlaying /usr.

AC-6: Given a running session, when running `ps aux | grep ttyd`,
      then the ttyd password does NOT appear in the command arguments.

AC-7: Given the OOD dashboard, the app appears under "Interactive Apps"
      with title "Claude Code" and a functional launch form.
```

### Feature Tiers

**Must Have (P0):** FR-1 through FR-10, NFR-1 through NFR-6, AC-1 through AC-7

**Nice to Have (P2 — future tasks, not this PR):**
- VS Code Server integration
- Usage tracking / analytics (correlate with LiteLLM spend logs)
- Custom branding (icon.png, inline help text)
- MCP server pre-configuration (default settings.local.json)

---

## Trade-Off Analysis

### Choice: Write settings.json only if absent (vs. always overwrite)
```
+ Respects user customization — power users can tweak models, env vars, MCP
+ Idempotent — relaunching the app doesn't clobber config
- Users with revoked API keys must manually delete ~/.claude/settings.json
- No way to update model defaults without manual intervention
Decision: Write-if-absent for v1. Revisit if key rotation becomes common.
         Add clear help text in the form explaining this behavior.
```

### Choice: Single SIF image path (vs. version selector in form)
```
+ Simple — one image, one path, no form complexity
+ Admin controls the version centrally
- Users can't pin to an older Claude Code version
- Upgrades require admin to update the SIF and restart sessions
Decision: Single path for v1. Version selector is a P2 enhancement if
         users request version pinning.
```

### Choice: `--auth-header X-Forwarded-User` (vs. ttyd `-c user:pass`)
```
+ No credential in process list — `ps aux | grep ttyd` shows no password
+ No credential file management in before.sh.erb
+ Delegates auth entirely to OOD's existing session layer
+ view.html.erb is a simple link — no POST form auth complexity
- `--auth-header` checks header presence only, not value. A user on the SLAC
  internal network who can reach <node>:<port> directly and forge the header
  bypasses auth. Mitigated by SLAC network perimeter.
Decision: --auth-header X-Forwarded-User. OOD's mod_ood_proxy injects this
         server-side on all /node/<host>/<port>/ requests. Accepted risk noted.
```

### Choice: Function-wrapper pattern with SIF version dropdown (vs. hardcoded single SIF)
```
+ Users can pin to older Claude Code releases via dropdown
+ Admin adds new SIFs to /sdf/sw/ai/claude-code/ — form auto-discovers them
+ Mirrors slac-ood-jupyter pattern — familiar to OOD maintainers
+ No exec bypass issue — ttyd() wrapper called directly, not via exec
- Requires nested apptainer exec (cluster-default SIF → claude-code SIF)
  Phase 0 must verify this works on S3DF nodes
Decision: Function-wrapper + version dropdown. The slac-ood-jupyter pattern
         is proven. Version pinning is an explicit user requirement.
         Phase 0 gates on nested apptainer validation.
```

---

## Migration & Transition Path

No migration required — this is a greenfield additive change. No existing
services, schemas, or APIs are affected. The app is deployed alongside
existing OOD apps with no interaction.

---

## Implementation Plan

### Concrete File Specifications

#### `manifest.yml`
```yaml
---
name: Claude Code
category: Interactive Apps
subcategory: AI Tools
role: batch_connect
description: |
  Launch a browser-based [Claude Code] terminal session on an interactive
  node. Claude Code is an AI coding assistant that runs in your terminal.

  Paste your SLAC AI API key, click Launch, and start coding with Claude
  immediately. Sessions persist via tmux — you can close your browser and
  reconnect later.

  [Claude Code]: https://docs.anthropic.com/en/docs/claude-code
```

#### `form.yml.erb`
```yaml
---
cluster: '*'
form:
  - api_key
  - cluster
  - sif_version
  - working_dir
  - bc_num_hours
  - bc_email_on_started
attributes:
  api_key:
    widget: "text_field"
    label: "SLAC AI API Key"
    help: |
      Your LiteLLM API key for ai-api.slac.stanford.edu. Get one at the
      [AI API Portal](https://ai-api.slac.stanford.edu).

      **This key is written to `~/.claude/settings.json` on your first launch only.**
      If `~/.claude/settings.json` already exists, this field is ignored and your
      existing configuration is preserved.

      **If your key stops working:** delete `~/.claude/settings.json` on the
      interactive node, then relaunch this app with your new key.

      If Claude Code shows API errors after connecting, your key may be invalid —
      check the OOD session log or delete `~/.claude/settings.json` and relaunch.
    required: true
  sif_version:
    widget: "select"
    label: "Claude Code Version"
    help: |
      Version of Claude Code to run. "latest" is recommended for most users.
      Older versions are available if you need to pin to a specific release.
    options: []  # populated dynamically by form.js from /sdf/sw/ai/claude-code/
  working_dir:
    widget: "text_field"
    label: "Working Directory"
    value: ""
    placeholder: "$HOME (default)"
    help: |
      Directory where Claude Code will start. Leave blank to use your home
      directory. Must be an existing directory you have read/write access to.
  bc_num_hours:
    widget: "number_field"
    label: "Session Duration (hours)"
    value: 8
    help: |
      Number of hours for the Claude Code session. Maximum is limited
      by the cluster's site_timeout (typically 168 hours / 7 days).
    min: 1
    max: 168
    step: 1
```

#### `form.js`
```javascript
'use strict'

function toggle_visibility_of_form_group(form_id, show) {
  let form_element = $(form_id);
  let parent = form_element.parent();
  if (show) {
    parent.show();
  } else {
    form_element.val('');
    parent.hide();
  }
}

// Filter cluster list to interactive-only
function filter_interactive_clusters() {
  let initial = true;
  $('#batch_connect_session_context_cluster option').each(function () {
    if (this.text.includes('interactive')) {
      $(this).show();
      if (initial) { $(this).prop('selected', true); initial = false; }
    } else {
      $(this).hide();
    }
    // Clean up label: remove '_interactive' suffix
    $(this).attr('label', this.text.replace('_interactive', ''));
  });
  // Hide the cluster label header (matches slac-ood-jupyter pattern)
  $('#batch_connect_session_context_cluster').siblings().hide();
}

// Mask the API key field as password-type
function mask_api_key() {
  let input = $('#batch_connect_session_context_api_key');
  input.attr('type', 'password');
  input.attr('autocomplete', 'off');
  input.attr('data-lpignore', 'true');
  input.attr('data-1p-ignore', 'true');
}

// Populate SIF version dropdown from available SIF files.
// SIF files are named claude-code_<version>.sif under /sdf/sw/ai/claude-code/.
// The list is embedded at render time via ERB so no client-side filesystem access needed.
function populate_sif_versions() {
  let select = $('#batch_connect_session_context_sif_version');
  select.empty();
  let sifs = <%= Dir.glob("/sdf/sw/ai/claude-code/claude-code_*.sif")
                   .map { |f| File.basename(f, '.sif') }
                   .sort
                   .reverse
                   .to_json %>;
  if (sifs.length === 0) {
    // Fallback: no SIFs found at the standard path
    select.append($('<option>', { value: 'latest', text: 'latest (default)' }));
    return;
  }
  sifs.forEach(function(name, i) {
    let version = name.replace('claude-code_', '');
    let label = (i === 0) ? version + ' (latest)' : version;
    select.append($('<option>', {
      value: '/sdf/sw/ai/claude-code/' + name + '.sif',
      text: label,
      selected: i === 0
    }));
  });
}

// Main
filter_interactive_clusters();
mask_api_key();
populate_sif_versions();
```

#### `submit.yml.erb`
```yaml
---
batch_connect:
  template: "basic"
```
No `script.native` block — Interactive mode only, no Slurm args.

#### `view.html.erb`
```erb
<%# OOD injects X-Forwarded-User header automatically — no credential needed %>
<a href="/node/<%= host %>/<%= port %>/" target="_blank" class="btn btn-primary">
  <i class="fa fa-terminal"></i> Connect to Claude Code
</a>

<p class="text-muted small mt-3">
  <strong>Host:</strong> <%= host %><br>
  <strong>Port:</strong> <%= port %><br>
  <strong>Working Dir:</strong> <%= working_dir.blank? ? "~" : working_dir %>
</p>
<p class="text-muted small">
  <i class="fa fa-info-circle"></i>
  Your session continues running after you close this tab.
  Return to <strong>My Interactive Sessions</strong> and click Connect to resume.
</p>
```
**Note:** Authentication is handled by OOD's reverse proxy injecting
`X-Forwarded-User` — no POST form or credential embedding needed in view.html.erb.

#### `template/before.sh.erb`
```bash
# Export module function if available
[[ $(type -t module) == "function" ]] && export -f module

# Find available port
port=$(find_port ${host})

# Working directory (default to $HOME)
# ERB strips shell metacharacters before interpolation to prevent command substitution.
# context.working_dir is validated to contain only safe path characters.
<%
  wd = context.working_dir.to_s.strip
  wd = "" unless wd.match?(%r{\A[A-Za-z0-9_./ -]*\z})
%>
export WORKING_DIR="<%= wd %>"
if [ -z "${WORKING_DIR}" ] || [ ! -d "${WORKING_DIR}" ]; then
  export WORKING_DIR="${HOME}"
fi

# SIF image path — selected by user from version dropdown
# context.sif_version is the full path set by form.js (e.g. /sdf/sw/ai/claude-code/claude-code_2.1.104.sif)
export SINGULARITY_IMAGE_PATH="<%= context.sif_version %>"
if [ ! -f "${SINGULARITY_IMAGE_PATH}" ]; then
  echo "ERROR: SIF not found at ${SINGULARITY_IMAGE_PATH}" >&2
  clean_up 1
fi

# Write ~/.claude/settings.json if it does not exist
if [ ! -f "${HOME}/.claude/settings.json" ]; then
  mkdir -p "${HOME}/.claude"
  (
  umask 077
  # Use randomized delimiter to prevent injection if API key contains SETTINGS_EOF.
  # Unquoted << ${DELIM}: shell expands DELIM to get the terminator string, AND
  # expands variables in the body — but ERB has already substituted api_key,
  # so there are no remaining shell variables to expand in the JSON body.
  DELIM="SETTINGS_EOF_${RANDOM}"
  cat > "${HOME}/.claude/settings.json" << ${DELIM}
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://ai-api.slac.stanford.edu",
    "ANTHROPIC_AUTH_TOKEN": "<%= context.api_key %>",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "us.anthropic.claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "us.anthropic.claude-opus-4-6-v1",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
${DELIM}
  )
  echo "Wrote ~/.claude/settings.json with API key from form."
else
  echo "~/.claude/settings.json already exists — preserving existing config."
fi
```

#### `template/script.sh.erb`
```bash
#!/usr/bin/env bash

# SIF image path (set in before.sh.erb, exported into this script)
CLAUDE_SIF="${SINGULARITY_IMAGE_PATH}"

# Function wrappers — invoke claude-code SIF tools from within the
# cluster-default container (slac-ood-jupyter pattern).
# Required so that users can select different SIF versions via the form dropdown.
# Explicit -B bindpath avoids /usr overlay masking container binaries.
function ttyd()  { apptainer exec -B /sdf,/fs,/lscratch "${CLAUDE_SIF}" ttyd  "$@"; }
function claude(){ apptainer exec -B /sdf,/fs,/lscratch "${CLAUDE_SIF}" claude "$@"; }
export -f ttyd claude

# Change to working directory
cd "${WORKING_DIR}"

# Launch ttyd serving claude-code directly via PTY.
# ttyd() wrapper invokes apptainer exec $SIF ttyd — ttyd then runs claude as its
# subprocess *inside the same SIF*, so claude is on PATH naturally.
# --auth-header: OOD mod_ood_proxy injects X-Forwarded-User server-side on all
#   /node/<host>/<port>/ requests — no password needed
# --writable: enable PTY input (required for interactive claude-code)
ttyd \
  --port ${port} \
  --base-path "/node/${host}/${port}/" \
  --auth-header X-Forwarded-User \
  --writable \
  claude
```

#### `template/after.sh.erb`
```bash
# Wait for ttyd to start listening
echo "Waiting for ttyd to open port ${port}..."
if wait_until_port_used "${host}:${port}" 120; then
  echo "Discovered ttyd listening on port ${port}!"
else
  echo "Timed out waiting for ttyd to open port ${port}!"
  clean_up 1
fi
sleep 2
```

### Deployment Changes (slac-ondemand repo)

Three additions to `ondemand-patch.yaml` (same pattern as slac-ood-jupyter):

**1. Init container:**
```yaml
- name: slac-ood-claude-code
  image: slaclab/gitclone
  resources:
    limits:
      ephemeral-storage: 100Mi
    requests:
      ephemeral-storage: 100Mi
  env:
  - name: http_proxy
    value: http://sdfproxy.sdf.slac.stanford.edu:3128
  - name: https_proxy
    value: http://sdfproxy.sdf.slac.stanford.edu:3128
  - name: no_proxy
    value: .slac.stanford.edu
  - name: GIT_REPO
    value: https://github.com/slaclab/slac-ood-claude-code.git
  - name: GIT_RELEASE
    value: prod
  volumeMounts:
  - mountPath: /app
    name: slac-ood-claude-code
```

**2. Volume mount in main container:**
```yaml
- name: slac-ood-claude-code
  mountPath: /var/www/ood/apps/sys/slac-ood-claude-code/
  readOnly: true
```

**3. Volume definition:**
```yaml
- name: slac-ood-claude-code
  emptyDir: {}
```

---

## Delivery Slices

### Slice 0 — Spike: Validate Assumptions (0.5 day)

Manual testing on an interactive node. No code committed — just answers.

- [ ] SSH to an interactive node (e.g. `ssh sdfiana005`)
- [ ] Verify `find_port` and `create_passwd` are available in the cluster-default
      SIF (the adapter runs scripts there, not in the claude-code SIF)
- [ ] Test nested apptainer — from inside the default SIF, run:
      `apptainer exec -B /sdf,/fs,/lscratch <claude-code-SIF> which ttyd`
      `apptainer exec -B /sdf,/fs,/lscratch <claude-code-SIF> which claude`
      → **Record whether nested apptainer exec works**
- [ ] Test function-wrapper pattern manually:
      ```bash
      CLAUDE_SIF="/sdf/home/y/ytl/k8s/claude-code/claude-code_2.1.104.sif"
      function ttyd() { apptainer exec -B /sdf,/fs,/lscratch "${CLAUDE_SIF}" ttyd "$@"; }
      ttyd --port 8888 --base-path /node/$(hostname)/8888/ \
           --auth-header X-Forwarded-User --writable bash
      ```
- [ ] Test `--auth-header` behaviour: without OOD proxy, direct curl to ttyd
      should get 407. Through OOD `/node/` proxy, should work.
- [ ] Access `https://ondemand.slac.stanford.edu/node/<host>/8888/` in browser
      → Confirm OOD injects X-Forwarded-User and ttyd accepts the connection
- [ ] Confirm WebSocket upgrade works through OOD proxy (xterm.js renders)
- [ ] Test Claude Code TUI through ttyd: colors, cursor, ctrl-C, permission prompts
- [ ] Verify `<%= session.id %>` resolves to a per-session UUID in shell ERB
      templates; if not, test `basename $PWD` as fallback for unique naming
- [ ] Test `hidepid=2` status on interactive nodes: `cat /proc/1/cmdline` from
      another user — if masked, evaluate adding `-c user:pass` secondary auth
- [ ] **Record all findings in Problems & Solutions section**

**Gate:** If nested apptainer exec fails, escalate to Option A (submit.yml.erb
container override) before proceeding to Slice 1.

### Slice 1 — App Skeleton: All OOD Files (1 day)

Ship the complete app — every file listed in the Architecture section.

- [ ] Create app directory structure (manifest.yml, form.yml.erb, form.js,
      submit.yml.erb, view.html.erb, template/{before,script,after}.sh.erb)
- [ ] All files match the concrete specifications above
- [ ] Test locally: `form.yml.erb` renders correctly in OOD dev mode
- [ ] Commit to `main` branch, push to GitHub

### Slice 2 — Integration Test: End-to-End (1 day)

Deploy to OOD and validate all acceptance criteria.

- [ ] AC-1: New user (no settings.json) → Launch → Claude responds
- [ ] AC-2: Existing user (has settings.json) → Launch → settings preserved
- [ ] AC-3: Close browser tab → re-Connect → ttyd still running, Claude still active
- [ ] AC-4: OOD "Delete" → outer tmux killed, ttyd+Claude receive SIGTERM
- [ ] AC-5: Tools accessible on all tested clusters despite bindpath
- [ ] AC-6: `ps aux | grep ttyd` → no password in args
- [ ] AC-7: App appears in OOD dashboard under "Interactive Apps"
- [ ] Test invalid API key → clear error in OOD session logs

### Slice 3 — Deploy to Production (0.5 day)

- [ ] Add gitclone init container + volume + volumeMount to
      `slac-ondemand` `ondemand-patch.yaml`
- [ ] Create `prod` branch/tag on this repo
- [ ] Confirm SIF accessible from all interactive nodes
- [ ] Deploy updated OOD pod
- [ ] Smoke test: launch from OOD dashboard, verify Claude responds
- [ ] Write user-facing docs

---

## Implementation Checklist

- [ ] **Slice 0:** Spike — /usr overlay tested, findings recorded
- [ ] **Slice 0:** ADR-002 resolved (if tools were masked)
- [ ] **Slice 1:** manifest.yml written
- [ ] **Slice 1:** form.yml.erb written
- [ ] **Slice 1:** form.js written
- [ ] **Slice 1:** submit.yml.erb written
- [ ] **Slice 1:** view.html.erb written
- [ ] **Slice 1:** template/before.sh.erb written
- [ ] **Slice 1:** template/script.sh.erb written
- [ ] **Slice 1:** template/after.sh.erb written
- [ ] **Slice 2:** AC-1 through AC-7 all pass
- [ ] **Slice 2:** Session reconnect (close tab → re-Connect) works
- [ ] **Slice 3:** ondemand-patch.yaml updated in slac-ondemand repo
- [ ] **Slice 3:** Deployed to production OOD
- [ ] **Slice 3:** User-facing docs written

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Nested apptainer exec fails (default SIF → claude-code SIF) | Medium | High | Test in Slice 0; fallback is submit.yml.erb container override (Option A) |
| ttyd --auth-header bypass (SLAC internal network + forged header) | Low | Medium | **Accepted risk** — SLAC network perimeter mitigates; evaluate `-c user:pass` + `hidepid=2` as secondary layer in Phase 0 |
| OOD WebSocket upgrade fails through proxy for ttyd | Low | High | Jupyter already uses WebSockets through same proxy; test in Slice 0 |
| Claude Code TUI garbled through ttyd | Low | Medium | ttyd's xterm.js is mature; test rendering in Slice 0 |
| SIF not accessible from all interactive nodes | Low | High | SIF on /sdf shared filesystem; verify reachability in Slice 0 |
| API key injected via ERB heredoc — delimiter collision | Low | High | Fixed: randomized delimiter `SETTINGS_EOF_${RANDOM}` |
| Shell injection via context.working_dir | Medium | High | Validate directory exists (`[ -d "${WORKING_DIR}" ]`); strip dangerous chars |
| Users can't update revoked API key | Medium | Low | Help text explains manual delete; acceptable for v1 |
| Hardcoded model names become stale | Medium | Low | Admin periodic update; future P2 to make form-selectable |

---

## Definition of Done

- [ ] All 7 acceptance criteria (AC-1 through AC-7) pass on at least 2 clusters
- [ ] App appears in OOD dashboard and launches successfully
- [ ] Claude Code responds to prompts through the browser terminal
- [ ] Session reconnect (close tab → re-Connect) works
- [ ] OOD "Delete" cleanly terminates the session
- [ ] No credentials leaked in process list or logs
- [ ] Deployment changes (ondemand-patch.yaml) applied to production
- [ ] SIF image accessible from all interactive nodes
- [ ] User-facing documentation written and linked
- [ ] All open questions resolved or deferred with rationale

---

## Problems & Solutions

<!-- Add entries as you hit walls during implementation. -->

---

## Open Questions

1. **SIF image location:** Where should the production SIF live? Currently
   at `/sdf/home/y/ytl/k8s/claude-code/claude-code_*.sif`. Needs a
   shared path like `/sdf/sw/ai/claude-code/` or
   `/fs/ddn/sdf/group/.../claude-code.sif` so all interactive nodes can
   reach it.

2. ~~**Nested tmux sessions:**~~ **Resolved.** No inner tmux session — ttyd
   exec's `claude` directly via PTY. The OOD adapter's outer tmux keeps the
   job alive. No nesting, no prefix key conflict, no /tmp socket collision.

3. **OOD WebSocket proxying:** Does OOD's `/node/` reverse proxy handle
   WebSocket upgrade for ttyd? Jupyter already uses WebSockets, so this
   likely works, but must confirm.
   → **Test in Phase 0.**

4. **Claude Code TUI under ttyd:** Does the full TUI render correctly?
   Terminal capabilities, ANSI colors, cursor movement, ctrl-C,
   interactive permission prompts.
   → **Test in Phase 0.**

5. **Singularity bindpath:** The existing cluster configs bind
   `/etc,/media,/mnt,/opt,/run,/srv,/usr,/var,/sdf,/fs,/lscratch`.
   The container's `/usr` and `/etc` will be overlaid by the host's.
   Does this break any container-installed tools (ttyd at `/usr/local/bin`,
   claude at `/home/claudeuser/.local/bin`)? May need to adjust bindpath
   or install tools outside `/usr`.
   → **Critical — test in Phase 0.**

6. **API key persistence:** The API key is written to `~/.claude/settings.json`
   on first launch and never overwritten. If a user's key is revoked, they
   must manually edit the file or delete it before re-launching. Is this
   acceptable, or should we always overwrite?

---

## Board Review

**Verdict:** CLEAR WITH WARNINGS
**Date:** 2026-04-14
**Rounds:** 2

| Reviewer | R1 | R2 | Amended | Key findings |
|---|---|---|---|---|
| research-handbook | FAIL | PASS WITH WARNINGS | Yes | `--credential-file` doesn't exist in ttyd; `context.token` not session-unique; nested apptainer risk flagged for Phase 0 |
| codebase-arch-review | FAIL | PASS WITH WARNINGS | Yes | Container execution model wrong (scripts run in cluster-default SIF); ttyd auth redesigned to `--auth-header`; session ID changed to `session.id` |
| codebase-eng-review | FAIL | PASS WITH WARNINGS | Yes | `exec ttyd` bypasses shell function wrappers (fixed to `exec apptainer exec ... ttyd`); heredoc delimiter issue; view.html.erb POST auth wrong |
| codebase-doc-review | PASS WITH WARNINGS | — (skipped R2) | Yes | AMD-UX-1..5 applied: form field reorder, stronger help text, working_dir placeholder, reconnect info in view.html.erb, manifest description |
| security-review | FAIL | PASS WITH WARNINGS | Yes | API key heredoc injection (fixed with randomized delimiter + unquoted `<< ${DELIM}`); working_dir command substitution (fixed with ERB metachar validation); `--auth-header` forgery accepted risk documented |
| codebase-ux-review | PASS WITH WARNINGS | — (skipped R2) | Yes | Form field order, settings.json warning text, working_dir placeholder, session reconnect discoverability, manifest description |

**Accepted warnings:**
- `--auth-header X-Forwarded-User` checks header presence only (not value) — forgery possible by users on SLAC internal network who can reach node:port directly. Mitigated by SLAC network perimeter; `-c user:pass` secondary layer deferred to Phase 0 evaluation.
- SIF fallback path points to user home directory — remove or guard before production deployment.
- Nested apptainer exec (cluster-default SIF → claude-code SIF) needs Phase 0 validation; if it fails, escalate to submit.yml.erb `script.native.singularity_container` override.
- `session.id` availability in shell ERB templates needs Phase 0 verification; fallback to `basename $PWD`.

**ADRs written:** ADR-001 (function-wrapper pattern), ADR-002 (singularity bindpath), ADR-003 (ttyd auth — `--auth-header`)

---

## References

- [`slaclab/slac-ood-jupyter`](https://github.com/slaclab/slac-ood-jupyter) — reference OOD app
- [Open OnDemand Documentation](https://osc.github.io/ood-documentation/)
- [OOD Interactive Apps — BatchConnect](https://osc.github.io/ood-documentation/latest/app-development/interactive/setup.html)
- [OOD Linux Host Adapter](https://osc.github.io/ood-documentation/latest/installation/resource-manager/linuxhost.html)
- [ttyd — Share your terminal over the web](https://tsl0922.github.io/ttyd/)
- Container source: `/sdf/home/y/ytl/k8s/claude-code/` (Dockerfile + Makefile)
- Container image: `docker.io/slaclab/claude-code`
- OOD deployment: `/sdf/home/y/ytl/k8s/ondemand/slac-ondemand/`

## Relationship to Other Tasks

- This is the foundational task — no dependencies on other items in this repo.
- Future VS Code integration (#P2), usage tracking (#P2), and MCP pre-config (#P2) depend on this shipping first.
