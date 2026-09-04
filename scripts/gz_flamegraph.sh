#!/usr/bin/env bash
# gz_flamegraph.sh — Steady-state runtime flamegraph capture for Gazebo
#
# Usage: ./gz_flamegraph.sh <world_sdf> <label> [duration_s] [run_mode] [topic1 topic2 ...]
#
# run_mode: headless (default), gui, headless-rendering
# topics:   sensor topics to subscribe to (forces rendering pipeline to run)
#
# If an executable <world>.setup.sh exists next to the SDF it is run after the
# startup wait and the subscribers are up (e.g. to publish velocity commands).
#
# Environment:
#   SKIP_PERF=1   run the world for the duration without perf and only write
#                 <label>_stats.txt (a clean real time factor measurement)
#
# Prerequisites:
#   - Workspace built with ENABLE_PROFILER=OFF, RelWithDebInfo, -fno-omit-frame-pointer
#   - sudo sysctl kernel.perf_event_paranoid=1
#   - FlameGraph scripts at ~/rotary_ws/tools/FlameGraph/
#
# Notes:
#   - Samples task-clock (not cycles): on hybrid P/E core CPUs the default
#     cycles event is split into cpu_core/cpu_atom PMUs and perf script keeps
#     only one of them, silently dropping about half of the samples.
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
if [[ "${SKIP_PERF:-0}" != "1" && "$(cat /proc/sys/kernel/perf_event_paranoid)" -gt 1 ]]; then
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

# Run an optional per-world setup script (e.g. publish velocity commands so
# robots move). Looked up as <world>.setup.sh next to the SDF.
SETUP_SCRIPT="${WORLD%.sdf}.setup.sh"
if [[ -x "$SETUP_SCRIPT" ]]; then
    echo "  Running setup script: $SETUP_SCRIPT"
    "$SETUP_SCRIPT" || echo "  WARNING: setup script failed" >&2
    sleep 2
fi

# Snapshot the world statistics before the capture. The steady state step
# rate is the difference between this snapshot and the one taken after the
# capture: a free running server steps an empty world at hundreds of
# thousands of iterations per second while its entities are still being
# created, so sim_time / real_time from the final snapshot alone overstates
# the RTF of worlds that take a while to create.
STATS_TOPIC=$(gz topic -l 2>/dev/null | grep -m1 '^/world/.*/stats$' || true)
if [[ -n "$STATS_TOPIC" ]]; then
    timeout 5 gz topic -e -n 1 -t "$STATS_TOPIC" > "$OUTPUT_DIR/${LABEL}_stats_start.txt" 2>/dev/null || true
fi

# Capture with perf (or, with SKIP_PERF=1, just let the world run so the
# stats snapshot below gives an unperturbed real time factor)
if [[ "${SKIP_PERF:-0}" == "1" ]]; then
    echo "[4/6] SKIP_PERF=1: running ${DURATION}s without perf..."
    sleep "$DURATION"
else
    echo "[4/6] Recording perf data for ${DURATION}s at 997 Hz..."
    perf record -e task-clock -F 997 --call-graph dwarf -p "$GZ_PID" \
        -o "$OUTPUT_DIR/perf_${LABEL}.data" \
        sleep "$DURATION" 2>&1 | tail -3
fi

# Snapshot the world statistics again and report the steady state rate
if [[ -n "$STATS_TOPIC" ]]; then
    timeout 5 gz topic -e -n 1 -t "$STATS_TOPIC" > "$OUTPUT_DIR/${LABEL}_stats.txt" 2>/dev/null || true
    echo "  Stats: $(tr -s ' \n' ' ' < "$OUTPUT_DIR/${LABEL}_stats.txt" | cut -c1-160)"
    python3 - "$OUTPUT_DIR/${LABEL}_stats_start.txt" "$OUTPUT_DIR/${LABEL}_stats.txt" <<'PY' || true
import re, sys
def parse(path):
    s = open(path).read()
    def g(k):
        m = re.search(k + r' \{\s*(?:sec: (\d+))?\s*(?:nsec: (\d+))?', s)
        return int(m.group(1) or 0) + int(m.group(2) or 0) / 1e9 if m else None
    it = re.search(r'iterations: (\d+)', s)
    return (int(it.group(1)) if it else None, g('real_time'), g('sim_time'))
a, b = parse(sys.argv[1]), parse(sys.argv[2])
if None in a or None in b:
    sys.exit(0)
di, dr, ds = b[0] - a[0], b[1] - a[1], b[2] - a[2]
if dr > 0:
    print(f"  Steady state over {dr:.1f} s: {di / dr:.0f} steps/s, RTF {ds / dr:.2f}")
PY
fi

# Cleanup
echo "[5/6] Stopping simulation and subscribers..."
for pid in "${SUB_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
kill "$GZ_PID" 2>/dev/null || true
wait "$GZ_PID" 2>/dev/null || true

if [[ "${SKIP_PERF:-0}" == "1" ]]; then
    echo "[6/6] SKIP_PERF=1: no flamegraph. Stats: $OUTPUT_DIR/${LABEL}_stats.txt"
    exit 0
fi

# Generate flamegraph
echo "[6/6] Generating flamegraph..."
perf script -i "$OUTPUT_DIR/perf_${LABEL}.data" 2>/dev/null \
    | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
    > "$OUTPUT_DIR/${LABEL}.folded"

"$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "$LABEL" \
    --subtitle "$(date '+%Y-%m-%d %H:%M'), ${DURATION}s @ 997Hz ($RUN_MODE)" \
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
# (C++ symbols contain spaces, so strip the trailing count and split on ";".
#  "|| true" keeps a SIGPIPE from head aborting the script under pipefail.)
awk '{ cnt=$NF; sub(/ [0-9]+$/, ""); n=split($0,a,";"); printf "%s\t%d\n", a[n], cnt }' "$OUTPUT_DIR/${LABEL}.folded" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%12d  %s\n",s[k],k}' \
    | sort -rn | head -20 || true
