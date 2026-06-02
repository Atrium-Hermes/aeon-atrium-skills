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
"parse PDF tables", "review a PR", "summarize a thread"). Cap at 15. If `${var}` is
set, prioritize needs touching it. If there are zero needs, switch to
**ATRIUM_SCOUT_BROWSE** mode: just surface the marketplace's top + newest skills as
inspiration, then stop.

### 2. Search Atrium
For each need, query the public indexer (no key required):
```bash
curl -s "https://indexer-production-92e5.up.railway.app/skills?q=<need>&sort=invocations&limit=5"
```
Collect candidates: `skillId`, `name`, `pricePerCall`, `tags`, `totalInvocations`.

### 3. Rank + recommend
Score each candidate by relevance to the need × proven usage (`totalInvocations`) ÷
price. Keep the best match per need that is genuinely useful (skip weak/irrelevant
hits). Produce a short table: need → recommended skill, price, why, and the
one-liner to use it.

### 4. Optionally invoke (only if enabled)
If `scout-config.md` has `auto_invoke: true` AND a candidate's `pricePerCall` ≤
`max_price_usdc` AND `ATRIUM_PRIVATE_KEY` is set: invoke the single highest-value
match to unblock an active loop —
```bash
atrium invoke <skillId> --network base    # (install via curl|bash if `atrium` is missing)
```
then fetch the body and stash it under `memory/atrium/rented/<slug>.md` for the
relevant loop. Cap at ONE auto-invoke per run. Otherwise, recommend only.

### 5. Notify
Send the operator the ranked recommendations (need → skill → price → why), plus any
auto-invoked skill and where its body was saved. If nothing relevant was found,
say so in one line rather than padding.

## Notes
- Pairs with `atrium-publish`: scout what you need, publish what you build.
- Marketplace + docs: https://atriumhermes.tech · indexer is CORS-open and read-only.
