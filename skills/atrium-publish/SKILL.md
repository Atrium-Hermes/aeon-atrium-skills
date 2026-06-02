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
- **ATRIUM_PUBLISH_NO_QUEUE** — if `memory/atrium/publish-queue.md` is missing or empty AND no `${var}` was given. Do not publish. Instead, scan recent logs + `skills/*/SKILL.md` for stable, reusable skills and propose 3–5 good publish candidates (slug + a one-line why + a suggested price), tell the operator how to queue them (append to `memory/atrium/publish-queue.md`), and stop.
- **ATRIUM_PUBLISH_OK** — otherwise.

### 2. Ensure the Atrium CLI
Check `command -v atrium`. If missing, install the pinned, published CLI from npm:
```bash
npm i -g @atrium-hermes/cli@0.1.0
```
Confirm `~/.atrium/.env` has `ATRIUM_PRIVATE_KEY` (from the `ATRIUM_PRIVATE_KEY`
secret), `ATRIUM_NETWORK=base`, `ATRIUM_REGISTRY_MAINNET=0xA713c88927523279B874640003Ed697e509732a7`,
and `PINATA_JWT` (from the `PINATA_JWT` secret). Write any missing values. If
`ATRIUM_PRIVATE_KEY` or `PINATA_JWT` is unset, record `BOOTSTRAP: secrets missing`,
notify the operator, and stop (do not invent keys).

### 3. Build the publish set
For each queue line (or `${var}`), resolve the target skill folder. Skip any slug
already in `published.json` whose source is unchanged (compare a content hash of
its `SKILL.md`). For each remaining target, produce a valid Atrium `skill.md`:
- frontmatter: `name`, `version` (bump if re-publishing an evolved version),
  `author_did` (from `atrium init`), `description` (1–3 sentences),
  `tags`, `categories`, `language: en`, `runtime: prompt-only`,
  `price_per_call_usdc` (queue value, or `ATRIUM_DEFAULT_PRICE_USDC`, else `'0.005'`; must be > 0 and ≤ 50),
  `parent_skills: []` (or the prior version's skillId with a royalty if this is an evolution — see step 5),
  `created_at`, `derivation_method: hermes-loop`.
- body: the skill's actual instructions/prompt, cleaned for a third party (no secrets,
  no operator-specific paths). Never include "imported/scraped from" lines.

### 4. Publish
For each prepared skill:
```bash
atrium publish <path-to-skill-dir> --network base
```
Capture the `Skill ID`, `IPFS CID`, and `Tx`. On revert (`ZeroPrice`, `SkillExists`,
insufficient gas), log the reason and continue with the rest — never abort the batch.

### 5. Royalty lineage (evolutions)
If this is a newer version of a skill already in `published.json`, declare the prior
version as a parent (`parent_skills: [{ skill_id, royalty_bps }]`, e.g. 1000 = 10%)
so the lineage of an evolving skill is preserved and the prior version earns. Keep
combined parent royalties ≤ 50%.

### 6. Record + notify
Append each result to `memory/atrium/published.json`. Append a dated line to
`memory/logs/`. Notify the operator: how many skills published, their names +
skillIds + a Basescan/atriumhermes.tech link, and the prices set. If nothing was
published (all duplicates), say so briefly.

## Notes
- This is the "earn from what you learn" loop: pair it with Aeon's self-improve so
  every stable, evolved skill becomes a provenance-signed, USDC-earning Atrium skill.
- Registry: `0xA713c88927523279B874640003Ed697e509732a7` (Base mainnet, verified).
  Docs: https://atriumhermes.tech/docs
