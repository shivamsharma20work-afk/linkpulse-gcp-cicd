#!/usr/bin/env bash
# Smoke test a deployed LinkPulse URL.
#   ./scripts/smoke_test.sh <base_url> [expected_version]
# Exits non-zero on the first failed check.
set -euo pipefail

BASE_URL="${1:?usage: smoke_test.sh <base_url> [expected_version]}"
EXPECTED_VERSION="${2:-}"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

echo "Smoke testing $BASE_URL"

# 1. Health endpoint (retry: a fresh revision can take a few seconds to warm up)
for i in {1..10}; do
  if curl -fsS "$BASE_URL/healthz" | grep -q '"ok"'; then break; fi
  [[ $i == 10 ]] && fail "/healthz never returned ok"
  sleep 3
done
echo "  ok  /healthz"

# 2. The new build is really the one serving
if [[ -n "$EXPECTED_VERSION" ]]; then
  curl -fsS "$BASE_URL/api/info" | grep -q "\"version\":\"$EXPECTED_VERSION\"" \
    || fail "/api/info is not reporting version $EXPECTED_VERSION"
  echo "  ok  /api/info version=$EXPECTED_VERSION"
fi

# 3. Create a link and follow it (exercises Firestore read + write)
CODE=$(curl -fsS -X POST "$BASE_URL/api/links" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://cloud.google.com/run"}' | sed -E 's/.*"code":"([^"]+)".*/\1/')
[[ -n "$CODE" ]] || fail "could not create a link"

STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/$CODE")
[[ "$STATUS" == "307" ]] || fail "redirect for /$CODE returned $STATUS"
echo "  ok  create + redirect (/$CODE)"

echo "Smoke test passed"
