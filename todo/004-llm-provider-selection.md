# TODO #004 — LLM provider selection in OOD form (Bedrock + SDF-Sage LiteLLM)

> **Priority:** 🟡 P2 — Medium
> **Status:** 📋 Preparing
> **Branch:** —
> **PR:** —
> **Created:** 2026-04-15
> **Shipped:** —

---

## Problem Statement

The OOD form today has a single path: user enters a Bedrock API key, and
`before.sh.erb` writes `~/.claude/settings.json` pointing at
`https://ai-api.slac.stanford.edu` with that key.

SLAC now also operates `llm.sdf.slac.stanford.edu` — a LiteLLM proxy
(sdf-sage) that provides access to models via facility/repo allocation tokens
rather than personal Bedrock keys. Users in allocations on this proxy should be
able to run Claude Code without a Bedrock key, using their facility quota
instead.

The two auth models are mutually exclusive per session — the form needs to let
the user choose, and `before.sh.erb` needs to write the correct settings block
for each.

### What fails today

| Scenario | Current behaviour | Desired behaviour |
|----------|-------------------|-------------------|
| User with LiteLLM repo allocation | Must still enter a Bedrock key — no LiteLLM path exists | Can select LiteLLM provider, enter `facility:repo`, and launch without a Bedrock key |
| User with Bedrock key | Works today | Unchanged |
| Form layout | Single text field (api_key) always visible | API key field hidden when LiteLLM selected; repo field shown instead |
| settings.json update | Full file rewrite only on first launch or "overwrite" checkbox | Relevant ENV entries always updated on each launch (via `sed` in-place); full clear only when "Clear settings.json" checked |
| "Overwrite existing settings" checkbox | Rewrites entire `~/.claude/settings.json` | Renamed to **"Clear settings.json"** — deletes the file entirely so Claude Code rewrites it from scratch; normal path always updates just the provider ENV keys |

---

## Goals

1. User can choose between **Bedrock** and **SDF-Sage (LiteLLM)** as the LLM
   provider via a radio button or select widget on the form
2. Selecting Bedrock shows the existing API key field (unchanged behaviour)
3. Selecting SDF-Sage shows a `facility:repo` text field and a provider
   sub-select (e.g. `copilot`, `s3df`, `bedrock`, …)
4. `before.sh.erb` **always updates** the relevant ENV keys in
   `~/.claude/settings.json` on every session launch — using `sed` to update
   entries in-place if the file exists, or writing a fresh file if it doesn't.
   The two URL/auth blocks:
   - **Bedrock:** `ANTHROPIC_BASE_URL=https://ai-api.slac.stanford.edu` +
     `ANTHROPIC_AUTH_TOKEN=<key>`
   - **SDF-Sage:** `ANTHROPIC_BASE_URL=https://llm.sdf.slac.stanford.edu` +
     model env vars using `facility:repo/provider/model` naming +
     `NODE_TLS_REJECT_UNAUTHORIZED=0` +
     `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
5. The **"Overwrite existing settings"** checkbox is renamed to **"Clear
   settings.json"** — when checked it deletes `~/.claude/settings.json`
   entirely before the session starts, allowing Claude Code to recreate it
   from scratch. Useful after a corruption or major config reset. The normal
   path (unchecked) always updates just the provider ENV keys in-place.
6. `form.js` shows/hides fields dynamically based on the provider selection
7. The API key field remains masked as password-type when visible

## Non-Goals

- Supporting providers other than Bedrock and SDF-Sage LiteLLM at this time
- Validating the `facility:repo` allocation against the LiteLLM API at form
  submission time
- Changing how ttyd auth or the SIF version selection works

---

## Design

### Form fields

New and changed fields in `form.yml.erb`:

```
llm_provider     — select: "bedrock" | "sdf_sage"   (new, shown always)
api_key          — text_field (existing, shown only when llm_provider=bedrock)
sdf_sage_repo    — text_field "facility:repo"        (new, shown only when llm_provider=sdf_sage)
sdf_sage_provider— select: copilot | s3df | bedrock  (new, shown only when llm_provider=sdf_sage)
clear_settings   — check_box "Clear settings.json"   (replaces overwrite_settings)
```

### Field ordering in `form:`

```yaml
form:
  - llm_provider
  - api_key
  - sdf_sage_provider
  - sdf_sage_repo
  - cluster
  - sif_version
  - working_dir
  - bc_num_hours
  - bc_email_on_started
  - clear_settings
