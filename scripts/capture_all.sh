#!/usr/bin/env bash
# capture_all.sh — Run flamegraph captures for all worlds in a directory
#
# Usage: ./capture_all.sh <worlds_dir> [--runtime-only] [--loading-only]
#
# Each .sdf file in <worlds_dir> is captured as a headless runtime + loading
# flamegraph. The label is derived from the filename (e.g., jetty.sdf → jetty).
#
# For sensor worlds that need subscribers, create a companion file
# <world>.topics with one topic per line (e.g., gpu_lidar_sensor.topics).
#
# Prerequisites:
#   - Workspace built with ENABLE_PROFILER=OFF, RelWithDebInfo, -fno-omit-frame-pointer
#   - sudo sysctl kernel.perf_event_paranoid=1
#   - Assets pre-cached (run each world once beforehand)

set -eo pipefail

WORLDS_DIR="${1:?Usage: $0 <worlds_dir> [--runtime-only] [--loading-only]}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse flags
DO_RUNTIME=true
DO_LOADING=true
for arg in "$@"; do
    case "$arg" in
        --runtime-only) DO_LOADING=false ;;
        --loading-only) DO_RUNTIME=false ;;
    esac
done

DURATION=30

echo "============================================"
echo "  Gazebo Performance Profiling"
echo "============================================"
echo "  Worlds dir: $WORLDS_DIR"
echo "  Duration:   ${DURATION}s per runtime capture"
echo "  Runtime:    $DO_RUNTIME"
echo "  Loading:    $DO_LOADING"
echo ""

WORLDS_DIR="$(cd "$WORLDS_DIR" && pwd)"
COUNT=0

for world in "$WORLDS_DIR"/*.sdf; do
    [ -f "$world" ] || continue

    label=$(basename "$world" .sdf)
    topics_file="${world%.sdf}.topics"

    # Read sensor topics from companion file if it exists
    topics=()
    if [ -f "$topics_file" ]; then
        while IFS= read -r topic; do
            [ -n "$topic" ] && topics+=("$topic")
        done < "$topics_file"
        mode="headless-rendering"
    else
        mode="headless"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $label"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if $DO_RUNTIME; then
        echo ""
        echo "--- Runtime capture ---"
        "$SCRIPT_DIR/gz_flamegraph.sh" "$world" "$label" "$DURATION" "$mode" "${topics[@]}"
    fi

    if $DO_LOADING; then
        echo ""
        echo "--- Loading capture ---"
        "$SCRIPT_DIR/gz_loading_flamegraph.sh" "$world" "$label"
    fi

    COUNT=$((COUNT + 1))
done

# ---- Summary ----

echo ""
echo "============================================"
echo "  $COUNT worlds captured"
echo "============================================"
