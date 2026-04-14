# 001 — Open OnDemand Interactive App for Claude Code

> **Priority:** 🟡 P2 — Medium
> **Status:** ⬜ Open
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
| Session persistence | Terminal closed = session lost | tmux session survives browser disconnects |

---

## Goals

1. Users can launch Claude Code from the OOD dashboard with zero CLI setup
2. API key is injected via the OOD form into `~/.claude/settings.json` on first launch
3. Claude Code runs in a browser terminal (ttyd) with full TUI support (colors, cursor, ctrl-C)
4. Sessions persist via tmux — survive browser disconnects, re-connectable via OOD or SSH
5. Everything runs inside the existing Apptainer image (`docker.io/slaclab/claude-code`)
6. Follows the established `slac-ood-jupyter` pattern — no novel infrastructure

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

### Design Decision: ttyd → tmux (Hybrid Approach)

The Apptainer container (`docker.io/slaclab/claude-code`) includes both
`ttyd` and `tmux`. Claude Code runs in a **named tmux session**; `ttyd`
serves as the browser bridge via OOD's `basic` BatchConnect template.

```
script.sh.erb:
  1. tmux new-session -d -s claude-code-${SESSION_ID} "claude"
  2. ttyd --port ${port} \
         --base-path /node/${host}/${port}/ \
         --credential-file ${CREDENTIAL_FILE} \
         tmux attach-session -t claude-code-${SESSION_ID}
```

**Note:** The tmux session name includes the OOD session UUID to avoid
collisions when the same user runs multiple concurrent sessions on one
node. Apptainer shares `/tmp` (and thus the default tmux socket) with
the host, so a hardcoded name would conflict.

OOD reverse-proxies ttyd via `/node/${host}/${port}/`. The user clicks
"Connect" and gets a browser terminal attached to the Claude Code tmux
session.

**Why this approach:**

| Benefit | Detail |
|---------|--------|
| Resilient sessions | Claude Code survives ttyd restarts — tmux session persists |
| SSH attachable | Users can also `ssh <node>` + `tmux attach -t claude-code` |
| Full TUI | ttyd's xterm.js renders ANSI colors, cursor movement, ctrl-C |
| Standard OOD pattern | Same `basic` template as `slac-ood-jupyter` |
| Secure credentials | `--credential-file` avoids password in `/proc/cmdline` |
| No host dependencies | ttyd + tmux + claude all live inside the Apptainer image |

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
  │              ├─ script.sh.erb (runs inside container):
  │              │    ├─ cd ${WORKING_DIR:-$HOME}
  │              │    ├─ tmux new-session -d -s claude-code-${SESSION_ID} claude
  │              │    └─ exec ttyd \
  │              │         --port ${port} \
  │              │         --base-path /node/${host}/${port}/ \
  │              │         --credential-file ${CREDENTIAL_FILE} \
  │              │         tmux attach-session -t claude-code-${SESSION_ID}
  │              │
  │              └─ after.sh.erb:
  │                   └─ wait_until_port_used ${host}:${port}
  │
  └─ OOD reverse-proxies ttyd via /node/${host}/${port}/
      │
      User's browser ↔ OOD proxy ↔ ttyd (HTTP/WS) ↔ tmux ↔ Claude Code TUI
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
| `script.sh.erb` | User commands → `jupyter lab --config=...` | `tmux new-session` → `claude` (Claude Code CLI), then `ttyd` → `tmux attach` |
| `after.sh.erb` | `wait_until_port_used` | Same |
| Service proxied | Jupyter (HTTP) on `${port}` | ttyd (HTTP/WS) on `${port}` |
| `base_url` / `base-path` | `c.NotebookApp.base_url = '/node/…/'` | `ttyd --base-path /node/…/` |
| Auth | Jupyter password (SHA1 hash) | ttyd `--credential-file` (plaintext user:pass, file mode 600) |

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
- **ttyd + tmux hybrid** — ttyd alone loses sessions on browser close. tmux alone
  has no browser bridge. Combined: resilient sessions with browser access.
