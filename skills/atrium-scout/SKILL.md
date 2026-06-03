---
name: atrium-scout
description: Scan the Atrium marketplace for skills that match your agent's open loops and goals, then recommend (or invoke) the ones worth renting
var: ""
tags: [crypto, atrium, discovery, research]
---

> **${var}** — Optional focus (e.g. `pdf`, `trading`, `code-review`). If empty, scouts against all of your agent's current open loops.

Finds capabilities your agent *lacks* by searching **Atrium** (onchain skill
marketplace, Base) and surfacing skills that would unblock real work — instead of
building everything from scratch. Read-only by default; only invokes (pays) when
the operator explicitly enables it.

Read `memory/MEMORY.md` for goals + "Next Priorities".
Read the last 7 days of `memory/logs/` for recurring needs, failures, and "todo/next:" lines.
Read `memory/topics/*.md` for active threads.
Read `memory/cron-state.json` for skills failing repeatedly (a capability gap to fill).
Read `memory/atrium/scout-config.md` if present (`auto_invoke: true|false`, `max_price_usdc`, allowed categories).

**Graceful bootstrap** — for any missing/empty source, record
`BOOTSTRAP: <resource> not yet populated` and continue. Never fail.

## Steps

### 1. Build the need list
From the sources above, extract a deduped list of concrete capability needs (e.g.
"parse PDF tables", "review a PR", "summarize a thread"). Cap at 15. If a `var`
focus was given, prioritize needs touching it. If there are zero needs, switch to
**ATRIUM_SCOUT_BROWSE** mode: just surface the marketplace's top + newest skills as
inspiration, then stop.

### 2. Search Atrium
For each need, query the public indexer (no key required):
```bash
curl -s "https://indexer-production-92e5.up.railway.app/skills?q=<need>&sort=invocations&limit=5"
```
Collect candidates: `skillId`, `name`, `pricePerCall`, `tags`, `totalInvocations`.

### 3. Rank + recommend
For the top few candidates per need, fetch the full record to read its **quality
signals**:
```bash
curl -s "https://indexer-production-92e5.up.railway.app/skills/<skillId>"
  # .stakeAttestation = { rateBps, totalStake, attestationCount }  ← STRONGEST: a stake-weighted
  #                       success rate with $ATRIUM bonded behind it, slashable if false (sybil-resistant)
  # .attestation      = { successRate, sampleCount } | null         ← weaker: an unbacked claim anyone can post
```
Rank each candidate by relevance, then by quality in this order:
1. **Stake-backed rate** — a high `stakeAttestation.rateBps` with real `totalStake` bonded
   beats everything; the more $ATRIUM staked, the more trustworthy the number (it's
   slashable). `$ATRIUM` is 18-decimal — divide `totalStake` by 1e18 for the human amount.
2. **Plain attested** `successRate` over a real `sampleCount` (a signal, but unbacked).
3. **Proven usage** (`totalInvocations`) ÷ price as the tiebreaker.
Keep the best match per need that is genuinely useful (skip weak/irrelevant hits).
Produce a short table: need → recommended skill, price, quality (staked rate / attested / usage), why.

### 4. Optionally queue a rental (only if enabled)
If `scout-config.md` has `auto_invoke: true` AND a candidate's `pricePerCall` ≤
`max_price_usdc`: **queue** the single highest-value match by writing
`.pending-atrium/<slug>.json`:
```json
{ "skillId": "0x...", "slug": "<slug>", "price": "0.1", "network": "base" }
```
**Do NOT invoke here.** Aeon keeps the wallet key out of this (model) step, so
spending inline always fails. The companion `scripts/postprocess-atrium.sh` runs
after the agent — where `ATRIUM_PRIVATE_KEY` is available — and performs the actual
on-chain `atrium invoke`, then stashes the body under `memory/atrium/rented/<slug>.md`.
Queue at most ONE rental per run. Otherwise, recommend only.

### 5. Notify
Send the operator the ranked recommendations (need → skill → price → why), plus any
auto-invoked skill and where its body was saved. If nothing relevant was found,
say so in one line rather than padding.

## Notes
- Pairs with `atrium-publish`: scout what you need, publish what you build.
- Marketplace + docs: https://atriumhermes.tech · indexer is CORS-open and read-only.
