#!/usr/bin/env bash
set -euo pipefail

# Contract fixtures only: never publish these as playback qualification evidence.
REPORT_SELECTION_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hls-report-selection.XXXXXX")
trap 'rm -f "$REPORT_SELECTION_ROOT"/*.json; rmdir "$REPORT_SELECTION_ROOT"' EXIT
REPORT_SELECTOR="${REPORT_SELECTOR:-Scripts/select-qualification-report.sh}"
vertical="$REPORT_SELECTION_ROOT/z vertical.json"
audiovisual="$REPORT_SELECTION_ROOT/a audiovisual.json"
changed="$REPORT_SELECTION_ROOT/changed.json"
jq -nc '{schemaVersion:1,qualificationKind:"vertical_paging_ui",passed:true}' > "$vertical"
jq -nc --slurpfile vertical "$vertical" \
  '{schemaVersion:1,qualificationKind:"real_audiovisual_feed_ui",passed:true,vertical:$vertical[0]}' > "$audiovisual"

select_report() { bash "$REPORT_SELECTOR" vertical_paging_ui "$@"; }
expect_selected() {
  local expected="$1" actual
  shift
  actual=$(select_report "$@")
  if [ "$actual" != "$expected" ]; then
    echo "Selected the wrong root report: $actual (expected $expected)" >&2
    exit 1
  fi
}
expect_rejected() {
  if select_report "$@" >/dev/null 2>&1; then
    echo "Accepted missing, ambiguous, or invalid report selection" >&2
    exit 1
  fi
}

# A nested matching kind and filename ordering must not pick the larger envelope.
expect_selected "$vertical" "$audiovisual" "$vertical"
expect_selected "$vertical" "$vertical" "$audiovisual"
expect_rejected "$audiovisual"
expect_rejected
jq '.' "$vertical" > "$changed"
expect_rejected "$vertical" "$changed"
jq '.schemaVersion = 2' "$vertical" > "$changed"
expect_rejected "$changed"
jq 'del(.schemaVersion)' "$vertical" > "$changed"
expect_rejected "$changed"
jq '.passed = "true"' "$vertical" > "$changed"
expect_rejected "$changed"
jq -nr '"{"' > "$changed"
expect_rejected "$vertical" "$changed"
jq -nc '[]' > "$changed"
expect_selected "$vertical" "$changed" "$vertical"
jq -c '., .' "$vertical" > "$changed"
expect_rejected "$changed"

# Selection must not hide a failed report by choosing only passing reports.
jq '.passed = false' "$vertical" > "$changed"
expect_selected "$changed" "$audiovisual" "$changed"
if jq -e '.passed == true' "$changed" >/dev/null; then
  echo "The downstream pass gate accepted a failing report" >&2
  exit 1
fi
echo "Qualification report selection: 12 root-kind, ordering, ambiguity, and validation cases passed."