```

### `form.js` — show/hide logic

```javascript
function update_provider_fields() {
  const provider = $('#batch_connect_session_context_llm_provider').val();
  const is_bedrock  = provider === 'bedrock';
  const is_sdf_sage = provider === 'sdf_sage';

  toggle_field('api_key',           is_bedrock);
  toggle_field('sdf_sage_provider', is_sdf_sage);
  toggle_field('sdf_sage_repo',     is_sdf_sage);
}

// toggle_field shows/hides the OOD form-group div wrapping a field
function toggle_field(id, visible) {
  const el = $('#batch_connect_session_context_' + id);
  el.closest('.form-group').toggle(visible);
  // Disable hidden fields so they are not submitted / treated as required
  el.prop('disabled', !visible);
}

$('#batch_connect_session_context_llm_provider').on('change', update_provider_fields);
update_provider_fields();  // run on load to set initial state
```

Note: disabling hidden fields prevents OOD from enforcing `required: true` on
hidden inputs and keeps the submitted params clean.

### `before.sh.erb` — always-update via `sed`, optional clear

The key behavioural change: instead of a write-once-or-overwrite pattern, we
**always `sed` the relevant ENV keys** into `~/.claude/settings.json` on every
launch. This means switching providers between sessions Just Works without the
user needing to remember to check a box.

The **"Clear settings.json"** checkbox (replaces "Overwrite existing settings")
deletes the file entirely *before* the update step — useful for resetting all
custom config (keybindings, permissions, etc.) that the sed approach would
otherwise preserve.

**ENV keys managed by this script (always updated):**
- Bedrock path: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
  `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`,
  `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`
- SDF-Sage path: `ANTHROPIC_BASE_URL`, `NODE_TLS_REJECT_UNAUTHORIZED`,
  `ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`,
  `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`,
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`

**Top-level settings keys managed (SDF-Sage only):**
- `apiKeyHelper`: `"cat ~/.s3df-access-token"` — LiteLLM uses an S3DF access
  token rather than a static API key; this helper command is run by Claude Code
  to obtain the token at request time.

Note: `apiKeyHelper` is a **top-level** key in `settings.json`, not nested
inside `env`. The sed upsert logic must handle both `env.*` keys and this
top-level key separately. When switching to Bedrock, `apiKeyHelper` must be
removed (it would interfere with Bedrock auth). The `python3 json` approach is
cleaner here than sed for a mixed top-level + nested update.

Keys not in these lists (user customisations) are left untouched.

