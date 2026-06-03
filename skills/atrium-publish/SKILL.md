---
name: atrium-publish
description: Publish the skills your agent created or evolved to Atrium — DID-signed, pinned to IPFS, priced per call in USDC — so they earn while you sleep
var: ""
tags: [crypto, atrium, skills, monetization]
---

> **${var}** — Optional: a single skill slug or queue path to publish this run. If empty, processes the whole publish queue.

Publishes designated local skills to **Atrium** (onchain skill marketplace, Base
mainnet) so they gain provenance + a per-call USDC price. The operator opts skills
in; this never publishes anything not explicitly queued.

Read `memory/MEMORY.md` for goals + voice.
Read `soul/SOUL.md` (if present) for identity (used in the published skill's framing).
Read `memory/atrium/publish-queue.md` — the opt-in list of skills to publish (one per line: `<skill-slug-or-path> [price_usdc]`).
Read `memory/atrium/published.json` — already-published skills (`{ slug: { skillId, cid, tx, price, at } }`) to avoid duplicates.
Read the last 7 days of `memory/logs/` for any skills the self-improve loop flagged as stable/high-quality (candidates to suggest queueing).

**Graceful bootstrap** — any of the above may be missing on a cold start. For each
missing/empty source, record `BOOTSTRAP: <resource> not yet populated` and continue.
Never fail the run.

## Steps

### 1. Detect mode
- **ATRIUM_PUBLISH_NO_QUEUE** — if `memory/atrium/publish-queue.md` is missing or empty AND no `var` input was given. Do not publish. Instead, scan recent logs + `skills/*/SKILL.md` for stable, reusable skills and propose 3–5 good publish candidates (slug + a one-line why + a suggested price), tell the operator how to queue them (append to `memory/atrium/publish-queue.md`), and stop.
- **ATRIUM_PUBLISH_OK** — otherwise.

### 2. Prepare only — do NOT spend in this step
Aeon keeps the wallet key (`ATRIUM_PRIVATE_KEY`) and `PINATA_JWT` **out of this
(model) step** by design, so `atrium publish` — which pins to IPFS *and* registers
on-chain — can never run inline here. This step **stages + queues**; the companion
`scripts/postprocess-atrium.sh` (which Aeon runs after the agent, with full env) does
the actual publish. Do not look for the secrets here and do not fail if they're
absent — just prepare the skill files and queue them.

### 3. Build the publish set
For each queue line (or the `var` input), resolve the target skill folder. Skip any slug
already in `published.json` (entry with a non-empty `skillId`) whose source is unchanged
(compare a content hash of its `SKILL.md`). For each remaining target, produce a valid
Atrium `skill.md`:
- frontmatter: `name`, `version` (bump if re-publishing an evolved version),
  `author_did: ''` (leave blank — `atrium publish` fills it from the wallet identity in
  post-process; never invent a DID), `description` (1–3 sentences),
  `tags`, `categories`, `language: en`, `runtime: prompt-only`,
  `price_per_call_usdc` (queue value, or `ATRIUM_DEFAULT_PRICE_USDC`, else `'0.005'`; must be > 0 and ≤ 50),
  `parent_skills: []` (or the prior version's skillId with a royalty if this is an evolution — see step 5),
  `created_at`, `derivation_method: hermes-loop`.
- body: the skill's actual instructions/prompt, cleaned for a third party (no secrets,
  no operator-specific paths). Never include "imported/scraped from" lines.

### 4. Stage + queue (do NOT publish here)
For each prepared skill, write its `skill.md` into a staging dir and **queue** it for
post-process — do **not** run `atrium publish` (no key/JWT in this step):
- write the manifest to `.pending-atrium-publish/<slug>/skill.md`
- write a request `.pending-atrium-publish/<slug>.json`:
  ```json
  { "slug": "<slug>", "path": ".pending-atrium-publish/<slug>", "price": "0.005", "network": "base" }
  ```
`scripts/postprocess-atrium.sh` then runs `atrium publish <path> --network <network>`
with the key present, captures `Skill ID` / `IPFS CID` / `Tx`, and records each result
to `memory/atrium/published.json` (skipping reverts like `ZeroPrice` / `SkillExists`).
Queue every opted-in skill; one publish per request, the script processes the batch.

### 5. Royalty lineage (evolutions)
If this is a newer version of a skill already in `published.json`, declare the prior
version as a parent (`parent_skills: [{ skill_id, royalty_bps }]`, e.g. 1000 = 10%)
so the lineage of an evolving skill is preserved and the prior version earns. Keep
combined parent royalties ≤ 50%.

### 6. Record + notify
The on-chain write + `published.json` append happen in post-process (where the key
is). In this step, append a dated line to `memory/logs/` listing what was **queued**
(slugs + prices), and notify the operator: how many skills were staged for publish and
that the post-process step will register them this run. If nothing was queued (all
duplicates), say so briefly.

## Notes
- This is the "earn from what you learn" loop: pair it with Aeon's self-improve so
  every stable, evolved skill becomes a provenance-signed, USDC-earning Atrium skill.
- Registry: `0xA713c88927523279B874640003Ed697e509732a7` (Base mainnet, verified).
  Docs: https://atriumhermes.tech/docs
