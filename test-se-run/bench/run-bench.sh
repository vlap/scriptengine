#!/usr/bin/env bash
# ScriptEngine parallel loop benchmark
# Tests base.copy with and without --parallel flag.
#
# Usage:
#   bash run-bench.sh <inidata_dir> [N]
#
# The script picks large .nc files from inidata_dir, copies them locally,
# then benchmarks parallel vs sequential execution of base.copy loops.

set -uo pipefail

INIDATA_DIR=${1:?'Usage: run-bench.sh <inidata_dir> [N]'}
N=${2:-10}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORKDIR=${BENCH_WORKDIR:-${TMPDIR:-/tmp}/se-bench-$$}
SRCDIR=$WORKDIR/src

if ! command -v se >/dev/null 2>&1; then
    echo "ERROR: 'se' not found in PATH" >&2
    exit 1
fi

mapfile -t FILES < <(find "$INIDATA_DIR" -maxdepth 1 -name '*.nc' -size +1M -exec basename {} \; | sort)

if [ ${#FILES[@]} -lt 5 ]; then
    echo "ERROR: Need at least 5 large .nc files in $INIDATA_DIR, found ${#FILES[@]}" >&2
    exit 1
fi

FILES_YAML=$(printf ", '%s'" "${FILES[@]}")
FILES_YAML="[${FILES_YAML:2}]"

TOTAL_SIZE=$(find "$INIDATA_DIR" -maxdepth 1 -name '*.nc' -size +1M -exec du -cm {} + | tail -1 | cut -f1)

echo "ScriptEngine --parallel benchmark"
echo "=================================="
echo "  source:  $INIDATA_DIR"
echo "  files:   ${#FILES[@]} files (~${TOTAL_SIZE}MB total)"
echo "  runs:    $N iterations"
echo ""

echo "Preparing source files..."
mkdir -p "$SRCDIR"
for f in "${FILES[@]}"; do
    if [ ! -f "$SRCDIR/$f" ]; then
        cp "$INIDATA_DIR/$f" "$SRCDIR/"
    fi
done
echo "  done ($SRCDIR)"
echo ""

CONTEXT_YML=$WORKDIR/context.yml
cat > "$CONTEXT_YML" << EOF
- base.context:
    files: $FILES_YAML
    srcdir: "$SRCDIR"
    workdir: "$WORKDIR/run"
EOF

run_se() {
    local flag=$1 yml=$2
    rm -rf "$WORKDIR/run"
    TIMEFORMAT='%R'
    { time se --loglevel error $flag "$CONTEXT_YML" "$yml" ; } 2>&1 | tail -1
}

YML="$SCRIPT_DIR/bench-copy.yml"

# Warmup (prime filesystem caches)
run_se "" "$YML" > /dev/null 2>&1 || true
run_se "--parallel" "$YML" > /dev/null 2>&1 || true

echo "Running benchmark..."

P_TIMES=()
S_TIMES=()
for ((i=1; i<=N; i++)); do
    if (( i % 2 == 1 )); then
        P_TIMES+=("$(run_se "--parallel" "$YML")")
        S_TIMES+=("$(run_se "" "$YML")")
    else
        S_TIMES+=("$(run_se "" "$YML")")
        P_TIMES+=("$(run_se "--parallel" "$YML")")
    fi
done

MEDIAN_P=$(printf '%s\n' "${P_TIMES[@]}" | sort -n | awk -v n="$N" 'NR==int(n/2)+1{print}')
MEDIAN_S=$(printf '%s\n' "${S_TIMES[@]}" | sort -n | awk -v n="$N" 'NR==int(n/2)+1{print}')
SPEEDUP=$(awk "BEGIN{if($MEDIAN_S>0) printf \"%.0f\", ($MEDIAN_S-$MEDIAN_P)/$MEDIAN_S*100; else print 0}")

echo ""
echo "┌────────────┬──────────┬────────────┬─────────┐"
echo "│ Operation  │ Parallel │ Sequential │ Speedup │"
echo "├────────────┼──────────┼────────────┼─────────┤"
printf "│ %-10s │ %6ss │ %8ss │ %5s%% │\n" "base.copy" "$MEDIAN_P" "$MEDIAN_S" "$SPEEDUP"
echo "└────────────┴──────────┴────────────┴─────────┘"
echo ""
echo "All runs (seconds):"
echo "  parallel:   ${P_TIMES[*]}"
echo "  sequential: ${S_TIMES[*]}"
echo ""

rm -rf "$WORKDIR"
echo "Done."
