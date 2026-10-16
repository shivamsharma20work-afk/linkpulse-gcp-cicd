#!/usr/bin/env bash
# Canary release to Cloud Run with automatic rollback.
#
#   1. Remember which revision is serving prod right now (the rollback target)
#   2. Deploy the new image with NO traffic, tagged "canary"
#   3. Smoke test the canary through its private tag URL
#   4. Send CANARY_PERCENT of real traffic to it and watch /healthz for CANARY_SECONDS
#   5. Healthy -> promote to 100%.  Any failure -> 100% back to the old revision.
#
# Env: SERVICE REGION IMAGE VERSION [CANARY_PERCENT=10] [CANARY_SECONDS=120]
set -euo pipefail

: "${SERVICE:?}" "${REGION:?}" "${IMAGE:?}" "${VERSION:?}"
CANARY_PERCENT="${CANARY_PERCENT:-10}"
CANARY_SECONDS="${CANARY_SECONDS:-120}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

run() { gcloud run services "$@" --region="$REGION" --quiet; }

STABLE_REVISION=$(run describe "$SERVICE" \
  --format='value(status.traffic[0].revisionName)')
echo "Stable revision: ${STABLE_REVISION:-<none>}"

rollback() {
  echo "!! Canary failed -> rolling back to $STABLE_REVISION"
  if [[ -n "$STABLE_REVISION" ]]; then
    run update-traffic "$SERVICE" --to-revisions="$STABLE_REVISION=100"
  fi
  exit 1
}

# First ever deploy (still on Terraform's placeholder image): nothing to canary against
CURRENT_IMAGE=$(run describe "$SERVICE" --format='value(spec.template.spec.containers[0].image)')
if [[ -z "$STABLE_REVISION" || "$CURRENT_IMAGE" == *cloudrun/container/hello* ]]; then
  echo "No real prod revision yet -> direct deploy"
  gcloud run deploy "$SERVICE" --image="$IMAGE" --region="$REGION" \
    --update-env-vars="APP_VERSION=$VERSION" --labels="commit-sha=$VERSION" --quiet
  URL=$(run describe "$SERVICE" --format='value(status.url)')
  "$SCRIPT_DIR/smoke_test.sh" "$URL" "$VERSION"
  exit 0
fi

# 2. Deploy without traffic
gcloud run deploy "$SERVICE" --image="$IMAGE" --region="$REGION" \
  --update-env-vars="APP_VERSION=$VERSION" --labels="commit-sha=$VERSION" \
  --no-traffic --tag=canary --quiet
CANARY_REVISION=$(run describe "$SERVICE" --format='value(status.latestCreatedRevisionName)')
CANARY_URL=$(run describe "$SERVICE" \
  --format='value(status.traffic.filter(tag=canary).url)' | tr ';' '\n' | head -1)
echo "Canary revision: $CANARY_REVISION ($CANARY_URL)"

# 3. Smoke test the canary before any user sees it
"$SCRIPT_DIR/smoke_test.sh" "$CANARY_URL" "$VERSION" || rollback

# 4. Real traffic split
run update-traffic "$SERVICE" \
  --to-revisions="$CANARY_REVISION=$CANARY_PERCENT,$STABLE_REVISION=$((100 - CANARY_PERCENT))"
echo "Canary at ${CANARY_PERCENT}% for ${CANARY_SECONDS}s"

failures=0
end=$((SECONDS + CANARY_SECONDS))
while (( SECONDS < end )); do
  if ! curl -fsS --max-time 5 "$CANARY_URL/healthz" > /dev/null; then
    failures=$((failures + 1))
    echo "  health check failed ($failures)"
    (( failures >= 3 )) && rollback
  fi
  sleep 10
done

# 5. Promote
run update-traffic "$SERVICE" --to-latest
echo "Promoted $CANARY_REVISION to 100%"
