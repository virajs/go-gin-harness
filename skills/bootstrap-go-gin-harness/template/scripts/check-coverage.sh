#!/usr/bin/env bash
# check-coverage.sh — enforce per-area coverage thresholds.
#
# Usage: check-coverage.sh <coverage.out> <min-domain-app> <min-other>
#
# Reads `go tool cover -func`, splits by package prefix:
#   internal/domain, internal/app    → must meet $min-domain-app (default 80)
#   everything else                  → must meet $min-other      (default 60)
#
# Exit code:
#   0 — all gates passed
#   1 — at least one package below its gate
#
# The Makefile invokes this. Override per-call with `make cover COVER_MIN_DOMAIN=85`.

set -euo pipefail

profile="${1:-coverage.out}"
min_domain="${2:-80}"
min_other="${3:-60}"

if [[ ! -f "$profile" ]]; then
  echo "coverage profile not found: $profile" >&2
  exit 2
fi

fail=0

# go tool cover -func emits lines like:
#   {{ProjectName}}/internal/domain/projects/project.go:42:  NewProject  100.0%
# We aggregate by package (strip the file + symbol parts).
go tool cover -func="$profile" | awk -v dom="$min_domain" -v oth="$min_other" '
  /^total:/ { next }                              # skip "total" summary line
  {
    # Field 1 = file:line, Field 3 = "12.5%"
    n = split($1, p, "/")
    pkg = ""
    for (i = 1; i < n; i++) { pkg = (pkg == "" ? p[i] : pkg "/" p[i]) }
    pct = $3 + 0
    pkgs[pkg]   += pct
    counts[pkg] += 1
  }
  END {
    for (pkg in pkgs) {
      avg = pkgs[pkg] / counts[pkg]
      gate = oth
      if (pkg ~ /internal\/domain/ || pkg ~ /internal\/app/) { gate = dom }
      if (avg + 0.001 < gate + 0) {
        printf "FAIL %s  %.1f%% < %d%%\n", pkg, avg, gate
        rc = 1
      } else {
        printf "PASS %s  %.1f%% >= %d%%\n", pkg, avg, gate
      }
    }
    exit rc + 0
  }
' || fail=$?

if [[ $fail -ne 0 ]]; then
  echo "" >&2
  echo "Coverage gate FAILED — fix tests or justify in an exclusion comment." >&2
  exit 1
fi

echo "Coverage gate PASSED (domain/app >= ${min_domain}%, other >= ${min_other}%)"
