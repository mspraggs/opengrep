#!/usr/bin/env bash
# cProfile drill-down of the rule-loading portion of `opengrep scan`.
#
# Usage: ./bench_profile.sh RULES_PATH [PYTHON] [CLI]
#   RULES_PATH  your rules file (JSON or YAML)
#   PYTHON      the python of the env with the opengrep CLI installed
#               (default: python3)
#   CLI         the *Python* CLI console script to profile
#               (default: pyopengrep — the `opengrep` wrapper may dispatch
#               to the OCaml binary, which cProfile cannot see into)
#
# Scans an empty directory so nearly all Python time is CLI startup +
# rule loading + validation. Writes rule_load.prof next to this script
# and prints the top functions, filtered to the rule-loading modules.
set -euo pipefail

RULES="${1:?usage: bench_profile.sh RULES_PATH [PYTHON] [CLI]}"
PY="${2:-python3}"
CLI_NAME="${3:-pyopengrep}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROF="$HERE/rule_load.prof"
EMPTY="$(mktemp -d -t opengrep-bench-empty-XXXXXX)"
trap 'rm -rf "$EMPTY"' EXIT

# Prefer the console script sitting next to the chosen python, then PATH.
CLI="$(dirname "$PY")/$CLI_NAME"
if [ ! -x "$CLI" ]; then
    CLI="$(command -v "$CLI_NAME" || true)"
fi
if [ -z "$CLI" ] || [ ! -e "$CLI" ]; then
    echo "error: could not find the '$CLI_NAME' console script" >&2
    exit 1
fi

"$PY" -m cProfile -o "$PROF" "$CLI" scan \
    --config "$RULES" --quiet "$EMPTY" || true

"$PY" - "$PROF" <<'EOF'
import pstats, sys
stats = pstats.Stats(sys.argv[1])
print("\n=== Top 30 by cumulative time, rule-loading modules only ===")
stats.sort_stats("cumulative").print_stats(
    r"rule_lang|config_resolver|rpc|rule\.py|json|yaml", 30
)
print("=== Top 20 overall by cumulative time ===")
stats.sort_stats("cumulative").print_stats(20)
EOF

echo "Full profile written to $PROF (view interactively with: snakeviz $PROF)"
