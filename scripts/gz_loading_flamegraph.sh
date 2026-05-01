#!/usr/bin/env bash
# gz_loading_flamegraph.sh — Startup/loading time flamegraph capture for Gazebo
#
# Usage: ./gz_loading_flamegraph.sh <world_sdf> <label>
#
# Wraps the entire gz-sim-main process launch with perf (not attach-to-PID).
# Uses --iterations 1 so the process exits after startup + 1 sim step.
# The flamegraph shows where time goes during SDF parsing, mesh loading,
# DART construction, ogre2 scene setup, etc.
#
# Prerequisites:
#   - Workspace built with ENABLE_PROFILER=OFF, RelWithDebInfo, -fno-omit-frame-pointer
#   - sudo sysctl kernel.perf_event_paranoid=1
#   - Assets pre-cached locally (run world once beforehand to download)

set -eo pipefail

WORLD="${1:?Usage: $0 <world.sdf> <label>}"
LABEL="${2:?Usage: $0 <world.sdf> <label>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$(pwd)/FlameGraph}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/captures/loading}"
GZ_SIM_MAIN="${GZ_SIM_MAIN:-$(which gz-sim-main 2>/dev/null || echo "")}"

# Try common locations if not found
if [[ -z "$GZ_SIM_MAIN" || ! -x "$GZ_SIM_MAIN" ]]; then
    for candidate in \
        "$(dirname "$SCRIPT_DIR")/../../install/libexec/gz/sim/gz-sim-main" \
        "/usr/libexec/gz/sim/gz-sim-main"; do
        if [[ -x "$candidate" ]]; then
            GZ_SIM_MAIN="$candidate"
            break
        fi
    done
fi

mkdir -p "$OUTPUT_DIR"

# Verify prerequisites
if [[ -z "$GZ_SIM_MAIN" || ! -x "$GZ_SIM_MAIN" ]]; then
    echo "ERROR: gz-sim-main not found. Set GZ_SIM_MAIN or add it to PATH." >&2
    exit 1
fi
if [[ ! -f "$FLAMEGRAPH_DIR/flamegraph.pl" ]]; then
    echo "ERROR: FlameGraph scripts not found at $FLAMEGRAPH_DIR" >&2
    echo "  Set FLAMEGRAPH_DIR or clone https://github.com/brendangregg/FlameGraph" >&2
    exit 1
fi
if [[ "$(cat /proc/sys/kernel/perf_event_paranoid)" -gt 1 ]]; then
    echo "ERROR: perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid), need <= 1" >&2
    echo "  Run: sudo sysctl kernel.perf_event_paranoid=1" >&2
    exit 1
fi

# Note: source your workspace setup.bash and set GZ_CONFIG_PATH before running this script

echo "=== Loading Flamegraph: $LABEL ==="
echo "  World:  $WORLD"
echo "  Output: $OUTPUT_DIR"
echo ""

# Capture: wrap entire process with perf
# --iterations 1: exit after startup + 1 simulation step
echo "[1/4] Recording loading with perf (startup + 1 iteration)..."
{ time perf record -F 997 --call-graph dwarf \
    -o "$OUTPUT_DIR/perf_${LABEL}_loading.data" \
    -- "$GZ_SIM_MAIN" -s -r --iterations 1 "$WORLD" \
    2>&1 | tail -5 ; } 2> "$OUTPUT_DIR/${LABEL}_wallclock.txt"

echo ""
echo "  Wall-clock time:"
cat "$OUTPUT_DIR/${LABEL}_wallclock.txt"
echo ""

# Generate flamegraph
echo "[2/4] Collapsing stacks..."
perf script -i "$OUTPUT_DIR/perf_${LABEL}_loading.data" 2>/dev/null \
    | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
    > "$OUTPUT_DIR/${LABEL}_loading.folded"

echo "[3/4] Generating SVG..."
"$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "$LABEL (loading)" \
    --subtitle "$(date '+%Y-%m-%d %H:%M') — startup + 1 iteration" \
    "$OUTPUT_DIR/${LABEL}_loading.folded" \
    > "$OUTPUT_DIR/${LABEL}_loading.svg"

echo ""
echo "=== Results ==="
echo "  SVG:       $OUTPUT_DIR/${LABEL}_loading.svg"
echo "  Folded:    $OUTPUT_DIR/${LABEL}_loading.folded"
echo "  Data:      $OUTPUT_DIR/perf_${LABEL}_loading.data"
echo "  Wallclock: $OUTPUT_DIR/${LABEL}_wallclock.txt"
echo ""

# Print top-20 self-time leaves
echo "[4/4] Top 20 self-time leaves (loading):"
awk '{ n=split($1,a,";"); printf "%s\t%d\n", a[n], $NF }' "$OUTPUT_DIR/${LABEL}_loading.folded" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%12d  %s\n",s[k],k}' \
    | sort -rn | head -20
