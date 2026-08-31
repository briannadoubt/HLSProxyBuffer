#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: select-qualification-report.sh ROOT_KIND JSON_ATTACHMENT..." >&2
  exit 1
fi
report_kind="$1"
shift

# Parse root objects only. A nested report is not a second attachment, and a
# failed report must not be hidden by selecting only passing candidates.
jq -ner --arg kind "$report_kind" '
  [inputs | select(type == "object") | select(.qualificationKind == $kind)
    | {filename:input_filename, schemaVersion, passed}] as $matches
  | if ($matches | length) != 1 then
      error("Expected exactly one root report of kind " + $kind)
    elif $matches[0].schemaVersion != 1 or ($matches[0].passed | type) != "boolean" then
      error("Invalid root report envelope for " + $kind)
    else $matches[0].filename end
' -- "$@"
