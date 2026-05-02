#!/usr/bin/env bash
# gz_cache_stats.sh — Measure CPU cache performance for a running Gazebo simulation
#
# Usage:
#   Runtime:  ./gz_cache_stats.sh --pid <PID> [duration_s]
#   Loading:  ./gz_cache_stats.sh --load <world.sdf>
#
# Measures cache miss rates and Instructions Per Cycle (IPC) using
# hardware performance counters via perf stat.
#
# IPC interpretation:
#   2-4   Healthy (compute-bound)
#   1-2   Moderate
#   <1    Memory-bound (CPU stalled waiting for RAM)
#
# Prerequisites:
#   - sudo sysctl kernel.perf_event_paranoid=1
#   - GZ_SIM_MAIN set or gz-sim-main in PATH (for --load mode)

set +o pipefail

MODE="${1:?Usage: $0 --pid <PID> [duration] OR $0 --load <world.sdf>}"

case "$MODE" in
    --pid)
        PID="${2:?Usage: $0 --pid <PID> [duration_s]}"
        DURATION="${3:-10}"
        LABEL="PID $PID"

        if ! kill -0 "$PID" 2>/dev/null; then
            echo "ERROR: Process $PID not found" >&2
            exit 1
        fi

        echo "============================================"
        echo "  Cache Stats: $LABEL (${DURATION}s sample)"
        echo "============================================"
        echo ""

        perf stat -e \
            cpu_core/cache-references/,\
cpu_core/cache-misses/,\
cpu_core/L1-dcache-loads/,\
cpu_core/L1-dcache-load-misses/,\
cpu_core/LLC-loads/,\
cpu_core/LLC-load-misses/,\
cpu_core/instructions/,\
cpu_core/cycles/ \
            -p "$PID" sleep "$DURATION" 2>&1
        ;;

    --load)
        WORLD="${2:?Usage: $0 --load <world.sdf>}"
        GZ_SIM_MAIN="${GZ_SIM_MAIN:-$(which gz-sim-main 2>/dev/null || echo "")}"
        LABEL=$(basename "$WORLD" .sdf)

        if [[ -z "$GZ_SIM_MAIN" || ! -x "$GZ_SIM_MAIN" ]]; then
            echo "ERROR: gz-sim-main not found. Set GZ_SIM_MAIN." >&2
            exit 1
        fi

        echo "============================================"
        echo "  Cache Stats (loading): $LABEL"
        echo "============================================"
        echo ""

        perf stat -e \
            cpu_core/cache-references/,\
cpu_core/cache-misses/,\
cpu_core/L1-dcache-loads/,\
cpu_core/L1-dcache-load-misses/,\
cpu_core/LLC-loads/,\
cpu_core/LLC-load-misses/,\
cpu_core/instructions/,\
cpu_core/cycles/ \
            -- "$GZ_SIM_MAIN" -s -r --iterations 1 "$WORLD" 2>&1
        ;;

    --all-runtime)
        # Convenience: measure all worlds in a directory (must already be running)
        WORLDS_DIR="${2:-.}"
        DURATION="${3:-10}"

        echo "============================================"
        echo "  Cache Stats: All running simulations"
        echo "============================================"

        for pid_cmd in $(ps -ef | grep 'gz-sim-main -s -r' | grep -v grep | grep -v bash | awk '{print $2 ":" $NF}'); do
            PID=$(echo "$pid_cmd" | cut -d: -f1)
            WORLD=$(echo "$pid_cmd" | cut -d: -f2)
            LABEL=$(basename "$WORLD" .sdf)
            echo ""
            echo "--- $LABEL (PID $PID, ${DURATION}s) ---"
            perf stat -e \
                cpu_core/cache-misses/,\
cpu_core/LLC-load-misses/,\
cpu_core/instructions/,\
cpu_core/cycles/ \
                -p "$PID" sleep "$DURATION" 2>&1 \
                | grep -E 'cache-misses|LLC-load-misses|insn per cycle|elapsed'
        done
        ;;

    --all-loading)
        # Convenience: run loading cache stats for all worlds in a directory
        WORLDS_DIR="${2:?Usage: $0 --all-loading <worlds_dir>}"
        GZ_SIM_MAIN="${GZ_SIM_MAIN:-$(which gz-sim-main 2>/dev/null || echo "")}"

        if [[ -z "$GZ_SIM_MAIN" || ! -x "$GZ_SIM_MAIN" ]]; then
            echo "ERROR: gz-sim-main not found. Set GZ_SIM_MAIN." >&2
            exit 1
        fi

        echo "============================================"
        echo "  Cache Stats: Loading all worlds"
        echo "============================================"

        for world in "$WORLDS_DIR"/*.sdf; do
            [ -f "$world" ] || continue
            LABEL=$(basename "$world" .sdf)
            echo ""
            echo "--- $LABEL ---"
            perf stat -e \
                cpu_core/cache-misses/,\
cpu_core/LLC-load-misses/,\
cpu_core/instructions/,\
cpu_core/cycles/ \
                -- "$GZ_SIM_MAIN" -s -r --iterations 1 "$world" 2>&1 \
                | grep -E 'cache-misses|LLC-load-misses|insn per cycle|elapsed'
            sleep 2
        done
        ;;

    *)
        echo "Usage:" >&2
        echo "  $0 --pid <PID> [duration_s]     # measure running sim" >&2
        echo "  $0 --load <world.sdf>           # measure loading" >&2
        echo "  $0 --all-runtime [dir] [dur]    # all running sims" >&2
        echo "  $0 --all-loading <worlds_dir>   # all worlds loading" >&2
        exit 1
        ;;
esac