```bash
<%
  llm_provider    = context.llm_provider.to_s.strip
  api_key         = context.api_key.to_s.strip
  sdf_provider    = context.sdf_sage_provider.to_s.strip
  sdf_repo        = context.sdf_sage_repo.to_s.strip
  sdf_repo        = "" unless sdf_repo.match?(/\A[A-Za-z0-9_\-]+:[A-Za-z0-9_\-\/]+\z/)
  sdf_provider    = "" unless sdf_provider.match?(/\A[A-Za-z0-9_\-]+\z/)
  clear_settings  = context.clear_settings == "1"
%>

LLM_PROVIDER="<%= llm_provider %>"
SETTINGS="${HOME}/.claude/settings.json"

# Clear settings.json if checkbox was ticked
<% if clear_settings %>
if [ -f "${SETTINGS}" ]; then
  BACKUP="${SETTINGS}.bak.$(date +%Y%m%d_%H%M%S)"
  mv "${SETTINGS}" "${BACKUP}"
  echo "Cleared settings.json (backed up to ${BACKUP})"
fi
<% end %>

# Build the env block for this provider
if [ "${LLM_PROVIDER}" = "bedrock" ]; then
  declare -A CLAUDE_ENVS=(
    [ANTHROPIC_BASE_URL]="https://ai-api.slac.stanford.edu"
    [ANTHROPIC_AUTH_TOKEN]="<%= api_key %>"
    [ANTHROPIC_DEFAULT_SONNET_MODEL]="us.anthropic.claude-sonnet-4-6"
    [ANTHROPIC_DEFAULT_OPUS_MODEL]="us.anthropic.claude-opus-4-6-v1"
    [ANTHROPIC_DEFAULT_HAIKU_MODEL]="us.anthropic.claude-haiku-4-5-20251001-v1:0"
    [CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS]="1"
  )
  CLAUDE_TOP_LEVEL=()
  # Remove SDF-Sage-only keys that may linger from a previous session
  REMOVE_KEYS=(NODE_TLS_REJECT_UNAUTHORIZED ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)
  REMOVE_TOP_LEVEL_KEYS=(apiKeyHelper)
else
  declare -A CLAUDE_ENVS=(
    [ANTHROPIC_BASE_URL]="https://llm.sdf.slac.stanford.edu"
    [NODE_TLS_REJECT_UNAUTHORIZED]="0"
    [ANTHROPIC_SMALL_FAST_MODEL]="<%= sdf_repo %>/<%= sdf_provider %>/claude-haiku-4.5"
    [ANTHROPIC_DEFAULT_HAIKU_MODEL]="<%= sdf_repo %>/<%= sdf_provider %>/claude-haiku-4.5"
    [ANTHROPIC_DEFAULT_SONNET_MODEL]="<%= sdf_repo %>/<%= sdf_provider %>/claude-sonnet-4.6"
    [ANTHROPIC_DEFAULT_OPUS_MODEL]="<%= sdf_repo %>/<%= sdf_provider %>/claude-opus-4.6"
    [CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC]="1"
  )
  CLAUDE_TOP_LEVEL=( [apiKeyHelper]="cat ~/.s3df-access-token" )
  # Remove Bedrock-only keys that may linger from a previous session
  REMOVE_KEYS=(ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS)
  REMOVE_TOP_LEVEL_KEYS=()
fi

# Ensure settings.json exists with minimal structure if absent
mkdir -p "${HOME}/.claude"
if [ ! -f "${SETTINGS}" ]; then
  (umask 077; printf '{"env":{}}\n' > "${SETTINGS}")
fi

# Upsert each key into the "env" object using sed.
# Pattern: find existing "KEY": "..." line and replace value,
#          or append before the closing } of the env block if absent.
upsert_env_key() {
  local key="$1" value="$2" file="$3"
  # Escape value for sed replacement (forward slashes, ampersands)
  local escaped
  escaped="$(printf '%s' "${value}" | sed 's/[\/&]/\\&/g')"
  if grep -q "\"${key}\"" "${file}"; then
    sed -i "s|\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"${key}\": \"${escaped}\"|g" "${file}"
  else
    # Append before the closing } of the env block
    sed -i "/\"env\"[[:space:]]*:[[:space:]]*{/,/}/{
      /}[[:space:]]*$/{
        s|}[[:space:]]*$|  \"${key}\": \"${escaped}\"\n  }|
      }
    }" "${file}"
  fi
}

for key in "${!CLAUDE_ENVS[@]}"; do
  upsert_env_key "${key}" "${CLAUDE_ENVS[$key]}" "${SETTINGS}"
done

# Remove keys belonging to the other provider
for key in "${REMOVE_KEYS[@]}"; do
  sed -i "/\"${key}\"[[:space:]]*:/d" "${SETTINGS}"
done

chmod go-rwx "${SETTINGS}"
echo "Updated ~/.claude/settings.json for provider: ${LLM_PROVIDER}"
```