- **Credential file over CLI password** — `--credential-file` keeps the password
  out of `/proc/cmdline`.
- **Write settings.json only if absent** — respects existing user config. Downside:
  revoked keys require manual edit. Acceptable for initial launch.
- **Apptainer container** — all tools (ttyd, tmux, claude, node, ripgrep) inside
  the image. No host dependencies beyond Singularity/Apptainer runtime.
- **Session-unique tmux name** (`claude-code-${SESSION_ID}`) — Apptainer
  shares `/tmp` with the host, so tmux sockets are visible across sessions.
  A hardcoded session name would collide if the same user launches multiple
  concurrent sessions on one node.

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

### ADR-002: Singularity Bindpath and /usr Overlay

**Status:** Proposed — requires Phase 0 spike validation
**Date:** 2026-04-14

#### Context
All interactive cluster configs use:
```
singularity_bindpath: /etc,/media,/mnt,/opt,/run,/srv,/usr,/var,/sdf,/fs,/lscratch
```
This overlays the container's `/usr` and `/etc` with the host's versions. The
claude-code container installs tools at:
- `/usr/local/bin/ttyd` — **will be masked** by host `/usr`
- `/usr/bin/rg`, `/usr/bin/gh`, `/usr/bin/kubectl`, `/usr/bin/vault` — **will be masked**
- `/home/claudeuser/.local/bin/claude` — safe (not under /usr)
- `/home/claudeuser/.local/bin/uv` — safe

#### Options considered

| Option | Pros | Cons |
|---|---|---|
| A: Custom bindpath excluding /usr | Tools survive | Breaks host /usr libs that container processes may need; diverges from cluster standard |
| B: Move tools to /opt/claude-code/ in Dockerfile | Clean separation, survives /usr overlay | Requires container rebuild; /opt may also be overlaid |
| C: Copy tools to user-writable path at runtime | No container changes needed | Slow startup, fragile, wastes disk per session |
| D: Use `--no-mount` or selective bind | Precise control | Requires OOD cluster config changes per-cluster |
| E: Override bindpath in submit.yml.erb | App controls its own bindpath, no cluster config changes | Need to confirm OOD respects per-app singularity_bindpath |

#### Decision
**Test in Phase 0.** First verify what actually breaks. The container's
`/home/claudeuser/.local/bin/` is safe. If ttyd at `/usr/local/bin/` is
masked, the preferred fix is **Option B** — rebuild the container to install
ttyd (and other /usr tools) under `/opt/claude-code/bin/` and add that to PATH.
This is a one-time container change and the cleanest long-term solution.

If Option B is impractical short-term, **Option E** (per-app bindpath in
`submit.yml.erb` or `before.sh.erb`) is the fallback.

#### Consequences
- Phase 0 spike must explicitly test: `which ttyd`, `which rg`, `which claude`
  inside the container with full bindpath active
- Container Dockerfile may need a rebuild to relocate tools out of /usr
- Document the bindpath constraint in the task file's Problems & Solutions

---

### ADR-003: ttyd Authentication via Credential File

**Status:** Accepted
**Date:** 2026-04-14

#### Context
ttyd supports several authentication methods. The OOD reverse proxy provides
session-level auth (user must be logged into OOD), but ttyd itself needs auth
to prevent other users on the same node from connecting directly.

#### Options considered

| Option | Pros | Cons |
|---|---|---|
| `--credential user:pass` CLI arg | Simple | Password visible in `ps aux`, `/proc/cmdline` — security risk |
| `--credential-file /path` | Password not in process list, file is mode 600 | Slightly more setup in before.sh.erb |
| No ttyd auth (rely on OOD proxy) | Simplest | Any user on the node can connect to the ttyd port directly |

#### Decision
Credential file. Same security posture as Jupyter's SHA1 password in a config file.
`before.sh.erb` generates a random password, writes `user:<password>` to a file
with `umask 077`, and passes `--credential-file` to ttyd.

#### Consequences
- `view.html.erb` must POST the credential (username + password) to ttyd's
  `/node/${host}/${port}/` endpoint
