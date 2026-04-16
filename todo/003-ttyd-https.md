# TODO #003 — Encrypt OOD → ttyd traffic with HTTPS/WSS

> **Priority:** 🔵 P3 — Low
> **Status:** 📋 Preparing
> **Branch:** —
> **PR:** —
> **Created:** 2026-04-15
> **Shipped:** —

---

## Problem Statement

The connection between the OOD Apache reverse proxy (running in the Kubernetes pod)
and the ttyd process on the interactive node is plain HTTP/WS, even though the
browser-facing connection is HTTPS. For a zero-trust posture, all traffic should
be encrypted — including the cluster-internal leg.

Current flow:
```
Browser ──HTTPS──▶ Apache (OOD pod) ──HTTP/WS──▶ ttyd (interactive node :PORT)
```

Desired flow:
```
Browser ──HTTPS──▶ Apache (OOD pod) ──HTTPS/WSS──▶ ttyd (interactive node :PORT)
```

### What fails today

| Scenario | Current behaviour | Desired behaviour |
|----------|-------------------|-------------------|
| Cluster network sniffing | ttyd traffic visible in plaintext | Traffic is TLS-encrypted end to end |
| Zero-trust compliance | Internal HTTP hop violates zero-trust | All hops encrypted regardless of network trust |

---

## Goals

1. ttyd listens on HTTPS/WSS using a per-session TLS certificate
2. Apache (OOD pod) proxies to `https://host:port/` and `wss://host:port/` instead of `http://`
3. Apache verifies the certificate chain fully — `SSLProxyVerify require`, no disabled checks
4. A cluster CA is used to sign session certs so Apache can verify them without trusting arbitrary self-signed certs
5. Cert and key are written with `umask 077`, deleted promptly after ttyd starts
6. Password in process list remains unexposed (existing `--credential-file` protection retained)

## Non-Goals

- Replacing `--auth-header X-Forwarded-User` or `--credential-file` auth layers
- Encrypting traffic between the user's browser and OOD (already HTTPS)
- Upstream contribution to OOD (may move to `slac-ondemand` repo later)

---

## Design

### Architecture

The change spans three components:

```
1. proxy.lua (OOD pod)       — hardcoded "ws://"/"http://", needs patching
2. ood_portal.yml            — needs SSLProxy directives via custom_location_directives
3. before.sh.erb / script.sh.erb — generate session cert, pass --ssl flags to ttyd
```

### Key finding: OOD_SECURE_UPSTREAM does NOT exist in deployed version

Inspected the actual `proxy.lua` from the prod OOD pod (2026-04-15):

```lua
-- /opt/ood/mod_ood_proxy/lib/ood/proxy.lua  (current)
local protocol = (r.headers_in['Upgrade'] and "ws://" or "http://")
```

The protocol is **hardcoded**. There is no `OOD_SECURE_UPSTREAM` env var or any
conditional. This must be patched via a ConfigMap volumeMount.

### Component 1 — Patch `proxy.lua`

Mount a patched version via ConfigMap over
`/opt/ood/mod_ood_proxy/lib/ood/proxy.lua` in the OOD deployment:

```lua
-- patched: respect OOD_SECURE_UPSTREAM env var
local secure = r.subprocess_env['OOD_SECURE_UPSTREAM'] == 'yes'
local protocol = r.headers_in['Upgrade'] and (secure and "wss://" or "ws://")
                                          or  (secure and "https://" or "http://")
```

The env var is set per-LocationMatch in `ood_portal.yml` (see Component 2), so it
only applies to the `/node/` proxy — not PUN or other paths.

### Component 2 — `ood_portal.yml` `custom_location_directives`

The ood-portal.conf.erb template already supports `custom_location_directives`,
which are injected verbatim into the `/node/` LocationMatch block. No template
patching required.

```yaml
custom_location_directives:
  - 'SSLProxyEngine on'
  - 'SSLProxyVerify require'
  - 'SSLProxyCACertificateFile "/etc/pki/tls/ood-node-ca/ca.crt"'
  - 'SSLProxyCheckPeerCN on'
  - 'SSLProxyCheckPeerExpire on'
  - 'SetEnv OOD_SECURE_UPSTREAM yes'
```

`SSLProxyCheckPeerCN on` verifies the cert's CN/SAN matches the hostname Apache
is connecting to (the interactive node FQDN) — the per-session cert must include
the node hostname as CN or SAN.