> **Note:** The `upsert_env_key` sed logic above is indicative. The exact
> implementation should be validated against real settings.json files —
> especially the append-if-absent branch, which depends on the file's
> formatting. Because `apiKeyHelper` is a **top-level key** (not inside `env`),
> a pure sed approach requires two separate patterns. Using `python3 -c` with
> the `json` module is strongly preferred — it handles both `env.*` keys and
> top-level keys cleanly and is immune to JSON formatting variations.

### "Clear settings.json" checkbox

Replaces `overwrite_settings`. Label and help text in `form.yml.erb`:

```yaml
clear_settings:
  widget: "check_box"
  label: "Clear settings.json"
  help: |
    Deletes `~/.claude/settings.json` before starting, allowing Claude Code
    to recreate it from scratch. Use after a major config reset or corruption.
    Your provider and API key will be written fresh. **All other customisations
    (permissions, keybindings, etc.) will be lost.**
  value: "0"
```

### Model name format for SDF-Sage

Based on the env vars provided:

```
"scs:admin/copilot/claude-haiku-4.5"
```

The pattern is `<facility>:<repo>/<provider>/<model-name>`. The `sdf_sage_repo`
field captures `<facility>:<repo>` (e.g. `scs:admin`) and `sdf_sage_provider`
captures the routing segment (e.g. `copilot`, `s3df`, `bedrock`). These are
concatenated in `before.sh.erb` at settings-write time.

### SDF-Sage: device flow prerequisite

The `apiKeyHelper` command (`cat ~/.s3df-access-token`) only works if the user
has already authenticated via **device flow** to obtain their S3DF access token.
This is a one-time setup step that happens outside the OOD session.

The form's help text for the SDF-Sage option should include a note along the
lines of:

> **Prerequisite:** You must have an S3DF access token at `~/.s3df-access-token`.
> If you haven't done this yet, run the device flow authentication first:
> `[link to S3DF auth docs]`

The session will launch successfully regardless, but Claude Code will fail to
authenticate to the LiteLLM proxy until the token file exists.

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Provider selection widget | `select` (not radio) | Consistent with other OOD form widgets; easy to extend with more providers later |
| Field visibility | JS show/hide + `disabled` attribute | OOD's `form.js` pattern; disabled fields not validated as required |
| Settings update strategy | `sed` upsert on every launch | Users can switch provider between sessions without touching a checkbox; other customisations (keybindings, permissions) are preserved |
| "Overwrite" → "Clear" | Rename checkbox, change semantics | "Overwrite" implied a full rewrite every time; "Clear" is a deliberate reset action, distinct from the normal always-update path |
| Stale key removal | `sed -i "/KEY/d"` for other-provider keys | Prevents e.g. `ANTHROPIC_AUTH_TOKEN` lingering when user switches to SDF-Sage |
| Input validation | ERB regex in `before.sh.erb` | Prevents shell injection via `facility:repo` field; empty string fallback writes visibly broken (but harmless) config |
| `NODE_TLS_REJECT_UNAUTHORIZED: "0"` | Included for SDF-Sage | LiteLLM proxy uses self-signed cert; required for Claude Code to connect |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `"1"` for SDF-Sage only | Prevents Claude Code calling anthropic.com for telemetry/updates when routing through LiteLLM |
| No ANTHROPIC_AUTH_TOKEN for SDF-Sage | Omitted | LiteLLM proxy uses facility allocation auth, not a per-user key |
| `apiKeyHelper` for SDF-Sage | `"cat ~/.s3df-access-token"` (top-level key) | LiteLLM uses S3DF token auth; `apiKeyHelper` is how Claude Code fetches it at request time; must be removed when switching to Bedrock |
| JSON manipulation approach | `python3 -c 'import json...'` preferred over sed | `apiKeyHelper` is top-level (not in `env`); python3 handles mixed top-level + nested cleanly; sed requires two separate patterns and is fragile |

