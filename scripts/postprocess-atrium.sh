#!/usr/bin/env bash
# Post-process Atrium rental requests queued by the atrium-scout skill.
#
# WHY THIS EXISTS: Aeon keeps secrets (ATRIUM_PRIVATE_KEY) OUT of the Claude/model
# step by design, so a skill can't spend inline. Instead atrium-scout writes its
# top pick to .pending-atrium/<slug>.json, and THIS script — which Aeon runs after
# Claude (via the post-process step, with full env) — performs the on-chain
# `atrium invoke` (USDC spend) and stashes the body.
#
# SETUP (one-time, in your Aeon repo):
#   1. Copy this file to scripts/postprocess-atrium.sh (Aeon auto-runs scripts/postprocess-*.sh).
#   2. Add to the post-process step env in .github/workflows/aeon.yml:
#        ATRIUM_PRIVATE_KEY: ${{ secrets.ATRIUM_PRIVATE_KEY }}
#      (keep it OUT of the Claude step — model never sees the key.)
#
# Safety: no key -> no-op (report-only). Honours auto_invoke + max_price_usdc from
# memory/atrium/scout-config.md. Skips already-rented skills. One rental per run.
set -euo pipefail

PENDING_DIR=".pending-atrium"
RENTED_DIR="memory/atrium/rented"
CONFIG="memory/atrium/scout-config.md"

# No key -> report-only no-op for every block below (invoke/publish/withdraw/attest all
# need the wallet). This is the ONLY global early-exit; per-queue guards follow so an
# empty rental queue never blocks publish/withdraw/attest (they're independent skills).
[ -n "${ATRIUM_PRIVATE_KEY:-}" ] || { echo "atrium-postprocess: ATRIUM_PRIVATE_KEY not set, skipping (report-only)"; exit 0; }

# Ensure the CLI once — all four queue blocks use it.
command -v atrium >/dev/null 2>&1 || { echo "atrium-postprocess: installing atrium CLI..."; npm install -g @atrium-hermes/cli >/dev/null 2>&1 || { echo "atrium-postprocess: CLI install failed"; exit 0; }; }