### Component 3 — Cluster CA

Rather than trusting arbitrary self-signed certs (which would require disabling
verification and provide no security), all per-session ttyd certs are signed by a
single cluster CA. The CA cert is shipped to the OOD pod as a ConfigMap and
mounted at `/etc/pki/tls/ood-node-ca/ca.crt`.

Two sub-options:

**Option A — Generate CA once, bake into OOD deployment (simpler)**
- Generate a long-lived CA key+cert offline
- Store CA cert as ConfigMap in `slac-ondemand` (public) and CA key as a K8s
  Secret (the signing key never touches the OOD pod)
- `before.sh.erb` generates a per-session cert+CSR, signs it with the CA key
  — but the CA key must be accessible to the session script on the interactive
  node, which is awkward

**Option B — Self-signed per-session cert, CA = cert itself (simpler trust)**
- Generate per-session self-signed cert in `before.sh.erb`
- Push the cert (as its own CA) to a location the OOD pod can read at proxy time
- Hard: OOD pod can't dynamically reload `SSLProxyCACertificateFile` per request

**Option C — Static cluster CA cert+key distributed to interactive nodes**
- CA key lives at a fixed path on interactive nodes (e.g. `/etc/ood/ca/ca.key`,
  mode 0600, root-owned)
- `before.sh.erb` calls `openssl x509 -req` to sign the session cert with it
- CA cert is a ConfigMap on the OOD pod
- Signing key never leaves the node; CA cert is not secret

**Recommendation: Option C.** The CA key stays on the interactive nodes (where
the session runs), the CA cert goes to the OOD pod. No key material flows between
components at session time.

### Component 4 — `before.sh.erb` cert generation

```bash
# Generate per-session TLS cert signed by cluster CA
TTYD_TLS_KEY="${HOME}/ondemand/.ttyd-$$.key"
TTYD_TLS_CERT="${HOME}/ondemand/.ttyd-$$.crt"
export TTYD_TLS_KEY TTYD_TLS_CERT

(umask 077
 openssl req -newkey rsa:2048 -nodes \
   -keyout "${TTYD_TLS_KEY}" \
   -subj "/CN=${host}" \
   -addext "subjectAltName=DNS:${host}" \
 | openssl x509 -req -days 1 \
     -CA /etc/ood/ca/ca.crt \
     -CAkey /etc/ood/ca/ca.key \
     -CAcreateserial \
     -out "${TTYD_TLS_CERT}"
)
```

CN and SAN set to `${host}` (the interactive node FQDN) so `SSLProxyCheckPeerCN`
passes.

### Component 5 — `script.sh.erb` ttyd invocation

Add `--ssl --ssl-cert "${TTYD_TLS_CERT}" --ssl-key "${TTYD_TLS_KEY}"` to the
ttyd invocation. Delete cert+key 2s after startup (same pattern as credential
file — ttyd reads them once at startup).

```bash
apptainer exec -B /sdf,/fs,/lscratch "${CLAUDE_SIF}" \
  ttyd \
    --port ${port} \
    --base-path "/node/${host}/${port}/" \
    --auth-header X-Forwarded-User \
    --credential-file "${TTYD_CRED_FILE}" \
    --ssl \
    --ssl-cert "${TTYD_TLS_CERT}" \
    --ssl-key "${TTYD_TLS_KEY}" \
    --writable \
    claude &
TTYD_PID=$!

sleep 2
rm -f "${TTYD_CRED_FILE}" "${TTYD_TLS_KEY}" "${TTYD_TLS_CERT}"

wait ${TTYD_PID}
```

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| CA approach | Option C (static CA on nodes) | CA key stays on interactive nodes; no key material crosses trust boundaries at session time |
| cert lifetime | 1 day | Short-lived; session is hours at most |
| cert deleted after startup | Yes (2s sleep, same as credential file) | ttyd reads cert at startup only; file is dead weight after that |
| proxy.lua delivery | ConfigMap volumeMount | Reviewable; no in-image patching; survives OOD upgrades via explicit override |
| SSLProxyVerify | `require` (not `none`) | `none` is equivalent to no TLS (MITM trivial); defeats the purpose |
| Future home | `slac-ondemand` repo | proxy.lua patch and ood_portal.yml changes belong in the OOD overlay, not the app repo. Keep here for now. |

