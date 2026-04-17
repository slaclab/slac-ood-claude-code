# TODO #005 — Improved SDF-Sage token auth (OOD-native)

> **Priority:** 🔵 P3 — Low
> **Status:** 📋 Preparing
> **Branch:** —
> **PR:** —
> **Created:** 2026-04-17
> **Shipped:** —

---

## Problem Statement

The SDF-Sage LiteLLM path (introduced in #004) authenticates Claude Code via
`~/.s3df-access-token`, obtained out-of-band via a device flow step the user
must run before launching the OOD session. This has several issues:

- The token expires. When it does, Claude Code silently fails mid-session with
  an auth error. There is no in-session refresh mechanism.
- The device flow is a manual prerequisite entirely outside the OOD interface.
  Users who skip it (or whose token has expired) get no warning until Claude
  Code fails.
- The `~/.s3df-access-token` file approach is fragile — wrong permissions,
  wrong path, or a corrupt file all produce the same opaque failure.

A better solution would integrate token acquisition/refresh into the OOD
session lifecycle (before.sh / after.sh) or leverage the existing OOD auth
session to obtain a token automatically, eliminating the out-of-band step
entirely. This likely requires coordination with the S3DF identity/auth team
and may involve changes to how OOD itself handles authentication.

### What fails today

| Scenario | Current behaviour | Desired behaviour |
|----------|-------------------|-------------------|
| Token expired mid-session | Claude Code auth errors, no recovery path | Token auto-refreshed, session continues |
| User skips device flow | Session launches, Claude fails silently | Token obtained automatically at session start |
| Token file missing/corrupt | Opaque auth failure | Clear error with self-service recovery |

---

## Goals

1. SDF-Sage users can launch a Claude Code session without any out-of-band auth
   prerequisite
2. Token expiry does not silently break a running session
3. The solution integrates with the existing OOD/S3DF auth model

## Non-Goals

- Redesigning S3DF identity infrastructure
- Supporting non-S3DF token providers
- Changes to the Bedrock auth path

---

## Design

_To be filled in — requires investigation of OOD auth hooks and S3DF token
issuance APIs. Run `/codebase-draft` once the auth team has provided input._

---

## Open Questions

1. **Can OOD's existing auth session be used to obtain an S3DF access token
   automatically?** — Requires input from S3DF identity/auth team.
2. **What is the token TTL, and is a refresh endpoint available?** — Needed to
   design a refresh strategy.
3. **Is there an OOD hook (before.sh, after.sh, or a separate wrapper) that
   can run a non-interactive token refresh without user interaction?**

---

## Relationship to Other Tasks

- **#004 (LLM provider selection):** This task improves the auth story introduced
  in #004. #004 ships with the `~/.s3df-access-token` workaround and a startup
  warning; this task replaces that workaround with a proper solution.