# ── Rentals queued by atrium-scout (.pending-atrium/<slug>.json) ──
if [ -d "$PENDING_DIR" ] && ls -A "$PENDING_DIR"/*.json >/dev/null 2>&1; then
  AUTO_INVOKE="false"; MAX_PRICE="0"
  if [ -f "$CONFIG" ]; then
    AUTO_INVOKE=$(grep -E '^auto_invoke:' "$CONFIG" | head -1 | sed -E 's/^auto_invoke:[[:space:]]*//; s/[[:space:]]*#.*//' || echo false)
    MAX_PRICE=$(grep -E '^max_price_usdc:' "$CONFIG" | head -1 | sed -E 's/^max_price_usdc:[[:space:]]*//; s/[[:space:]]*#.*//' || echo 0)
  fi
  if [ "$AUTO_INVOKE" != "true" ]; then
    echo "atrium-postprocess: auto_invoke is '$AUTO_INVOKE', not renting"
  else
    mkdir -p "$RENTED_DIR"
    for req in "$PENDING_DIR"/*.json; do
      [ -f "$req" ] || continue
      SKILL_ID=$(jq -r '.skillId // empty' "$req"); SLUG=$(jq -r '.slug // empty' "$req")
      PRICE=$(jq -r '.price // "0"' "$req"); NETWORK=$(jq -r '.network // "base"' "$req")
      [ -n "$SKILL_ID" ] && [ -n "$SLUG" ] || { echo "atrium-postprocess: bad request $(basename "$req"), skipping"; continue; }
      [ -f "$RENTED_DIR/$SLUG.md" ] && { echo "atrium-postprocess: $SLUG already rented"; rm -f "$req"; continue; }
      awk -v p="$PRICE" -v c="$MAX_PRICE" 'BEGIN{exit !(p+0 > c+0)}' && { echo "atrium-postprocess: $SLUG price $PRICE > cap $MAX_PRICE, skipping"; continue; }

      echo "atrium-postprocess: invoking $SLUG ($SKILL_ID) at \$$PRICE on $NETWORK..."
      # Balance/allowance are enforced on-chain by invoke (it reverts if short), so we
      # don't pre-gate on `atrium balance` (its non-zero exit must never block a funded wallet).
      atrium balance --network "$NETWORK" 2>/dev/null || echo "atrium-postprocess: balance query unavailable, proceeding (invoke enforces funds on-chain)"
      OUT=$(atrium invoke "$SKILL_ID" --network "$NETWORK" 2>&1) || { echo "atrium-postprocess: invoke failed for $SLUG:"; echo "$OUT"; continue; }
      echo "$OUT"
      TX=$(echo "$OUT" | grep -oE '0x[a-fA-F0-9]{64}' | head -1 || echo "")
      BODY=$(atrium fetch "$SKILL_ID" --network "$NETWORK" 2>/dev/null || echo "")
      { echo "# $SLUG (rented from Atrium)"; echo; echo "- skillId: \`$SKILL_ID\`"; echo "- price: \$$PRICE USDC"; echo "- tx: ${TX:-see run logs}"; echo; echo "---"; echo; echo "$BODY"; } > "$RENTED_DIR/$SLUG.md"
      echo "atrium-postprocess: saved body to $RENTED_DIR/$SLUG.md"
      rm -f "$req"
      break   # one rental per run
    done
  fi
fi

# ── Reputation attestations queued by atrium-attest (.pending-atrium-attest/*.json) ──
# These are tx-only (no USDC spend) but need ETH for gas; safe to run unconditionally.
ATTEST_DIR=".pending-atrium-attest"; ATTESTED="memory/atrium/attested.json"
if [ -d "$ATTEST_DIR" ] && ls -A "$ATTEST_DIR"/*.json >/dev/null 2>&1; then
  [ -f "$ATTESTED" ] && jq empty "$ATTESTED" 2>/dev/null || echo '{}' > "$ATTESTED"
  for req in "$ATTEST_DIR"/*.json; do
    [ -f "$req" ] || continue
    SKILL_ID=$(jq -r '.skillId // empty' "$req"); RATE=$(jq -r '.successRate // empty' "$req")
    SAMPLES=$(jq -r '.sampleCount // empty' "$req"); ROOT=$(jq -r '.merkleRoot // empty' "$req")
    NETWORK=$(jq -r '.network // "base"' "$req")
    [ -n "$SKILL_ID" ] && [ -n "$RATE" ] && [ -n "$SAMPLES" ] && [ -n "$ROOT" ] || { echo "atrium-postprocess: bad attest request, skipping"; rm -f "$req"; continue; }
    # Skip if already attested at the same rate+samples (nothing new to say).
    PREV=$(jq -r --arg id "$SKILL_ID" '.[$id] | "\(.successRate)/\(.sampleCount)"' "$ATTESTED" 2>/dev/null || echo "/")
    [ "$PREV" = "$RATE/$SAMPLES" ] && { echo "atrium-postprocess: $SKILL_ID already attested at $RATE/$SAMPLES"; rm -f "$req"; continue; }
    echo "atrium-postprocess: attesting $SKILL_ID — ${RATE}bps over $SAMPLES samples..."
    OUT=$(atrium attest "$SKILL_ID" --merkle-root "$ROOT" --success-rate "$RATE" --sample-count "$SAMPLES" --network "$NETWORK" 2>&1) || { echo "atrium-postprocess: attest failed:"; echo "$OUT"; continue; }
    echo "$OUT"
    jq --arg id "$SKILL_ID" --argjson r "$RATE" --argjson s "$SAMPLES" --arg at "$(date -u +%FT%TZ)" \
      '.[$id] = {successRate:$r, sampleCount:$s, at:$at}' "$ATTESTED" > "$ATTESTED.tmp" && mv "$ATTESTED.tmp" "$ATTESTED"
    rm -f "$req"
  done
fi

# ── Publish requests queued by atrium-publish (.pending-atrium-publish/<slug>.json) ──
# Each request points at a staged skill dir (containing skill.md) the Claude step
# prepared. Publishing registers the skill on-chain (gas) AND pins to IPFS, so it needs
# both ATRIUM_PRIVATE_KEY and PINATA_JWT — neither is in the Claude step. `atrium publish`
# overwrites author_did to the local identity, so the staged manifest needs no DID.
PUB_DIR=".pending-atrium-publish"; PUBLISHED="memory/atrium/published.json"
if [ -d "$PUB_DIR" ] && ls -A "$PUB_DIR"/*.json >/dev/null 2>&1; then
  [ -f "$PUBLISHED" ] && jq empty "$PUBLISHED" 2>/dev/null || echo '{}' > "$PUBLISHED"
  for req in "$PUB_DIR"/*.json; do
    [ -f "$req" ] || continue
    SLUG=$(jq -r '.slug // empty' "$req"); SKPATH=$(jq -r '.path // empty' "$req")
    PRICE=$(jq -r '.price // "0.005"' "$req"); NETWORK=$(jq -r '.network // "base"' "$req")
    [ -n "$SLUG" ] && [ -n "$SKPATH" ] && [ -d "$SKPATH" ] || { echo "atrium-postprocess: bad publish request $(basename "$req"), skipping"; rm -f "$req"; continue; }
    jq -e --arg s "$SLUG" '.[$s].skillId // empty | select(length>0)' "$PUBLISHED" >/dev/null 2>&1 && { echo "atrium-postprocess: $SLUG already published"; rm -f "$req"; continue; }
    echo "atrium-postprocess: publishing $SLUG from $SKPATH at \$$PRICE on $NETWORK..."
    OUT=$(atrium publish "$SKPATH" --network "$NETWORK" 2>&1) || { echo "atrium-postprocess: publish failed for $SLUG:"; echo "$OUT"; continue; }
    echo "$OUT"
    # Output labels (atrium publish): "Skill ID: 0x..", "IPFS CID: baf..", "Tx: 0x.."
    SKILL_ID=$(echo "$OUT" | grep -i 'Skill ID' | grep -oE '0x[a-fA-F0-9]{64}' | head -1 || echo "")
    CID=$(echo "$OUT" | grep -i 'IPFS CID' | grep -oE 'baf[a-z0-9]+' | head -1 || echo "")
    TX=$(echo "$OUT" | grep -iE '^[[:space:]]*Tx:' | grep -oE '0x[a-fA-F0-9]{64}' | head -1 || echo "")
    [ -n "$SKILL_ID" ] || { echo "atrium-postprocess: $SLUG published but skillId not parsed — leaving request for retry"; continue; }
    jq --arg s "$SLUG" --arg id "$SKILL_ID" --arg cid "$CID" --arg tx "$TX" --arg p "$PRICE" --arg at "$(date -u +%FT%TZ)" \
      '.[$s] = {skillId:$id, cid:$cid, tx:$tx, price:$p, at:$at}' "$PUBLISHED" > "$PUBLISHED.tmp" && mv "$PUBLISHED.tmp" "$PUBLISHED"
    echo "atrium-postprocess: recorded $SLUG -> $SKILL_ID"
    rm -f "$req"
  done
fi

# ── Withdraw queued by atrium-earnings (.pending-atrium-earnings/withdraw.json) ──
# Sweeping creator USDC is a tx (needs the key). `atrium withdraw` self-gates: it no-ops
# on a zero balance. We additionally honour a USDC threshold (don't bother below it).
WD_REQ=".pending-atrium-earnings/withdraw.json"; EARNINGS="memory/atrium/earnings.json"
if [ -f "$WD_REQ" ]; then
  NETWORK=$(jq -r '.network // "base"' "$WD_REQ"); THRESH=$(jq -r '.threshold // "1"' "$WD_REQ")
  OWED=$(atrium balance --network "$NETWORK" 2>/dev/null | grep -i 'Withdrawable' | grep -oE '[0-9]+\.?[0-9]*' | head -1 || echo "")
  if [ -z "$OWED" ]; then
    echo "atrium-postprocess: could not read withdrawable (no key / RPC?), skipping withdraw"
  elif awk -v o="$OWED" -v t="$THRESH" 'BEGIN{exit !(o+0 >= t+0)}'; then
    echo "atrium-postprocess: withdrawable \$$OWED >= threshold \$$THRESH on $NETWORK, withdrawing..."
    OUT=$(atrium withdraw --network "$NETWORK" 2>&1) || { echo "atrium-postprocess: withdraw failed:"; echo "$OUT"; OUT=""; }
    echo "$OUT"
    TX=$(echo "$OUT" | grep -i 'Withdrew' | grep -oE '0x[a-fA-F0-9]{64}' | head -1 || echo "")
    if [ -n "$TX" ]; then
      [ -f "$EARNINGS" ] && jq -e 'type=="array"' "$EARNINGS" >/dev/null 2>&1 || echo '[]' > "$EARNINGS"
      jq --arg w "$OWED" --arg tx "$TX" --arg at "$(date -u +%FT%TZ)" \
        '. += [{date:$at, withdrawn:$w, tx:$tx}]' "$EARNINGS" > "$EARNINGS.tmp" && mv "$EARNINGS.tmp" "$EARNINGS"
      echo "atrium-postprocess: swept \$$OWED -> $TX"
      rm -f "$WD_REQ"
    fi
  else
    echo "atrium-postprocess: withdrawable \$$OWED < threshold \$$THRESH, leaving for next run"
    rm -f "$WD_REQ"
  fi
fi
echo "atrium-postprocess: done"
