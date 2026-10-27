#!/usr/bin/env bash
# Offline tests for scripts/scan-summary.sh, with hand-made Grype reports.
# Run: scripts/test-scan-summary.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/scan-summary.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
expect() { # <description> <expected exit code> <command...>   (stdout+stderr kept in $out)
  local desc=$1 want=$2 got
  shift 2
  out=$("$@" 2>&1)
  got=$?
  if [ "$got" -eq "$want" ]; then echo "ok    $desc"; else
    echo "FAIL  $desc (exit $got, wanted $want)"
    printf '%s\n' "$out" | while IFS= read -r line; do printf '        %s\n' "$line"; done
    failures=$((failures + 1))
  fi
}
contains() { # <description> <needle>   checks $out
  if printf '%s' "$out" | grep -qF -- "$2"; then echo "ok    $1"; else
    echo "FAIL  $1 (missing: $2)"
    failures=$((failures + 1))
  fi
}
lacks() {
  if printf '%s' "$out" | grep -qF -- "$2"; then
    echo "FAIL  $1 (found: $2)"
    failures=$((failures + 1))
  else echo "ok    $1"; fi
}

# match <id> <severity> <fix state> [fixed version]
match() {
  jq -n --arg id "$1" --arg sev "$2" --arg state "$3" --arg fixed "${4:-}" '{
    vulnerability: {id: $id, severity: $sev, fix: {state: $state, versions: (if $fixed == "" then [] else [$fixed] end)}},
    artifact: {name: "openssl", version: "3.0.1"}}'
}
# report <match...>: a Grype report holding those matches
report() { jq -s '{matches: .}'; }

critical_fixed=$(match CVE-1 Critical fixed 3.0.9)
critical_unfixed=$(match CVE-2 Critical not-fixed)
high_fixed=$(match CVE-3 High fixed 1.2.4)
low_fixed=$(match CVE-4 Low fixed 9.9)

printf '%s\n%s\n%s\n%s\n' "$critical_fixed" "$critical_unfixed" "$high_fixed" "$low_fixed" | report >"$work/mixed.json"
printf '%s\n%s\n' "$critical_unfixed" "$low_fixed" | report >"$work/benign.json"
printf '%s\n' "$high_fixed" | report >"$work/high-only.json"
echo '{"matches": []}' >"$work/empty.json"
echo '{"not": "grype"}' >"$work/wrong.json"
echo 'not json' >"$work/garbage.json"

echo "-- the verdict"
expect "a fixable critical fails" 1 "$script" "$work/mixed.json" img:1
contains "  and names it, with the version that fixes it" "CVE-1 (Critical) in \`openssl 3.0.1\`, fixed in 3.0.9"
lacks "  but not the unfixable one" "CVE-2 (Critical) in"
lacks "  nor the low one" "CVE-4 (Low) in"
expect "an unfixable critical and a low pass" 0 "$script" "$work/benign.json" img:1
contains "  and say why" "Passes"
expect "a fixable high passes at the default threshold" 0 "$script" "$work/high-only.json" img:1
expect "a fixable high fails when the threshold is high" 1 "$script" "$work/high-only.json" img:1 high
expect "an empty report passes" 0 "$script" "$work/empty.json" img:1
contains "  and says nothing was found" "| none | 0 | 0 |"

echo "-- the summary"
expect "counts per severity, with how many are fixable" 1 "$script" "$work/mixed.json" registry.example/app:1.2.3
contains "  names the image" "### registry.example/app:1.2.3"
contains "  critical row" "| Critical | 2 | 1 |"
contains "  high row" "| High | 1 | 1 |"
contains "  low row" "| Low | 1 | 1 |"

echo "-- bad input"
expect "a JSON file that is not a Grype report is an error" 2 "$script" "$work/wrong.json" img:1
expect "garbage is an error" 2 "$script" "$work/garbage.json" img:1
expect "a missing file is an error" 2 "$script" "$work/nope.json" img:1
expect "an unknown threshold is an error" 2 "$script" "$work/empty.json" img:1 medium
expect "no arguments is an error" 2 "$script"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
