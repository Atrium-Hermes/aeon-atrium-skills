---
name: atrium-attest
description: Turn this agent's real run-quality scores into onchain Atrium benchmark attestations for the skills it has published — a reputation signal the marketplace can rank by
var: ""
tags: [crypto, atrium, reputation, attestation]
---

> **`var`** — Optional: a single skill slug to attest. If empty, attests every eligible published skill.

Aeon already scores every skill run 1–5. This skill carries that signal **onchain**:
for each skill this agent has **published to Atrium** and actually **runs**, it posts
a benchmark attestation reflecting the skill's real, observed success rate — so
`atrium-scout` (and any consumer) can rank by *proven* quality, not just price or
invocation count.

It does NOT pay or attest inline (Aeon keeps the wallet key out of the model step):
it **queues** the attestation; `scripts/postprocess-atrium.sh` posts it after the run.

Read `memory/atrium/published.json` — the slug → `{ skillId, cid, ... }` map of skills
this agent published (written by `atrium-publish`). If missing/empty, record
`BOOTSTRAP: nothing published yet` and stop.

Read `memory/atrium/attested.json` if present — `{ skillId: { successRate, sampleCount, at } }`
already attested, to avoid re-posting an unchanged attestation.

## Steps

### 1. Build the attestation set
For each published slug, read `memory/skill-health/<slug>.json`
(`avg_score` is a rolling 1–5 mean; `history` is the per-run score list). Keep only
skills with **at least 3 runs** (`history` length ≥ 3) — fewer is too noisy to attest.
If a skill maps to a `skillId` in `published.json`, it is eligible.

### 2. Compute the signal
For each eligible skill:
- `successRate` (bps, 0–10000) = `round(avg_score / 5 * 10000)`.
- `sampleCount` = number of runs in `history`.
- `merkleRoot` = a deterministic reference hash for this usage attestation, e.g.
  `keccak256("aeon-runs:" + skillId + ":" + sampleCount + ":" + successRate)`. This is
  a **usage** attestation (real run-quality), not a formal benchmark suite — be honest
  about that in the report.
- Skip if `attested.json` already has this skillId at the same `successRate` + `sampleCount`
  (nothing new to say).

### 3. Queue the attestations (do NOT post inline)
Write one file per skill to `.pending-atrium-attest/<slug>.json`:
```json
{ "skillId": "0x...", "slug": "<slug>", "successRate": 8400, "sampleCount": 12, "merkleRoot": "0x...", "network": "base" }
```
`scripts/postprocess-atrium.sh` performs the on-chain `atrium attest` afterwards
(where `ATRIUM_PRIVATE_KEY` is available), and records the result in
`memory/atrium/attested.json`.

### 4. Notify
Report the skills queued for attestation (slug → success rate → samples), and note
that the on-chain post happens in post-process. If nothing was eligible, say so in one line.

## Notes
- Pairs with `atrium-publish` (publish what you build) and `atrium-scout` (rank by
  attested quality). The honest signal here is *this agent's* run experience; on a
  permissionless registry the latest attestation wins, so attest only your own published
  skills from real runs.
- Marketplace + docs: https://atriumhermes.tech
