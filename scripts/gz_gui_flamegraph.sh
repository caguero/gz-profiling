#!/usr/bin/env bash
# gz_gui_flamegraph.sh — CPU flamegraph capture for the Gazebo *GUI* process.
#
# Unlike gz_flamegraph.sh (which profiles the headless server, gz-sim-main),
# this script profiles the GUI client process (gz-sim-gui-client, comm=gz-sim-gui).
# A server is launched to feed the GUI state over /world/<name>/state; perf is
# attached to the GUI process only, so the capture reflects GUI-side CPU:
# Qt event loop, ECM state deserialization, RenderUtil scene updates, and the
# Ogre render thread.
#
# Usage: ./gz_gui_flamegraph.sh <world_sdf> <label> [duration_s] [mode]
#
# In runtime mode, a <world>.topics file next to the SDF adds one gz topic
# subscriber per line and an executable <world>.setup.sh is run once the GUI
# is up (same conventions as gz_flamegraph.sh).
# Environment: GZ_INSTALL (workspace install prefix), FLAMEGRAPH_DIR, OUTPUT_DIR,
# STARTUP_WAIT.
#   mode: runtime (default) — attach to a settled GUI and sample DURATION seconds
#         loading           — sample the GUI from launch (Qt init + initial scene build)
#
# Prereqs:
#   - Workspace built with debug info (DWARF present in libgz-sim*, libgz-gui*)
#   - sudo sysctl kernel.perf_event_paranoid=1
#   - FlameGraph scripts at $FLAMEGRAPH_DIR
#   - A working OpenGL context (the GUI must be able to render)

set -eo pipefail

WORLD="${1:?Usage: $0 <world.sdf> <label> [duration] [mode]}"
LABEL="${2:?Usage: $0 <world.sdf> <label> [duration] [mode]}"
DURATION="${3:-30}"
MODE="${4:-runtime}"

FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-/home/caguero/rotary_ws/tools/FlameGraph}"
INSTALL="${GZ_INSTALL:-/home/caguero/rotary_ws/install}"
GZ_BIN="$INSTALL/bin/gz"
GUI_EXE="$INSTALL/libexec/gz/sim/gz-sim-gui-client"
SERVER_EXE="$INSTALL/libexec/gz/sim/gz-sim-main"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/captures_gui/$MODE}"
STARTUP_WAIT="${STARTUP_WAIT:-45}"   # large worlds (3k_shapes) load slowly

mkdir -p "$OUTPUT_DIR"

# --- prerequisite checks -----------------------------------------------------
[ -x "$GUI_EXE" ] || { echo "ERROR: GUI exe not found: $GUI_EXE" >&2; exit 1; }
[ -f "$FLAMEGRAPH_DIR/flamegraph.pl" ] || { echo "ERROR: FlameGraph not at $FLAMEGRAPH_DIR" >&2; exit 1; }
if [ "$(cat /proc/sys/kernel/perf_event_paranoid)" -gt 1 ]; then
  echo "ERROR: perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid), need <= 1" >&2
  echo "  Run: sudo sysctl kernel.perf_event_paranoid=1" >&2
  exit 1
fi

SERVER_PID=""; LAUNCH_PID=""; GUI_PID=""; SUB_PIDS=()
cleanup() {
  for p in "${SUB_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  [ -n "$GUI_PID" ]    && kill "$GUI_PID"    2>/dev/null || true
  [ -n "$LAUNCH_PID" ] && kill "$LAUNCH_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  # reap any stragglers spawned by the gz launcher (bracket avoids self-match)
  for p in $(pgrep -f '[l]ibexec/gz/sim/gz-sim' 2>/dev/null); do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

echo "=== GUI Flamegraph Capture: $LABEL ($MODE) ==="
echo "  World:    $WORLD"
echo "  Duration: ${DURATION}s"
echo "  Output:   $OUTPUT_DIR"

if [ "$MODE" = "loading" ]; then
  # Loading: start the server first, then wrap the GUI launch in perf so we
  # capture Qt init + render-engine init + initial scene construction.
  echo "[1/5] Launching server (headless, RTF from SDF)..."
  "$SERVER_EXE" -s -r "$WORLD" > "$OUTPUT_DIR/${LABEL}_server.log" 2>&1 &
  SERVER_PID=$!
  echo "  server PID: $SERVER_PID ; waiting ${STARTUP_WAIT}s for world load..."
  sleep "$STARTUP_WAIT"
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "ERROR: server died"; exit 1; }

  echo "[2/5] Recording GUI from launch for ${DURATION}s @ 997Hz..."
  perf record -e task-clock -F 997 --call-graph dwarf -o "$OUTPUT_DIR/perf_${LABEL}.data" \
    -- timeout "$DURATION" "$GUI_EXE" --verbose 1 "$WORLD" \
    > "$OUTPUT_DIR/${LABEL}_gui.log" 2>&1 || true
