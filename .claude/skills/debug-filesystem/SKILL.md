---
name: debug-filesystem
description: Diagnose OOD form dropdowns showing empty options due to /sdf/sw/ WekaFS mount failures on specific K8s nodes.
---

# debug-filesystem — OOD /sdf/sw/ Mount Failures

## Symptom

A form dropdown (e.g. "Claude Code Version") is empty in the browser even though
files exist on disk. Page source shows an empty `<select>` with no `<option>`
elements.

## Root Cause Pattern

OOD's Passenger process renders `form.yml.erb` **as the requesting user** (not
root). If the node hosting the OOD pod has a stale or permission-broken WekaFS
mount for `/sdf/sw/`, non-root users cannot read that path. `Dir.glob(...)` returns
`[]`, and the select widget renders with no options.

Key facts:
- `kubectl exec ... -- ruby -e "Dir.glob(...)"` runs as root → returns files (misleading)
- The Passenger process runs as the logged-in user → sees empty glob
- Affected nodes consistently show `/sdf/sw/` returning `Permission denied` or
  `Stale file handle` for non-root users
- Root can always see the files; the failure is user-space only

## Diagnostic Runbook

### Step 1 — Confirm it's server-side

View page source in the browser. If the `<select>` has no `<option>` elements,
the problem is server-side (not JS). If options are present but hidden, check
`form.js`.

### Step 2 — Find which pods are broken

Test the glob **as a real user** (not root) on every pod:

```bash
for pod in $(kubectl -n prod get pods -l app=ondemand -o name | sed 's|pod/||'); do
  node=$(kubectl -n prod get pod $pod -o jsonpath='{.spec.nodeName}')
  echo -n "$pod ($node): "
  kubectl -n prod exec $pod -c ondemand -- \
    bash -c 'runuser -u ytl -- ruby -e "puts Dir.glob(\"/sdf/sw/claude-code/claude-code_*.sif\").length"'
done
```

Expected: each pod prints `3` (or however many SIFs exist).
Broken pods print `0`.

> **Important:** `kubectl exec -- ruby` runs as root and will show the correct
> count even on broken nodes. Always use `runuser -u <username>` to simulate
> the Passenger context.

### Step 3 — Confirm the node-level mount failure

On a broken pod:

```bash
kubectl -n prod exec <bad-pod> -c ondemand -- \
  bash -c 'runuser -u ytl -- ruby -e "puts File.readable?(\"/sdf/sw/\")"'
# → false on broken node, true on healthy node
```

```bash
kubectl -n prod exec <bad-pod> -c ondemand -- \
  su - ytl -s /bin/bash -c 'ls /sdf/sw/ 2>&1 | head -3'
# → "Permission denied" or "Stale file handle" on broken node
```

### Step 4 — Identify all bad nodes

Check every schedulable node:

```bash
kubectl -n prod get nodes -o custom-columns='NAME:.metadata.name,SCHEDULABLE:.spec.unschedulable'
```

For each uncordoned node without an OOD pod, use a node debug pod:

```bash
kubectl -n prod debug node/<node> -it --image=busybox -- \
  sh -c 'ls /host/sdf/sw/claude-code/claude-code_*.sif 2>&1 | wc -l'
```

Note: node debug runs as root via the host PID namespace — this only confirms
the files exist, not that users can see them. Use this to rule out missing mounts,
not to confirm the fix.

## Fix

1. **Cordon all bad nodes** before deleting pods, or the replacement will land
   on another bad node immediately:

```bash
kubectl cordon sdfk8sc033 sdfk8sc021   # add all bad nodes
```

2. **Delete the pods on bad nodes:**

```bash
kubectl -n prod delete pod <pod-on-bad-node> [<pod-on-bad-node-2> ...]
```

3. **Verify the replacement pods** landed on good nodes and the glob works:

```bash
for pod in $(kubectl -n prod get pods -l app=ondemand -o name | sed 's|pod/||'); do
  node=$(kubectl -n prod get pod $pod -o jsonpath='{.spec.nodeName}')
  echo -n "$pod ($node): "
  kubectl -n prod exec $pod -c ondemand -- \
    bash -c 'runuser -u ytl -- ruby -e "puts Dir.glob(\"/sdf/sw/claude-code/claude-code_*.sif\").length"'
done
```

All pods must print the expected SIF count (currently `3`).

## Known Bad Nodes (2026-07-05)

Nodes confirmed to have broken non-root `/sdf/sw/` WekaFS mounts:

| Node | Status |
|------|--------|
| `sdfk8sc021` | Cordoned — recurrent offender |
| `sdfk8sc033` | Cordoned |
| `sdfk8sc034` | Removed from cluster |

Confirmed healthy nodes (as of 2026-07-05):
`sdfk8sc018`, `sdfk8sc022`, `sdfk8sc043`, `sdfk8sc050`, `sdfk8sc052`

## Underlying Issue

The WekaFS client on affected nodes loses its user-space permission context for
`/sdf/sw/` — possibly after a network partition, mount remount, or WekaFS client
upgrade. Root access continues to work because it bypasses permission checks.
The fix is a node-level WekaFS remount or client restart; cordoning + evicting
the OOD pod is a workaround until storage ops can remediate the node.

Report affected nodes to the storage/infrastructure team for WekaFS client
investigation on: `sdfk8sc021`, `sdfk8sc033`.

## Quick Reference

| Symptom | Check | Fix |
|---------|-------|-----|
| Empty version dropdown | `runuser -u ytl -- ruby -e "Dir.glob(...).length"` on each pod | Cordon bad node, delete pod |
| Pod keeps landing on bad node | `kubectl get nodes` — node not cordoned | `kubectl cordon <node>` before deleting pod |
| Root sees files, user doesn't | WekaFS non-root permission failure | Cordon node; report to storage ops |
| New pod lands on new bad node | Unchecked node has same issue | Re-run full pod scan, cordon, repeat |