---

## Implementation Plan

### Step 1 — Update `form.yml.erb`

Add `llm_provider`, `sdf_sage_provider`, `sdf_sage_repo` attributes. Rename
`overwrite_settings` → `clear_settings` with updated label/help. Change
`api_key` from `required: true` to `required: false`. Update `form:` field
order.

### Step 2 — Update `form.js`

Add `update_provider_fields()` function and `toggle_field()` helper. Call on
page load and on provider `change` event. Keep existing
`filter_interactive_clusters()` and `mask_api_key()`.

### Step 3 — Update `before.sh.erb`

Replace the write-once settings block with the sed-based upsert approach (see
Design). Add ERB-level input validation for `sdf_sage_repo` and
`sdf_sage_provider`. Handle stale key removal for the non-selected provider.
Replace `overwrite_settings` reference with `clear_settings` (delete-then-
recreate semantics).

Validate the sed append-if-absent branch against real settings.json files
before shipping — consider falling back to `python3 -c 'import json,sys; ...'`
if sed proves fragile on OOD's JSON formatting.

### Step 4 — Smoke test

Launch a session with each provider:
- **Bedrock:** correct settings block; api_key masked; SDF-Sage keys absent
- **SDF-Sage:** correct settings block; model names `facility:repo/provider/model`; Bedrock keys absent; api_key field hidden
- **Switch provider between sessions:** keys updated correctly without clear checkbox
- **Clear checkbox:** file deleted and recreated fresh

---

## Implementation Checklist

- [ ] Update `form.yml.erb`: add `llm_provider`, `sdf_sage_provider`, `sdf_sage_repo`; rename `overwrite_settings` → `clear_settings`; set `api_key: required: false`; add device flow prerequisite note to SDF-Sage help text
- [ ] Update `form.js`: add `update_provider_fields()`, `toggle_field()`; call on load + change
- [ ] Update `before.sh.erb`: python3-json upsert for both `env.*` keys and top-level `apiKeyHelper`; stale key + `apiKeyHelper` removal on Bedrock path; `clear_settings` delete-before-write; ERB input validation
- [ ] Smoke test Bedrock path: settings.json correct, api_key masked, SDF-Sage keys + `apiKeyHelper` absent
- [ ] Smoke test SDF-Sage path: settings.json correct, model names `facility:repo/provider/model`, `apiKeyHelper` present, Bedrock keys absent
- [ ] Smoke test provider switch: launch Bedrock then SDF-Sage without clearing — verify keys updated, `apiKeyHelper` added/removed
- [ ] Smoke test "Clear settings.json": file deleted and recreated correctly

---

## Open Questions

1. **What providers should appear in `sdf_sage_provider`?** — From the example
   env vars: `copilot` and presumably `s3df`, `bedrock`. Confirm the full list
   with the sdf-sage / litellm admin. This affects the select options in
   `form.yml.erb`.

2. **Is `NODE_TLS_REJECT_UNAUTHORIZED: "0"` safe long-term?** — It disables TLS
   verification for the LiteLLM proxy connection from Claude Code. The LiteLLM
   proxy should ideally get a valid cert (Let's Encrypt or SLAC CA). Until then,
   `"0"` is required. Track separately.

3. **Server-side guard for empty Bedrock key** — the sed upsert will write
   `"ANTHROPIC_AUTH_TOKEN": ""` if the user somehow submits Bedrock with no
   key (e.g. JS disabled). Add an ERB guard: if `llm_provider == "bedrock"` and
   `api_key` is blank, abort with a clear error message.

4. **What is the exact `facility:repo` format users should enter?** — The example
   uses `scs:admin`. Confirm format and provide an example in the field's `help:`
   text. Is the separator always `:`? Are there multi-level repos?

---

## Relationship to Other Tasks

- **#001 (OOD App):** This task modifies the form and `before.sh.erb` introduced
  in #001.
- **#003 (HTTPS/ttyd):** Independent; no interaction.