---

## Implementation Plan

### Step 1 — Generate cluster CA

```bash
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key \
  -subj "/CN=SLAC OOD Node Proxy CA" \
  -out ca.crt
```

Store `ca.key` securely for distribution to interactive nodes.
Store `ca.crt` — goes into a ConfigMap for the OOD pod.

### Step 2 — Distribute CA key to interactive nodes

Deploy `/etc/ood/ca/ca.key` (mode 0640, group `ood-ca` or similar) and
`/etc/ood/ca/ca.crt` to all interactive nodes that host OOD batch connect
sessions (sdfiana, sdfturing, sdfada, sdfampere, sdfmilan, sdfrome, sdftorino).

This is a node-level operation — outside the scope of this repo.

### Step 3 — Patch `proxy.lua` via ConfigMap

Create `kubernetes/overlays/dev/proxy-lua-patch.yaml` — ConfigMap containing the
full patched `proxy.lua`. Add volumeMount to OOD deployment overriding
`/opt/ood/mod_ood_proxy/lib/ood/proxy.lua`.

### Step 4 — Update `ood_portal.yml`

Add `custom_location_directives` to `kubernetes/overlays/dev/etc/ood_portal.yml`
with the SSLProxy directives and `SetEnv OOD_SECURE_UPSTREAM yes`.

Mount CA cert ConfigMap into OOD pod at `/etc/pki/tls/ood-node-ca/ca.crt`.

### Step 5 — Update `before.sh.erb`

Add cert+key generation using cluster CA (see Design above). Export
`TTYD_TLS_KEY` and `TTYD_TLS_CERT`.

### Step 6 — Update `script.sh.erb`

Add `--ssl --ssl-cert --ssl-key` flags to ttyd invocation. Add cert+key to the
`rm -f` cleanup line.

### Step 7 — Rebuild and push image

`make -C /sdf/home/y/ytl/k8s/claude-code/ build push` — ttyd's `--ssl` support
is already in 1.7.7; no Dockerfile changes needed.

### Step 8 — Verify

```bash
# On interactive node after session launch:
ps aux | grep ttyd          # must show --ssl --ssl-cert .../.ttyd-PID.crt
openssl s_client -connect ${host}:${port} -CAfile ca.crt  # must verify OK
# 2s after launch:
ls ~/ondemand/.ttyd-*.crt   # must be gone
```

---

## Implementation Checklist

- [ ] Generate cluster CA key+cert
- [ ] Distribute CA key to interactive nodes (`/etc/ood/ca/`)
- [ ] Create `proxy.lua` ConfigMap + volumeMount in OOD dev overlay
- [ ] Add `custom_location_directives` to `ood_portal.yml` (dev)
- [ ] Mount CA cert ConfigMap into OOD pod
- [ ] Update `before.sh.erb` — generate per-session cert signed by cluster CA
- [ ] Update `script.sh.erb` — add `--ssl` flags, extend cleanup `rm -f`
- [ ] Verify: `openssl s_client` verifies OK; cert files deleted within 2s
- [ ] Move proxy.lua patch + ood_portal.yml changes to `slac-ondemand` repo (future)

---

## Open Questions

1. **Who manages the cluster CA key on interactive nodes?** — Likely a Puppet/Ansible
   role. Needs coordination with the systems team. The signing key must be readable
   by the user running the batch connect session (or the `before.sh.erb` script runs
   as that user, so group-readable with the user's group is sufficient).

2. **Does `SSLProxyCheckPeerCN` check CN or SAN?** — Modern OpenSSL/Apache checks
   SAN first, falls back to CN. Including both (as in the design above) is safest.

3. **Does the patched `proxy.lua` need to handle the PUN (Unix socket) path?** — No.
   The `OOD_SECURE_UPSTREAM` env var is set only in the `/node/` LocationMatch block.
   The PUN path uses Unix domain sockets (`proxy:unix:...`) — no SSL involved there.

---

## Relationship to Other Tasks

- **#002 (ttyd credential file):** This task adds a third layer of protection on top
  of `--auth-header` and `--credential-file`. All three coexist.
- **Future:** proxy.lua patch + ood_portal.yml changes belong in `slac-ondemand` repo.
  The app-side changes (`before.sh.erb`, `script.sh.erb`) stay here.
