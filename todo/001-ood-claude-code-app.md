# 001 — Open OnDemand Interactive App for Claude Code

> **Priority:** 🟡 P2 — Medium
> **Status:** 📋 Preparing
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
  1. tmux new-session -d -s claude-code "claude --model ${MODEL}"
  2. ttyd --port ${port} \
         --base-path /node/${host}/${port}/ \
         --credential-file ${CREDENTIAL_FILE} \
         tmux attach-session -t claude-code
```

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
  │              │    ├─ tmux new-session -d -s claude-code claude
  │              │    └─ exec ttyd \
  │              │         --port ${port} \
  │              │         --base-path /node/${host}/${port}/ \
  │              │         --credential-file ${CREDENTIAL_FILE} \
  │              │         tmux attach-session -t claude-code
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
| `script.sh.erb` | User commands → `jupyter lab --config=...` | `tmux new-session` → `claude`, then `ttyd` → `tmux attach` |
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

---

## Requirements

### Must Have (P0)

1. **OOD BatchConnect app (Interactive mode only)**
   - Standard BatchConnect structure: `manifest.yml`, `form.yml.erb`,
     `form.js`, `submit.yml.erb`, `view.html.erb`, `template/`
   - `role: batch_connect`, `template: "basic"` — same as `slac-ood-jupyter`
   - **Interactive only** — SSH + tmux to an interactive node via Linux
     Host Adapter. No Batch/Slurm mode.

2. **Browser-to-terminal connection (ttyd → tmux)**
   - `ttyd` serves `tmux attach -t claude-code` via OOD's `basic` reverse
     proxy at `/node/${host}/${port}/`
   - `--credential-file` for authentication
   - Must support Claude Code's full TUI: ANSI colors, cursor movement,
     interactive prompts, ctrl-C

3. **Apptainer container (`docker.io/slaclab/claude-code`)**
   - Run inside existing Apptainer image which already includes: Claude
     Code, Node.js LTS, ttyd, tmux, ripgrep, gh, kubectl, vault, uv
   - SIF files versioned by Claude Code release (e.g.
     `claude-code_2.1.104.sif`)
   - Singularity bindpath for S3DF filesystems:
     `/etc,/media,/mnt,/opt,/run,/srv,/usr,/var,/sdf,/fs,/lscratch`

4. **Pre-configured `settings.json`**
   - `before.sh.erb` writes `~/.claude/settings.json` with the user's
     API key from the form:
     ```json
     {
       "env": {
         "ANTHROPIC_BASE_URL": "https://ai-api.slac.stanford.edu",
         "ANTHROPIC_AUTH_TOKEN": "<user's API key from form>",
         "ANTHROPIC_DEFAULT_SONNET_MODEL": "us.anthropic.claude-sonnet-4-6",
         "ANTHROPIC_DEFAULT_OPUS_MODEL": "us.anthropic.claude-opus-4-6-v1",
         "ANTHROPIC_DEFAULT_HAIKU_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
         "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
       }
     }
     ```
   - If the file already exists, leave it untouched

5. **API key authentication**
   - Form field: `api_key` — password-type input (masked), required
   - Injected into `settings.json` as `ANTHROPIC_AUTH_TOKEN`
   - Base URL (`ai-api.slac.stanford.edu`) is a hidden form default

### Should Have (P1)

6. **Form parameters (`form.yml.erb` + `form.js`)**
   - **`cluster`** — interactive cluster selector (e.g. `iana_interactive`,
     `rubin_interactive`)
   - **`api_key`** — password field (masked), required
   - **`working_dir`** — text field, defaults to `$HOME`
   - **`bc_num_hours`** — session walltime (hours)
   - No Slurm fields — Interactive mode only

7. **Session lifecycle**
   - Clean shutdown on OOD "Delete" — tmux session killed, Claude Code
     gets SIGTERM
   - `view.html.erb` shows session info: host, connect button

### Nice to Have (P2)

8. **VS Code Server integration**
    - Alternative form option that launches VS Code Server (code-server)
      with Claude Code available in the integrated terminal

9. **Usage tracking**
    - Log OOD session launches (user, duration, model) for analytics
    - Correlate with LiteLLM spend logs

10. **Custom branding**
    - App icon (`icon.png`) on the OOD dashboard
    - Brief inline help text in `form.yml.erb`

11. **MCP server access**
    - Pre-configure MCP server connections so Claude Code can use SLAC MCP
      tools (Grafana, Loki, Prometheus, etc.) via AgentGateway
    - Ship a default `.claude/settings.local.json` with MCP endpoints

---

## Implementation Plan

### Phase 0: Spike — Apptainer + ttyd + tmux through OOD (1 day)

- [ ] Test the Apptainer SIF on an interactive node manually:
      `singularity exec --bind /sdf,/fs claude-code_2.1.104.sif bash`
- [ ] Inside the container: verify `ttyd`, `tmux`, and `claude` are on PATH
- [ ] Test the ttyd → tmux flow manually:
      ```
      tmux new-session -d -s claude-test bash
      ttyd --port 8888 --base-path /node/$(hostname)/8888/ \
           --credential-file /tmp/cred tmux attach -t claude-test
      ```
- [ ] Verify OOD's `/node/${host}/${port}/` reverse proxy handles ttyd's
      WebSocket upgrade
- [ ] Test Claude Code TUI rendering through ttyd (colors, cursor, ctrl-C,
      interactive permission prompts)
- [ ] Confirm `--credential-file` works (no password in `ps` output)
- [ ] Test nested tmux: OOD adapter creates outer tmux; `script.sh.erb`
      creates inner named session — verify both coexist

### Phase 1: App Skeleton (1 day)

- [ ] Create `bc_claude_code/` directory
- [ ] `manifest.yml` — title: "Claude Code", category: "Interactive Apps"
- [ ] `form.yml.erb`:
      - `cluster` — interactive clusters only
      - `api_key` — password field (masked), required
      - `working_dir` — text field, default `$HOME`
      - `bc_num_hours` — session walltime
      - `base_url` — hidden, default `https://ai-api.slac.stanford.edu`
