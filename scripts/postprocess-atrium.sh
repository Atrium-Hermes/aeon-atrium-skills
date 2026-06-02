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

[ -d "$PENDING_DIR" ] && ls -A "$PENDING_DIR"/*.json >/dev/null 2>&1 || { echo "atrium-postprocess: no pending requests"; exit 0; }
[ -n "${ATRIUM_PRIVATE_KEY:-}" ] || { echo "atrium-postprocess: ATRIUM_PRIVATE_KEY not set, skipping (report-only)"; exit 0; }

AUTO_INVOKE="false"; MAX_PRICE="0"
if [ -f "$CONFIG" ]; then
  AUTO_INVOKE=$(grep -E '^auto_invoke:' "$CONFIG" | head -1 | sed -E 's/^auto_invoke:[[:space:]]*//; s/[[:space:]]*#.*//' || echo false)
  MAX_PRICE=$(grep -E '^max_price_usdc:' "$CONFIG" | head -1 | sed -E 's/^max_price_usdc:[[:space:]]*//; s/[[:space:]]*#.*//' || echo 0)
fi
[ "$AUTO_INVOKE" = "true" ] || { echo "atrium-postprocess: auto_invoke is '$AUTO_INVOKE', not renting"; exit 0; }

command -v atrium >/dev/null 2>&1 || { echo "atrium-postprocess: installing atrium CLI..."; npm install -g @atrium-hermes/cli >/dev/null 2>&1 || { echo "atrium-postprocess: CLI install failed"; exit 0; }; }

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
echo "atrium-postprocess: done"
