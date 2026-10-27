#!/usr/bin/env bash
# Summarize a Grype vulnerability report as Markdown and decide whether it fails.
# Used by .github/workflows/supply-chain.yml.
#
#   scan-summary.sh <report.json> <image> [critical|high] [exceptions-file]
#
# Prints a Markdown summary on stdout. Exit 0: nothing at or above the threshold
# has a fix available (or every such finding is an accepted exception). Exit 1:
# something does (the image should be bumped). Exit 2: bad input.
# Vulnerabilities with no fix are counted but never fail the run, because there
# is nothing to bump to.
#
# Exceptions (see docs/supply-chain.md) record a finding that cannot be fixed yet:
#   <exact image> | <vulnerability id> | <YYYY-MM-DD expiry> | <reason>
# An exception applies to that exact image reference, so a version bump makes it
# lapse, and it stops applying after its expiry date. Set TODAY to override the date.
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 2
}
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
  exit 2
}

[ $# -ge 2 ] || usage
report=$1
image=$2
threshold=${3:-critical}
exceptions=${4:-}
today=${TODAY:-$(date -u +%F)}
case $threshold in critical | high) ;; *) die "threshold must be critical or high" ;; esac

jq -e '.matches | type == "array"' "$report" >/dev/null 2>&1 || die "$report is not a Grype report"

# --- exceptions for this image: {"id": "expiry"} ------------------------------
active='{}'
if [ -n "$exceptions" ]; then
  [ -r "$exceptions" ] || die "cannot read $exceptions"
  # Every non-comment line must have four fields and a valid date: a typo must not
  # silently turn an exception off (or on).
  rows=$(awk -F'|' -v image="$image" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    {
      if (NF < 4 || trim($1) == "" || trim($2) == "" || trim($4) == "" || trim($3) !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
        printf "line %d is not <image> | <id> | <YYYY-MM-DD> | <reason>\n", NR > "/dev/stderr"
        bad = 1
        next
      }
      if (trim($1) == image) print trim($2) "\t" trim($3)
    }
    END { exit bad }' "$exceptions") || die "$exceptions is malformed"
  if [ -n "$rows" ]; then
    active=$(printf '%s\n' "$rows" | jq -R 'split("\t") | {(.[0]): .[1]}' | jq -s 'add')
  fi
fi

# --- verdict and summary, in one place ------------------------------------------
result=$(jq --arg image "$image" --arg threshold "$threshold" --arg today "$today" --argjson exceptions "$active" '
  def rank: {"Critical": 4, "High": 3, "Medium": 2, "Low": 1, "Negligible": 0}[.] // -1;
  def fixable: .vulnerability.fix.state == "fixed";
  def accepted: .vulnerability.id as $id | ($exceptions[$id] // "") >= $today and ($exceptions[$id] // "") != "";
  (.matches // []) as $m
  | ({"critical": "Critical", "high": "High"}[$threshold]) as $t
  | [$m[] | select(fixable and (.vulnerability.severity | rank) >= ($t | rank))] as $over
  | [$over[] | select(accepted)] as $ok
  | [$over[] | select(accepted | not)] as $bad
  | {
      failing: ($bad | length),
      markdown: (
        [ "### \($image)", "",
          "| severity | found | fix available |",
          "|---|---|---|" ]
        + [ ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"][] as $s
            | [$m[] | select(.vulnerability.severity == $s)] as $of
            | select($of | length > 0)
            | "| \($s) | \($of | length) | \([$of[] | select(fixable)] | length) |" ]
        + ( if ($m | length) == 0 then ["| none | 0 | 0 |"] else [] end )
        + [ "" ]
        + ( if ($bad | length) == 0
            then [ ( if ($ok | length) == 0
                     then "**Passes**: nothing \($threshold) or worse has a fix available."
                     else "**Passes**: \($ok | length) \($threshold)-or-worse finding(s) have a fix available but are accepted exceptions." end ) ]
            else [ "**Fails**: \($bad | length) \($threshold)-or-worse finding(s) have a fix available:" ]
                 + [ $bad[:20][] | "- \(.vulnerability.id) (\(.vulnerability.severity)) in `\(.artifact.name) \(.artifact.version)`, fixed in \(.vulnerability.fix.versions | join(", "))"
                       + ( .vulnerability.id as $id | if ($exceptions[$id] // "") != "" then " (the exception for it expired on \($exceptions[$id]))" else "" end ) ]
            end )
        + ( if ($ok | length) > 0 and ($bad | length) > 0
            then [ "", "Accepted exceptions: \([$ok[] | .vulnerability.id] | unique | join(", "))." ]
            elif ($ok | length) > 0
            then [ "", "Accepted: \([$ok[] | "\(.vulnerability.id) (until \($exceptions[.vulnerability.id]))"] | unique | join(", "))." ]
            else [] end )
        | join("\n") )
    }' "$report")

printf '%s' "$result" | jq -r .markdown
[ "$(printf '%s' "$result" | jq .failing)" -eq 0 ]