- [ ] `form.js` — minimal (hide cluster header, basic validation)
- [ ] `submit.yml.erb` — `template: "basic"` (no Slurm native args)
- [ ] `before.sh.erb`:
      - `find_port`, `create_passwd`
      - Write credential file (mode 600)
      - Write `~/.claude/settings.json` if absent
      - Set `SINGULARITY_IMAGE_PATH` to the SIF
- [ ] `script.sh.erb`:
      - `cd ${WORKING_DIR}`
      - `tmux new-session -d -s claude-code claude`
      - `exec ttyd --port ${port} --base-path ... --credential-file ...
           tmux attach-session -t claude-code`
- [ ] `after.sh.erb` — `wait_until_port_used`
- [ ] `view.html.erb` — connect button (POST form with hidden password)

### Phase 2: Integration Testing (1 day)

- [ ] End-to-end: OOD → paste API key → Launch → browser terminal →
      Claude Code responds to prompts
- [ ] Test OOD "Delete" — clean tmux/claude shutdown
- [ ] Test with a user who has no existing `~/.claude/settings.json`
- [ ] Test with a user who has an existing `settings.json` (preserved)
- [ ] Test invalid API key — Claude starts but API calls fail with
      clear error; user can check OOD logs
- [ ] Test session reconnect — close browser tab, click "Connect" again
      (ttyd reconnects to same tmux session)
- [ ] Test SSH attach — `ssh <node>` + `tmux attach -t claude-code`

### Phase 3: Deploy (1 day)

- [ ] Add gitclone init container to `slac-ondemand` deployment
      (same pattern as `slac-ood-jupyter`)
- [ ] Add volume + volumeMount in `ondemand-patch.yaml`
- [ ] Add cluster config if needed (or reuse existing interactive clusters)
- [ ] Confirm SIF image is accessible from interactive nodes
- [ ] Deploy to S3DF OOD
- [ ] Write user-facing docs (link from `docs/claude-code.md`)

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
