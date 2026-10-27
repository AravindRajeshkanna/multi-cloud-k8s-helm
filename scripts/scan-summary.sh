#!/usr/bin/env bash
# Summarize a Grype vulnerability report as Markdown and decide whether it fails.
# Used by .github/workflows/supply-chain.yml.
#
#   scan-summary.sh <report.json> <image> [critical|high]
#
# Prints a Markdown summary on stdout. Exit 0: nothing at or above the threshold
# has a fix available. Exit 1: something does (the image should be bumped).
# Exit 2: the report could not be read. Vulnerabilities with no fix are counted
# but never fail the run, because there is nothing to bump to.
set -euo pipefail

[ $# -ge 2 ] || {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
  exit 2
}
report=$1
image=$2
threshold=${3:-critical}
case $threshold in critical | high) ;; *)
  echo "error: threshold must be critical or high" >&2
  exit 2
  ;;
esac

jq -e '.matches | type == "array"' "$report" >/dev/null 2>&1 || {
  echo "error: $report is not a Grype report" >&2
  exit 2
}

# One row per severity: total, and how many of them have a fix.
jq -r --arg image "$image" --arg threshold "$threshold" '
  def rank: {"Critical": 4, "High": 3, "Medium": 2, "Low": 1, "Negligible": 0}[.] // -1;
  def fixable: .vulnerability.fix.state == "fixed";
  (.matches // []) as $m
  | ({"critical": "Critical", "high": "High"}[$threshold]) as $t
  | "### \($image)\n",
    "| severity | found | fix available |",
    "|---|---|---|",
    ( ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"][] as $s
      | [$m[] | select(.vulnerability.severity == $s)] as $of
      | select($of | length > 0)
      | "| \($s) | \($of | length) | \([$of[] | select(fixable)] | length) |" ),
    ( if ($m | length) == 0 then "| none | 0 | 0 |" else empty end ),
    "",
    ( [$m[] | select(fixable and (.vulnerability.severity | rank) >= ($t | rank))] as $bad
      | if ($bad | length) == 0
        then "**Passes**: nothing \($threshold) or worse has a fix available."
        else "**Fails**: \($bad | length) \($threshold)-or-worse finding(s) have a fix available:\n"
             + ( [$bad[:20][] | "- \(.vulnerability.id) (\(.vulnerability.severity)) in `\(.artifact.name) \(.artifact.version)`, fixed in \(.vulnerability.fix.versions | join(", "))"] | join("\n") )
        end )
' "$report"

# The verdict, again, as the exit status.
bad=$(jq --arg threshold "$threshold" '
  def rank: {"Critical": 4, "High": 3, "Medium": 2, "Low": 1, "Negligible": 0}[.] // -1;
  [(.matches // [])[] | select(.vulnerability.fix.state == "fixed" and (.vulnerability.severity | rank) >= (({"critical": "Critical", "high": "High"}[$threshold]) | rank))] | length' "$report")
[ "$bad" -eq 0 ]
