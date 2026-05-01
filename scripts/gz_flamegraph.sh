#!/usr/bin/env bash
# gz_flamegraph.sh — Steady-state runtime flamegraph capture for Gazebo
#
# Usage: ./gz_flamegraph.sh <world_sdf> <label> [duration_s] [run_mode] [topic1 topic2 ...]
#
# run_mode: headless (default), gui, headless-rendering
# topics:   sensor topics to subscribe to (forces rendering pipeline to run)
#
# Prerequisites:
#   - Workspace built with ENABLE_PROFILER=OFF, RelWithDebInfo, -fno-omit-frame-pointer
#   - sudo sysctl kernel.perf_event_paranoid=1
#   - FlameGraph scripts at ~/rotary_ws/tools/FlameGraph/
#
# Notes:
#   - Uses --call-graph dwarf for reliable stack unwinding (fp produces [unknown] stacks)
#   - Waits for loading to complete before recording (large worlds can take 30s+)

set -eo pipefail

WORLD="${1:?Usage: $0 <world.sdf> <label> [duration] [run_mode] [topic ...]}"
LABEL="${2:?Usage: $0 <world.sdf> <label> [duration] [run_mode] [topic ...]}"
DURATION="${3:-30}"
RUN_MODE="${4:-headless}"
shift 4 2>/dev/null || true
TOPICS=("$@")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$(pwd)/FlameGraph}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/captures/runtime}"
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

# Build launch args
LAUNCH_ARGS=("-r" "$WORLD")
case "$RUN_MODE" in
    headless)
        LAUNCH_ARGS=("-s" "-r" "$WORLD")
        STARTUP_WAIT=40
        ;;
    headless-rendering)
        LAUNCH_ARGS=("-s" "-r" "--headless-rendering" "$WORLD")
        STARTUP_WAIT=40
        ;;
    gui)
        LAUNCH_ARGS=("-r" "$WORLD")
        STARTUP_WAIT=40
        ;;
    *)
        echo "ERROR: Unknown run_mode '$RUN_MODE'. Use: headless, gui, headless-rendering" >&2
        exit 1
        ;;
esac

echo "=== Flamegraph Capture: $LABEL ==="
echo "  World:    $WORLD"
echo "  Mode:     $RUN_MODE"
echo "  Duration: ${DURATION}s"
echo "  Output:   $OUTPUT_DIR"
echo ""

# Note: source your workspace setup.bash and set GZ_CONFIG_PATH before running this script

# Launch simulation
echo "[1/6] Launching gz-sim-main..."
"$GZ_SIM_MAIN" "${LAUNCH_ARGS[@]}" &
GZ_PID=$!
echo "  PID: $GZ_PID"

# Wait for startup
echo "[2/6] Waiting ${STARTUP_WAIT}s for startup..."
sleep "$STARTUP_WAIT"

# Verify still running
if ! kill -0 "$GZ_PID" 2>/dev/null; then
    echo "ERROR: gz-sim-main exited during startup" >&2
    exit 1
fi

# Start subscribers for sensor topics
SUB_PIDS=()
if [[ ${#TOPICS[@]} -gt 0 ]]; then
    echo "[3/6] Starting subscribers for ${#TOPICS[@]} sensor topics..."
    for topic in "${TOPICS[@]}"; do
        gz topic -e -t "$topic" > /dev/null 2>&1 &
        SUB_PIDS+=($!)
        echo "  Subscribed: $topic (PID $!)"
    done
    sleep 2  # let subscriptions establish
else
    echo "[3/6] No sensor topics to subscribe (skipping)"
fi

# Capture with perf
echo "[4/6] Recording perf data for ${DURATION}s at 997 Hz..."
perf record -F 997 --call-graph dwarf -p "$GZ_PID" \
    -o "$OUTPUT_DIR/perf_${LABEL}.data" \
    sleep "$DURATION" 2>&1 | tail -3

# Cleanup
echo "[5/6] Stopping simulation and subscribers..."
for pid in "${SUB_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
kill "$GZ_PID" 2>/dev/null || true
wait "$GZ_PID" 2>/dev/null || true

# Generate flamegraph
echo "[6/6] Generating flamegraph..."
perf script -i "$OUTPUT_DIR/perf_${LABEL}.data" 2>/dev/null \
    | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
    > "$OUTPUT_DIR/${LABEL}.folded"

"$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "$LABEL" \
    --subtitle "$(date '+%Y-%m-%d %H:%M') — ${DURATION}s @ 997Hz ($RUN_MODE)" \
    "$OUTPUT_DIR/${LABEL}.folded" \
    > "$OUTPUT_DIR/${LABEL}.svg"

echo ""
echo "=== Results ==="
echo "  SVG:    $OUTPUT_DIR/${LABEL}.svg"
echo "  Folded: $OUTPUT_DIR/${LABEL}.folded"
echo "  Data:   $OUTPUT_DIR/perf_${LABEL}.data"
echo ""

# Print top-20 self-time leaves
echo "=== Top 20 self-time leaves ==="
awk '{ n=split($1,a,";"); printf "%s\t%d\n", a[n], $NF }' "$OUTPUT_DIR/${LABEL}.folded" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%12d  %s\n",s[k],k}' \
    | sort -rn | head -20