- ttyd uses HTTP Basic Auth — the POST form approach from slac-ood-jupyter
  won't work directly. Need to confirm ttyd's auth flow:
  - ttyd with `--credential-file` expects HTTP Basic Auth headers
  - OOD's `view.html.erb` may need to construct the URL with embedded
    credentials or use JavaScript to set the Authorization header
  - **Test in Phase 0**

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

FR-3: before.sh.erb finds a free port, generates a random credential,
      writes a ttyd credential file (mode 600), and writes
      ~/.claude/settings.json (if absent) with the user's API key and
      SLAC LiteLLM proxy URL.

FR-4: script.sh.erb launches Claude Code in a named tmux session inside
      the Apptainer container, then execs ttyd to serve that session via
      OOD's /node/${host}/${port}/ reverse proxy.

FR-5: after.sh.erb calls wait_until_port_used to signal OOD readiness.

FR-6: view.html.erb shows a "Connect to Claude Code" button that opens
      the ttyd session (POST with hidden credential, same pattern as
      slac-ood-jupyter's view.html.erb).

FR-7: The Apptainer SIF image (docker.io/slaclab/claude-code) provides
      all runtime dependencies: claude, node, ttyd, tmux, ripgrep, gh,
      kubectl, vault, uv. No host-side installs required.

FR-8: settings.json written by before.sh.erb includes:
      ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, model defaults for
      sonnet/opus/haiku, and CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1.
      If ~/.claude/settings.json already exists, it is NOT overwritten.

FR-9: Session survives browser disconnect — user can close the tab
      and click "Connect" again to re-attach the same tmux session.
      tmux session is named claude-code-${SESSION_ID} (using OOD's
      session token) to avoid collisions when the same user runs
      multiple concurrent sessions on one node.

FR-10: Users can also SSH to the compute node and run
       `tmux attach -t claude-code-<session_id>` to access the same
       session. (Session ID is visible in the OOD session details.)
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
      and clicks "Connect" again, then they re-attach to the same
      Claude Code tmux session with context preserved.

AC-4: Given a running session, when the user clicks "Delete" in OOD,
      then the tmux session is killed and Claude Code receives SIGTERM.

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

### Choice: ttyd Basic Auth (vs. token-based or no auth)
```
+ Proven pattern — HTTP Basic Auth is well-understood
+ Credential file keeps password out of process list
- Basic Auth over HTTP is cleartext (but OOD proxy uses HTTPS end-to-end)
- ttyd's auth flow differs from Jupyter's — need to verify view.html.erb approach
Decision: Credential file with Basic Auth. OOD's HTTPS proxy encrypts the
         transport. Test the view.html.erb auth flow in Phase 0.
```

### Choice: Named inner tmux session (vs. direct ttyd → claude)
```
+ Session survives ttyd restarts and browser disconnects
+ SSH-attachable from outside OOD
+ Clean separation: ttyd is the transport, tmux is the session
- Nested tmux (OOD outer + our inner) adds complexity
- Must test that tmux prefix keys don't conflict
Decision: Named tmux session. The resilience benefits are critical for
         long-running Claude Code sessions. Nested tmux is low-risk
         since outer is on host, inner is in container.
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
  - cluster
  - api_key
  - working_dir
  - bc_num_hours
  - bc_email_on_started
attributes:
  api_key:
    widget: "text_field"
    label: "SLAC AI API Key"
    help: |
      Your LiteLLM API key for ai-api.slac.stanford.edu.

      This key is written to ~/.claude/settings.json on first launch only.
      If you already have a settings.json, this field is ignored and your
      existing configuration is preserved.

      To get an API key, visit [AI API Portal](https://ai-api.slac.stanford.edu).
    required: true
  working_dir:
    widget: "text_field"
    label: "Working Directory"
    value: ""
    help: |
      Directory where Claude Code will start. Leave blank for your home
      directory ($HOME).
  bc_num_hours:
    widget: "number_field"
    label: "Session Duration (hours)"
    value: 4
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
}

// Main
filter_interactive_clusters();
mask_api_key();
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
<form action="/node/<%= host %>/<%= port %>/" method="post" target="_blank">
  <input type="hidden" name="username" value="<%= username %>">
  <input type="hidden" name="password" value="<%= password %>">
  <button class="btn btn-primary" type="submit">
    <i class="fa fa-terminal"></i> Connect to Claude Code
  </button>
</form>
<small>
  <strong>Host:</strong> <%= host %><br>
  <strong>Port:</strong> <%= port %><br>
  <strong>Working Dir:</strong> <%= working_dir.blank? ? "~" : working_dir %>
</small>
```
**Note:** ttyd's auth flow may differ from Jupyter's POST-to-/login pattern.
ttyd uses HTTP Basic Auth — the view.html.erb approach needs Phase 0 testing.
May need to embed credentials in the URL (`https://user:pass@host:port/`)
or use JavaScript to set `Authorization: Basic <base64>` header.

#### `template/before.sh.erb`
```bash
# Export module function if available
[[ $(type -t module) == "function" ]] && export -f module

# Find available port
port=$(find_port ${host})

# Generate credentials for ttyd
password="$(create_passwd 16)"
username="user"

# Write ttyd credential file (mode 600)
export CREDENTIAL_FILE="${PWD}/credential"
(
umask 077
echo "${username}:${password}" > "${CREDENTIAL_FILE}"
)

# Working directory (default to $HOME)
export WORKING_DIR="<%= context.working_dir.blank? ? "" : context.working_dir %>"
if [ -z "${WORKING_DIR}" ]; then
  export WORKING_DIR="${HOME}"
fi

# SIF image path
export SINGULARITY_IMAGE_PATH="/sdf/sw/ai/claude-code/claude-code.sif"
# Fallback for development/testing
if [ ! -f "${SINGULARITY_IMAGE_PATH}" ]; then
  export SINGULARITY_IMAGE_PATH="/sdf/home/y/ytl/k8s/claude-code/claude-code_2.1.104.sif"
fi

# Write ~/.claude/settings.json if it does not exist
if [ ! -f "${HOME}/.claude/settings.json" ]; then
  mkdir -p "${HOME}/.claude"
  (
  umask 077
  cat > "${HOME}/.claude/settings.json" << 'SETTINGS_EOF'
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
SETTINGS_EOF
  )
  echo "Wrote ~/.claude/settings.json with API key from form."
else
  echo "~/.claude/settings.json already exists — preserving existing config."
fi
```

#### `template/script.sh.erb`
```bash
#!/usr/bin/env bash

# Change to working directory
cd "${WORKING_DIR}"

# OOD session ID for unique tmux session name
# Avoids collisions when same user runs multiple sessions on one node
# (Apptainer shares /tmp with host, so tmux sockets are shared)
export SESSION_ID="<%= context.token %>"

# Start Claude Code in a named tmux session
# The CLI binary is `claude`; session name uses `claude-code-` prefix for clarity
tmux new-session -d -s "claude-code-${SESSION_ID}" "claude"

# Launch ttyd to serve the tmux session via OOD reverse proxy
# ttyd bridges the browser to the tmux session
exec ttyd \
  --port ${port} \
  --base-path "/node/${host}/${port}/" \
  --credential-file "${CREDENTIAL_FILE}" \
  --writable \
  tmux attach-session -t "claude-code-${SESSION_ID}"
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
- [ ] Run the SIF with full bindpath:
      `singularity exec -B /etc,/media,/mnt,/opt,/run,/srv,/usr,/var,/sdf,/fs,/lscratch <SIF> bash`
- [ ] Inside container: `which ttyd`, `which claude`, `which tmux`, `which rg`
      → **Record which tools survive the /usr overlay and which are masked**
- [ ] Test ttyd → tmux manually:
      ```
      echo "user:testpass" > /tmp/cred && chmod 600 /tmp/cred
      tmux new-session -d -s test-session bash
      ttyd --port 8888 --base-path /test/ --credential-file /tmp/cred tmux attach -t test-session
      ```
- [ ] From another terminal: `curl -u user:testpass http://<host>:8888/test/`
      → Confirm ttyd responds
- [ ] Test OOD reverse proxy: access `https://ondemand.slac.stanford.edu/node/<host>/8888/`
      → Confirm WebSocket upgrade works
- [ ] Test Claude Code TUI through ttyd: colors, cursor, ctrl-C, permission prompts
- [ ] Test nested tmux: outer tmux (simulating OOD adapter) + inner tmux session
- [ ] Verify /tmp sharing: confirm Apptainer shares /tmp with host, so
      tmux sessions created inside the container are visible from outside
      (this is expected — validates the SESSION_ID naming is necessary)
- [ ] Test concurrent sessions: two tmux sessions with different names
      on the same node via the same user — confirm no collision
- [ ] **Record findings in Problems & Solutions section**

**Gate:** If ttyd or claude are masked by /usr overlay, implement ADR-002
fix before proceeding to Slice 1.

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
- [ ] AC-3: Close browser tab → re-Connect → same tmux session
- [ ] AC-4: OOD "Delete" → tmux killed, Claude gets SIGTERM
- [ ] AC-5: Tools accessible on all tested clusters despite bindpath
- [ ] AC-6: `ps aux | grep ttyd` → no password in args
- [ ] AC-7: App appears in OOD dashboard under "Interactive Apps"
- [ ] Test invalid API key → clear error in OOD session logs
- [ ] Test SSH attach → `ssh <node>` + `tmux attach -t claude-code`

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
- [ ] **Slice 2:** Session reconnect works
- [ ] **Slice 2:** SSH attach works
- [ ] **Slice 3:** ondemand-patch.yaml updated in slac-ondemand repo
- [ ] **Slice 3:** Deployed to production OOD
- [ ] **Slice 3:** User-facing docs written

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| /usr overlay masks ttyd, rg, other container tools | **High** | **High** | ADR-002: Test in Slice 0; rebuild container to install under /opt if needed |
| ttyd WebSocket upgrade fails through OOD proxy | Low | High | Jupyter already uses WebSockets through same proxy; test in Slice 0 |
| tmux session name collision (/tmp shared) | High (if hardcoded) | High | Fixed: session name includes OOD session token (`claude-code-${SESSION_ID}`) |
| Nested tmux conflicts (OOD outer + our inner) | Low | Medium | Different tmux socket paths (host vs container); test in Slice 0 |
| Claude Code TUI garbled through ttyd | Low | Medium | ttyd's xterm.js is mature; test rendering in Slice 0 |
| ttyd auth flow incompatible with OOD view.html.erb | Medium | Medium | ttyd uses HTTP Basic Auth, not Jupyter's POST-to-/login; test in Slice 0, may need JS workaround |
| SIF not accessible from all interactive nodes | Low | High | SIF on /sdf shared filesystem; verify reachability in Slice 0 |
| API key leaked in logs or process list | Low | High | Credential file (mode 600) for ttyd; settings.json (mode 600) for API key; never pass as CLI arg |
| Users can't update revoked API key | Medium | Low | Help text explains manual edit; future enhancement to support overwrite |

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

2. **Nested tmux sessions:** The Linux Host Adapter wraps `script.sh.erb`
   in a tmux session. Our script creates a *second* named tmux session
   inside the container. Does nesting cause issues? The outer tmux is on
   the host; the inner one is inside the container — they should be
   separate session servers.
   → **Test in Phase 0.**

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

> *Populated by `/codebase-board-review` after the board completes. Do not fill manually.*

**Verdict:** —
**Date:** —
**Rounds:** —

| Reviewer | Result | Amended | Key findings |
|---|---|---|---|
| research-handbook | — | — | — |
| codebase-arch-review | — | — | — |
| codebase-eng-review | — | — | — |
| codebase-doc-review | — | — | — |
| security-review | — | — | — |

**Accepted warnings:** none
**ADRs written:** 0

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
