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

---

## Goals

1. User can choose between **Bedrock** and **SDF-Sage (LiteLLM)** as the LLM
   provider via a radio button or select widget on the form
2. Selecting Bedrock shows the existing API key field (unchanged behaviour)
3. Selecting SDF-Sage shows a `facility:repo` text field and a provider
   sub-select (e.g. `copilot`, `s3df`, `bedrock`, …)
4. `before.sh.erb` writes the correct `~/.claude/settings.json` block for the
   selected provider:
   - **Bedrock:** existing block (ANTHROPIC_BASE_URL=ai-api.slac.stanford.edu,
     ANTHROPIC_AUTH_TOKEN=key)
   - **SDF-Sage:** new block (ANTHROPIC_BASE_URL=https://llm.sdf.slac.stanford.edu,
     NODE_TLS_REJECT_UNAUTHORIZED=0, model env vars using `facility:repo/model`
     naming, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
5. `form.js` shows/hides fields dynamically based on the provider selection
6. The API key field remains masked as password-type when visible

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
overwrite_settings — check_box (existing, unchanged)
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
  - overwrite_settings
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

### `before.sh.erb` — provider-branched settings block

Current settings block is replaced with a conditional:

```bash
SHOULD_OVERWRITE="<%= context.overwrite_settings == "1" ? "yes" : "no" %>"
LLM_PROVIDER="<%= context.llm_provider %>"

if [ ! -f "${HOME}/.claude/settings.json" ] || [ "${SHOULD_OVERWRITE}" = "yes" ]; then
  mkdir -p "${HOME}/.claude"
  # Back up if overwriting
  if [ "${SHOULD_OVERWRITE}" = "yes" ] && [ -f "${HOME}/.claude/settings.json" ]; then
    BACKUP="${HOME}/.claude/settings.json.bak.$(date +%Y%m%d_%H%M%S)"
    cp "${HOME}/.claude/settings.json" "${BACKUP}"
    echo "Backed up existing settings to ${BACKUP}"
  fi

  (
  umask 077
  DELIM="SETTINGS_EOF_${RANDOM}"

  if [ "${LLM_PROVIDER}" = "bedrock" ]; then
    cat > "${HOME}/.claude/settings.json" << ${DELIM}
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://ai-api.slac.stanford.edu",
    "ANTHROPIC_AUTH_TOKEN": "<%= context.api_key %>",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "us.anthropic.claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_OPUS_MODEL":   "us.anthropic.claude-opus-4-6-v1",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL":  "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
${DELIM}

  else
    # SDF-Sage LiteLLM proxy
    # sdf_sage_provider is e.g. "copilot", "s3df", "bedrock"
    # sdf_sage_repo is e.g. "scs:admin" — prefixed to each model name
    <%
      provider = context.sdf_sage_provider.to_s.strip
      repo     = context.sdf_sage_repo.to_s.strip
      # Validate: facility:repo format, safe characters only
      repo     = "" unless repo.match?(/\A[A-Za-z0-9_\-]+:[A-Za-z0-9_\-\/]+\z/)
      provider = "" unless provider.match?(/\A[A-Za-z0-9_\-]+\z/)
    %>
    cat > "${HOME}/.claude/settings.json" << ${DELIM}
{
  "env": {
    "ANTHROPIC_BASE_URL":                    "https://llm.sdf.slac.stanford.edu",
    "NODE_TLS_REJECT_UNAUTHORIZED":          "0",
    "ANTHROPIC_SMALL_FAST_MODEL":            "<%= repo %>/<%= provider %>/claude-haiku-4.5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL":         "<%= repo %>/<%= provider %>/claude-haiku-4.5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL":        "<%= repo %>/<%= provider %>/claude-sonnet-4.6",
    "ANTHROPIC_DEFAULT_OPUS_MODEL":          "<%= repo %>/<%= provider %>/claude-opus-4.6",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
${DELIM}
  fi
  )

  chmod go-rwx "${HOME}/.claude/settings.json"
  echo "Wrote ~/.claude/settings.json for provider: ${LLM_PROVIDER}"
else
  echo "~/.claude/settings.json already exists — preserving existing config."
fi
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

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Provider selection widget | `select` (not radio) | Consistent with other OOD form widgets; easy to extend with more providers later |
| Field visibility | JS show/hide + `disabled` attribute | OOD's `form.js` pattern; disabled fields not validated as required |
| Input validation | ERB regex in `before.sh.erb` | Prevents shell injection via `facility:repo` field; empty string fallback writes a visibly broken config rather than executing arbitrary code |
| `NODE_TLS_REJECT_UNAUTHORIZED: "0"` | Included for SDF-Sage | LiteLLM proxy uses self-signed cert; required for Claude Code to connect |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `"1"` for SDF-Sage only | Prevents Claude Code from calling anthropic.com for telemetry/updates when routing through LiteLLM |
| No ANTHROPIC_AUTH_TOKEN for SDF-Sage | Omitted | LiteLLM proxy uses facility allocation auth, not a per-user Bedrock key |
| api_key `required: true` | Needs conditional | Must be `required: false` when SDF-Sage is selected; form.js `disabled` attr handles this — OOD skips validation for disabled fields |

---

## Implementation Plan

### Step 1 — Update `form.yml.erb`

Add `llm_provider`, `sdf_sage_provider`, `sdf_sage_repo` attributes. Change
`api_key` from `required: true` to `required: false` (JS enforcement when
Bedrock is selected is sufficient; server-side the field arrives empty for
SDF-Sage). Update `form:` field order.

### Step 2 — Update `form.js`

Add `update_provider_fields()` function and `toggle_field()` helper. Call on
page load and on provider `change` event. Keep existing `filter_interactive_clusters()`
and `mask_api_key()` (only runs when api_key is visible).

### Step 3 — Update `before.sh.erb`

Replace the single settings block with the provider-branched conditional (see
Design). Add ERB-level input validation for `sdf_sage_repo` and
`sdf_sage_provider`. Keep existing ttyd credential file and SIF path logic
unchanged.

### Step 4 — Smoke test

Launch a session with each provider:
- **Bedrock:** existing settings block written correctly; api_key field masked
- **SDF-Sage:** new settings block written with correct model names; api_key
  field hidden; `facility:repo` visible and submitted

---

## Implementation Checklist

- [ ] Update `form.yml.erb`: add `llm_provider`, `sdf_sage_provider`, `sdf_sage_repo`; set `api_key: required: false`
- [ ] Update `form.js`: add `update_provider_fields()`, `toggle_field()`; call on load + change
- [ ] Update `before.sh.erb`: provider-branched settings block; ERB input validation for sdf_sage fields
- [ ] Smoke test Bedrock path: settings.json correct, api_key masked, overwrite_settings works
- [ ] Smoke test SDF-Sage path: settings.json correct, model names formatted as `facility:repo/provider/model`
- [ ] Verify hidden fields are not submitted / not required when provider is not selected

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

3. **Should `api_key` be truly optional at the form level?** — If `required:
   false` is set, OOD won't block submission even when Bedrock is selected and
   the field is empty. The `disabled` attribute from JS should prevent this in
   practice, but a server-side guard in `before.sh.erb` (error if Bedrock
   selected and key is empty) would be safer.

4. **What is the exact `facility:repo` format users should enter?** — The example
   uses `scs:admin`. Confirm format and provide an example in the field's `help:`
   text. Is the separator always `:`? Are there multi-level repos?

---

## Relationship to Other Tasks

- **#001 (OOD App):** This task modifies the form and `before.sh.erb` introduced
  in #001.
- **#003 (HTTPS/ttyd):** Independent; no interaction.
