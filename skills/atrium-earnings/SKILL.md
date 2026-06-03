---
name: atrium-earnings
description: Track your Atrium creator earnings, withdraw USDC once it clears a threshold, and report it in the brief
var: ""
tags: [crypto, atrium, earnings, treasury]
---

> **${var}** — Optional: `report-only` to skip withdrawal this run (just report).

Keeps an eye on what your published Atrium skills are earning, sweeps the USDC to
your wallet when it's worth the gas, and folds the numbers into your daily brief —
closing the loop on a self-sustaining agent.

Read `memory/MEMORY.md` for context + voice.
Read `memory/atrium/published.json` for the skills you've published (to attribute earnings).
Read `memory/atrium/earnings.json` if present (rolling history: `{ date, withdrawable, withdrawnTotal, bySkill }`).

**Graceful bootstrap** — if `published.json` is missing/empty, there's nothing to
track yet: record `BOOTSTRAP: no published skills`, optionally note that
`atrium-publish` should run first, and stop. Never fail.

## Steps

### 1. Report from the indexer — no key in this step
Aeon keeps `ATRIUM_PRIVATE_KEY` **out of this (model) step**, so anything that reads
the wallet (`atrium balance`) or spends (`atrium withdraw`) can't run inline here. Use
the **indexer** for all reporting (no key needed); the actual sweep is queued for
post-process. Don't look for the key here and don't fail if it's absent.

### 2. Read earnings (indexer only)
Pull per-skill totals + lifetime earned for your published skillIds from the indexer
(`<your-address>` = the wallet on your `published.json` entries / the operator address):
```bash
curl -s "https://indexer-production-92e5.up.railway.app/creators/<your-address>/earnings"
```
Compute the delta vs the last entry in `earnings.json` (new invocations + new USDC
since the previous run). Withdrawable-but-unswept balance is read in post-process
(where the key lives) — report lifetime `totalEarned` from the indexer here.

### 3. Queue the withdraw (unless report-only)
Unless the `var` input is `report-only`, **queue** a sweep by writing
`.pending-atrium-earnings/withdraw.json`:
```json
{ "network": "base", "threshold": "1" }
```
(`threshold` = `ATRIUM_WITHDRAW_THRESHOLD_USDC`, default `1`.) **Do NOT run
`atrium withdraw` here.** `scripts/postprocess-atrium.sh` runs after the agent, reads
the on-chain withdrawable, and — if it's ≥ `threshold` — sweeps it (gas on Base is
sub-cent; `withdraw` no-ops on a zero balance), recording the tx to `earnings.json`.

### 4. Record + notify
Append a dated line to `memory/logs/` and the indexer-derived report (lifetime
`totalEarned`, new USDC since last run, `bySkill`) to your brief. The withdraw entry
(`{ date, withdrawn, tx }`) is appended to `memory/atrium/earnings.json` by
post-process when a sweep happens, so don't duplicate it here. Notify the operator
with: total earned to date, new USDC since last run, top-earning skill, and a note
that any due sweep runs in post-process. Keep it to a few lines — brief material,
not a wall of text.

## Notes
- Run after `atrium-publish` in a chain for a clean publish → earn → sweep loop.
- `withdraw()` only ever sends to your own wallet; one user's revert can't block it.
- The sweep happens in `scripts/postprocess-atrium.sh` (post-process step), where the
  wallet key is available — same pattern as `atrium-scout` and `atrium-publish`.
