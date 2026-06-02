#!/usr/bin/env bash
# Post-process Atrium rental requests queued by the atrium-scout skill.
# Aeon keeps ATRIUM_PRIVATE_KEY out of the Claude step, so scout queues its pick to
# .pending-atrium/<slug>.json and THIS script (run after Claude, with full env) does
# the on-chain `atrium invoke`. No key -> no-op. Honours auto_invoke + max_price. 1/run.
set -euo pipefail
PENDING_DIR=".pending-atrium"; RENTED_DIR="memory/atrium/rented"; CONFIG="memory/atrium/scout-config.md"
[ -d "$PENDING_DIR" ] && ls -A "$PENDING_DIR"/*.json >/dev/null 2>&1 || { echo "atrium-postprocess: no pending requests"; exit 0; }
[ -n "${ATRIUM_PRIVATE_KEY:-}" ] || { echo "atrium-postprocess: ATRIUM_PRIVATE_KEY not set, skipping (report-only)"; exit 0; }
AUTO_INVOKE="false"; MAX_PRICE="0"
if [ -f "$CONFIG" ]; then
  AUTO_INVOKE=$(grep -E '^auto_invoke:' "$CONFIG" | head -1 | sed -E 's/^auto_invoke:[[:space:]]*//; s/[[:space:]]*#.*//' || echo false)
  MAX_PRICE=$(grep -E '^max_price_usdc:' "$CONFIG" | head -1 | sed -E 's/^max_price_usdc:[[:space:]]*//; s/[[:space:]]*#.*//' || echo 0)
fi
[ "$AUTO_INVOKE" = "true" ] || { echo "atrium-postprocess: auto_invoke is '$AUTO_INVOKE', not renting"; exit 0; }
command -v atrium >/dev/null 2>&1 || { echo "atrium-postprocess: installing atrium CLI..."; npm install -g @atrium-hermes/cli >/dev/null 2>&1 || { echo "CLI install failed"; exit 0; }; }
mkdir -p "$RENTED_DIR"
for req in "$PENDING_DIR"/*.json; do
  [ -f "$req" ] || continue
  SKILL_ID=$(jq -r '.skillId // empty' "$req"); SLUG=$(jq -r '.slug // empty' "$req")
  PRICE=$(jq -r '.price // "0"' "$req"); NETWORK=$(jq -r '.network // "base"' "$req")
  [ -n "$SKILL_ID" ] && [ -n "$SLUG" ] || { echo "atrium-postprocess: bad request, skipping"; continue; }
  [ -f "$RENTED_DIR/$SLUG.md" ] && { echo "atrium-postprocess: $SLUG already rented"; rm -f "$req"; continue; }
  awk -v p="$PRICE" -v c="$MAX_PRICE" 'BEGIN{exit !(p+0 > c+0)}' && { echo "atrium-postprocess: $SLUG price $PRICE > cap $MAX_PRICE, skipping"; continue; }
  echo "atrium-postprocess: invoking $SLUG ($SKILL_ID) at \$$PRICE on $NETWORK..."
  atrium balance --network "$NETWORK" 2>/dev/null || echo "atrium-postprocess: balance query unavailable, proceeding (invoke enforces funds on-chain)"
  OUT=$(atrium invoke "$SKILL_ID" --network "$NETWORK" 2>&1) || { echo "atrium-postprocess: invoke failed for $SLUG:"; echo "$OUT"; continue; }
  echo "$OUT"; TX=$(echo "$OUT" | grep -oE '0x[a-fA-F0-9]{64}' | head -1 || echo "")
  BODY=$(atrium fetch "$SKILL_ID" --network "$NETWORK" 2>/dev/null || echo "")
  { echo "# $SLUG (rented from Atrium)"; echo; echo "- skillId: \`$SKILL_ID\`"; echo "- price: \$$PRICE USDC"; echo "- tx: ${TX:-see run logs}"; echo; echo "---"; echo; echo "$BODY"; } > "$RENTED_DIR/$SLUG.md"
  echo "atrium-postprocess: saved body to $RENTED_DIR/$SLUG.md"; rm -f "$req"; break
done
echo "atrium-postprocess: done"
