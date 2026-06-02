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

### 1. Ensure the CLI + wallet
`command -v atrium` or install the pinned, published CLI from npm: `npm i -g @atrium-hermes/cli@0.1.0`.
Confirm `~/.atrium/.env` has `ATRIUM_PRIVATE_KEY` (secret), `ATRIUM_NETWORK=base`,
`ATRIUM_REGISTRY_MAINNET=0xA713c88927523279B874640003Ed697e509732a7`. If the key is
missing, record `BOOTSTRAP: ATRIUM_PRIVATE_KEY missing`, notify, and stop.

### 2. Read earnings
```bash
atrium balance        # shows withdrawable USDC for your wallet
```
Also pull per-skill totals for your published skillIds from the indexer:
```bash
curl -s "https://indexer-production-92e5.up.railway.app/creators/<your-address>/earnings"
```
Compute the delta vs the last entry in `earnings.json` (new invocations + new USDC
since the previous run).

### 3. Withdraw (unless report-only)
Let `T = ATRIUM_WITHDRAW_THRESHOLD_USDC` (default `1`). If withdrawable ≥ `T` and
`${var}` ≠ `report-only`:
```bash
atrium withdraw --network base
```
Capture the tx hash. Gas on Base is sub-cent, so a low threshold is fine. On revert
(`NothingToWithdraw`), skip silently.

### 4. Record + notify
Append today's `{ date, withdrawable, withdrawnTotal, bySkill }` to
`memory/atrium/earnings.json` and a dated line to `memory/logs/`. Notify the
operator with: total earned to date, new USDC since last run, top-earning skill,
and any withdrawal tx. Keep it to a few lines — this is brief material, not a wall
of text.

## Notes
- Run after `atrium-publish` in a chain for a clean publish → earn → sweep loop.
- `withdraw()` only ever sends to your own wallet; one user's revert can't block it.