else
  # Runtime: launch server+GUI together (RTF from SDF), let it settle, then
  # attach perf to the settled GUI process for steady-state sampling.
  echo "[1/5] Launching server + GUI ($GZ_BIN sim -r, playing)..."
  # -r: run/unpause on start so dynamic worlds actually move (pose streaming path)
  "$GZ_BIN" sim -r -v 1 "$WORLD" > "$OUTPUT_DIR/${LABEL}_run.log" 2>&1 &
  LAUNCH_PID=$!
  echo "  launcher PID: $LAUNCH_PID ; waiting ${STARTUP_WAIT}s for load + scene build..."
  sleep "$STARTUP_WAIT"

  # Two processes match 'gz-sim-gui-client': a 1-thread 'sh -c' wrapper and the
  # real ~40-thread GUI. Pick the one with the most threads. Retry while it warms
  # up; guard against set -e/pipefail exiting on an empty pgrep match.
  GUI_PID=""
  for _try in 1 2 3 4 5 6 7 8; do
    best=0
    for cand in $(pgrep -f '[g]z-sim-gui-client' || true); do
      n=$(ls "/proc/$cand/task" 2>/dev/null | wc -l)
      if [ "$n" -gt "$best" ]; then best="$n"; GUI_PID="$cand"; fi
    done
    [ "$best" -gt 3 ] && break   # real GUI has many threads
    GUI_PID=""; sleep 3
  done
  if [ -z "$GUI_PID" ]; then
    echo "ERROR: GUI process (gz-sim-gui-client) not found. Last run log:" >&2
    tail -15 "$OUTPUT_DIR/${LABEL}_run.log" >&2 2>/dev/null || true
    exit 1
  fi
  echo "  GUI PID: $GUI_PID ($(ls /proc/$GUI_PID/task | wc -l) threads)"

  # Sensor subscribers (<world>.topics) and per world setup script
  # (<world>.setup.sh), same conventions as gz_flamegraph.sh, so the server
  # side behaves like the headless benchmark while the GUI is profiled.
  TOPICS_FILE="${WORLD%.sdf}.topics"
  if [ -f "$TOPICS_FILE" ]; then
    while IFS= read -r topic; do
      [ -n "$topic" ] || continue
      "$GZ_BIN" topic -e -t "$topic" > /dev/null 2>&1 &
      SUB_PIDS+=($!)
    done < "$TOPICS_FILE"
    echo "  Subscribed to ${#SUB_PIDS[@]} sensor topics"
    sleep 2
  fi
  SETUP_SCRIPT="${WORLD%.sdf}.setup.sh"
  if [ -x "$SETUP_SCRIPT" ]; then
    echo "  Running setup script: $SETUP_SCRIPT"
    "$SETUP_SCRIPT" || echo "  WARNING: setup script failed" >&2
    sleep 2
  fi

  echo "[2/5] Recording GUI for ${DURATION}s @ 997Hz (--call-graph dwarf)..."
  perf record -e task-clock -F 997 --call-graph dwarf -p "$GUI_PID" \
    -o "$OUTPUT_DIR/perf_${LABEL}.data" sleep "$DURATION" 2>&1 | tail -2
fi

echo "[3/5] Stopping simulation..."
cleanup; trap - EXIT
sleep 1

echo "[4/5] Folding stacks..."
perf script -i "$OUTPUT_DIR/perf_${LABEL}.data" 2>/dev/null \
  | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" > "$OUTPUT_DIR/${LABEL}.folded"

echo "[5/5] Rendering flamegraph SVG..."
"$FLAMEGRAPH_DIR/flamegraph.pl" \
  --title "GUI: $LABEL" \
  --subtitle "$(date '+%Y-%m-%d %H:%M'), ${DURATION}s @ 997Hz (gz-sim-gui, $MODE)" \
  "$OUTPUT_DIR/${LABEL}.folded" > "$OUTPUT_DIR/${LABEL}.svg"

echo ""
echo "=== Results ==="
echo "  SVG:    $OUTPUT_DIR/${LABEL}.svg"
echo "  Folded: $OUTPUT_DIR/${LABEL}.folded"
echo ""
echo "=== Top 20 self-time leaves ==="
# (C++ symbols contain spaces: strip the trailing count and split on ";".
#  "|| true" keeps a SIGPIPE from head aborting the script under pipefail.)
awk '{ cnt=$NF; sub(/ [0-9]+$/, ""); n=split($0,a,";"); printf "%s\t%d\n", a[n], cnt }' "$OUTPUT_DIR/${LABEL}.folded" \
  | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%12d  %s\n",s[k],k}' \
  | sort -rn | head -20 || true
