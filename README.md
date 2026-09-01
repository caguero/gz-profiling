# Gazebo Performance Profiling

CPU flamegraph benchmarks for [Gazebo](https://gazebosim.org). Interactive flamegraphs and reports are published at:

**https://caguero.github.io/gz-profiling/**

## Repository Structure

```
scripts/                    # Capture and analysis tools
  gz_flamegraph.sh          # Runtime flamegraph capture
  gz_loading_flamegraph.sh  # Loading/startup capture (1 iteration)
  capture_all.sh            # Captures all worlds in a directory
  gz_hotspots.sh            # Gazebo hotspot analysis from .folded
  gz_cache_stats.sh         # CPU cache miss rate / IPC measurement
  gz_cache_flamegraph.sh    # Cache-miss flamegraph capture
  gz_compare_cpu_cache.sh   # CPU vs cache-miss side-by-side comparison
  gz_offcpu_flamegraph.sh   # Off-CPU (blocking) flamegraph capture
  gz_false_sharing.sh       # False sharing detection via perf c2c
  gz_sched_analysis.sh      # Scheduler latency analysis
  gz_per_thread_flamegraph.sh  # Split captures into per-thread flamegraphs
  gz_diff_flamegraph.sh     # Differential flamegraph (before/after)
  gz_summary.sh             # Unified summary combining all dimensions
  gz_analyze.sh             # Post-capture analysis + cross-world merge
  gz_full_pipeline.sh       # End-to-end: capture + analyze + rank
  gz_publish_run.sh         # Package captures into a dated run for the repo
worlds/                     # Benchmark world SDFs (all RTF=0)
  3k_shapes.sdf             # 3000 dynamic entities
  3k_shapes_static.sdf      # 3000 static entities
  sensors.sdf               # Non-rendering sensors (IMU, mag, etc.)
  jetty.sdf                 # Complex real-world scene
  gpu_lidar_sensor.sdf      # GPU lidar rendering
  gpu_lidar_sensor.topics   # Sensor topics for subscriber
  sensors_demo.sdf          # 6 rendering sensors
  sensors_demo.topics       # Sensor topics for subscriber
  moving_robots_and_sensors.sdf       # gz-sim PR #3846 benchmark world (driven robots + sensors)
  moving_robots_and_sensors.topics    # Sensor topics for subscriber
  moving_robots_and_sensors.setup.sh  # Publishes cmd_vel / joint trajectory after load
2026-04-21/, 2026-07-03/, 2026-09-01/   # Benchmark run results, one directory per run
  runtime/*.svg, *.folded   # Interactive runtime flamegraphs + stacks
  loading/*.svg, *.folded   # Interactive loading flamegraphs + stacks
  cache/*.svg, *.folded     # Cache-miss flamegraphs
  c2c/*.tsv                 # False sharing (HITM) reports
  sched/*.tsv               # Scheduler latency reports
  threads/*.tsv             # Per-thread CPU distribution
  summary/*.tsv             # Per-world + cross-world ranked summaries
  findings_report.pdf       # Full analysis report
  index.html                # Per-run index with links
```

## Prerequisites

```bash
# Install perf
sudo apt install linux-tools-$(uname -r)

# Clone FlameGraph scripts
git clone https://github.com/brendangregg/FlameGraph

# Allow user-mode profiling (resets on reboot)
sudo sysctl kernel.perf_event_paranoid=1
```

### Additional permissions for extended analysis

The core CPU flamegraph and cache analysis scripts work with `perf_event_paranoid=1`. The extended analysis scripts have additional requirements:

| Script | Requirement | Command |
|---|---|---|
| `gz_offcpu_flamegraph.sh` | eBPF (needs root) | `sudo apt install bpfcc-tools` |
| `gz_false_sharing.sh` | Works at `paranoid=1` | (no extra permissions) |
| `gz_sched_analysis.sh` | Uses `/proc/schedstat` | (no extra permissions) |
| `gz_per_thread_flamegraph.sh` | Post-processing only | (no extra permissions) |
| `gz_diff_flamegraph.sh` | Post-processing only | (no extra permissions) |

All `sysctl` settings reset on reboot.

## Build Configuration

Build your Gazebo workspace with debug symbols and frame pointers. Use `ENABLE_PROFILER=OFF` for clean flamegraph captures (discovery phase). Use `ENABLE_PROFILER=ON` for before/after optimization validation with Remotery.

```bash
cd <GZ_WS>
colcon build --merge-install \
  --cmake-args -DENABLE_PROFILER=OFF \
               -DCMAKE_BUILD_TYPE=RelWithDebInfo \
               -DCMAKE_CXX_FLAGS="-fno-omit-frame-pointer" \
               -DCMAKE_C_FLAGS="-fno-omit-frame-pointer"
```

## Running Captures

### Environment Setup

Source your workspace and set the required environment variables before running any capture script:

```bash
source <GZ_WS>/install/setup.bash
export GZ_CONFIG_PATH=<GZ_WS>/install/share/gz:$GZ_CONFIG_PATH
export GZ_SIM_MAIN=<GZ_WS>/install/libexec/gz/sim/gz-sim-main
export FLAMEGRAPH_DIR=~/FlameGraph
```

### Capture All Worlds

```bash
# Capture all worlds in the provided directory
./scripts/capture_all.sh worlds/

# Runtime captures only (skip loading)
./scripts/capture_all.sh worlds/ --runtime-only

# Loading captures only (skip runtime)
./scripts/capture_all.sh worlds/ --loading-only

# Full analysis: CPU + cache + off-CPU + false sharing + scheduler
./scripts/capture_all.sh worlds/ --full

# Selective extended analysis
./scripts/capture_all.sh worlds/ --with-offcpu --with-sched

# Use your own worlds
./scripts/capture_all.sh /path/to/my/worlds/
```

Output goes to `captures/runtime/` and `captures/loading/` under the current working directory. When satisfied with the results, publish them to the repository (see [Publishing a Run](#publishing-a-run)).

### Capture a Single World

```bash
# Runtime: 30s steady-state capture
./scripts/gz_flamegraph.sh worlds/jetty.sdf jetty 30 headless

# With sensor subscribers (for rendering-sensor worlds)
./scripts/gz_flamegraph.sh worlds/gpu_lidar_sensor.sdf gpu_lidar 30 headless-rendering /lidar

# Loading: startup + 1 iteration
./scripts/gz_loading_flamegraph.sh worlds/jetty.sdf jetty
```

### Sensor Worlds

For worlds with rendering sensors, the sensor pipeline skips work unless there's a subscriber. Two ways to handle this:

1. **Companion `.topics` file**: create `<world>.topics` alongside the SDF with one topic per line. `capture_all.sh` reads this automatically.
2. **Command-line topics**: pass topics as extra arguments to `gz_flamegraph.sh`.

List the topics the sensors actually publish (for example an RGBD camera publishes
`<topic>/image`, `<topic>/depth_image` and `<topic>/points`, not `<topic>`); run the
world once and check `gz topic -l`. A subscriber on a topic that does not exist
leaves that sensor idle.

### Worlds That Need Commands

Some worlds only do interesting work once something drives them (velocity
commands, joint trajectories). Put an executable `<world>.setup.sh` next to the
SDF; `gz_flamegraph.sh` runs it after the startup wait and after the subscribers
are up, before recording. See `worlds/moving_robots_and_sensors.setup.sh`, which
mirrors what gz-sim's `BENCHMARK_server_run` publishes for that world.

### Real Time Factor Without perf

`SKIP_PERF=1` makes `gz_flamegraph.sh` run the world for the duration without
attaching `perf` and only write `<label>_stats.txt`, a snapshot of
`/world/<name>/stats` (sim time, real time, iterations). Every runtime capture
writes the same snapshot after recording, but the unprofiled one is the number
to quote for RTF:

```bash
SKIP_PERF=1 OUTPUT_DIR=captures/rtf ./scripts/gz_flamegraph.sh worlds/jetty.sdf jetty 30 headless
```

### Custom Worlds

To add a new benchmark world:

1. Copy the SDF to your worlds directory
2. Set `<real_time_factor>0</real_time_factor>` in the `<physics>` element to run at maximum speed
3. If it has rendering sensors, create a `.topics` companion file
4. Run `capture_all.sh` pointing to your directory

### Analyzing Hotspots

After capturing, use `gz_hotspots.sh` to automatically identify Gazebo-owned optimization targets:

```bash
./scripts/gz_hotspots.sh 2026-04-21/runtime/3k_shapes_static.folded
./scripts/gz_hotspots.sh 2026-04-21/runtime/jetty_headless.folded 20  # top 20
```

Outputs: optimization targets (inclusive time), attribution (which Gazebo function calls which external cost), external context, and a summary of how much CPU runs under Gazebo code.

### CPU Cache Analysis

Measure cache miss rates and Instructions Per Cycle (IPC) to determine if a workload is compute-bound or memory-bound:

```bash
# Measure a running simulation for 10 seconds
./scripts/gz_cache_stats.sh --pid $PID 10

# Measure loading performance
./scripts/gz_cache_stats.sh --load worlds/3k_shapes_static.sdf

# Measure all running simulations at once
./scripts/gz_cache_stats.sh --all-runtime

# Measure loading for all worlds
./scripts/gz_cache_stats.sh --all-loading worlds/
```

IPC interpretation: 2-4 = healthy (compute-bound), 1-2 = moderate, <1 = memory-bound (CPU stalled on RAM).

### Cache-Miss Flamegraphs

Generate flamegraphs showing WHERE cache misses happen (not CPU time):

```bash
# Runtime: capture cache misses from a running world
./scripts/gz_cache_flamegraph.sh --runtime worlds/3k_shapes_static.sdf 3k_static 30

# Loading: capture cache misses during startup
./scripts/gz_cache_flamegraph.sh --loading worlds/jetty.sdf jetty
```

### CPU vs Cache-Miss Comparison

Compare CPU flamegraphs with cache-miss flamegraphs to identify cache-hostile functions:

```bash
./scripts/gz_compare_cpu_cache.sh captures/runtime/3k_shapes_static.folded captures/cache/3k_static_rt_cachemiss.folded
```

Output shows cache ratio per function: >1.3 = cache-hostile (needs data layout fix), <0.7 = cache-friendly (needs algorithmic fix).

### Off-CPU Flamegraphs

Capture where threads **block** (mutexes, I/O, condition waits) — complementary to CPU flamegraphs:

```bash
# Runtime: capture off-CPU events from a running world
./scripts/gz_offcpu_flamegraph.sh worlds/jetty.sdf jetty 10 headless

# Attach to a running process
./scripts/gz_offcpu_flamegraph.sh --pid $PID jetty 10
```

Requires sudo access (eBPF programs need root) and `bpfcc-tools` installed (`sudo apt install bpfcc-tools`).

### False Sharing Detection

Detect cacheline contention between threads using `perf c2c`:

```bash
# Runtime: capture HITM events from a running world
./scripts/gz_false_sharing.sh --runtime worlds/3k_shapes.sdf 3k_dynamic 5

# Analyze existing perf c2c data
./scripts/gz_false_sharing.sh --analyze captures/c2c/perf_jetty_c2c.data jetty
```

High HITM rates on a symbol indicate threads writing to different data that shares a cache line.

### Scheduler Analysis

Measure per-thread scheduling delays that affect real-time simulation:

```bash
./scripts/gz_sched_analysis.sh worlds/jetty.sdf jetty 10
```

Flags threads where average scheduling delay exceeds `SCHED_THRESHOLD_MS` (default 1.0ms). Uses `/proc/PID/schedstat` — no special permissions needed.

### Per-Thread Flamegraphs

Split an existing perf capture into one flamegraph per thread:

```bash
./scripts/gz_per_thread_flamegraph.sh captures/runtime/perf_jetty.data jetty
```

Post-processing only — works on existing `perf_*.data` files without re-capturing.

### Differential Flamegraphs

Compare before/after captures to validate optimizations:

```bash
./scripts/gz_diff_flamegraph.sh baseline.folded optimized.folded my_optimization
```

Red = regression, blue = improvement. Also generates a TSV of top changes.

### Unified Summary

Combine all analysis dimensions into a single ranked priority list:

```bash
./scripts/gz_summary.sh captures/ jetty
```

Produces a composite score (0-100) per function combining CPU time, cache hostility, off-CPU blocking, false sharing, and scheduler impact.

### Interactive Analysis with KDAB Hotspot

For deep interactive exploration with per-thread timelines, install [KDAB Hotspot](https://github.com/KDAB/hotspot):

```bash
sudo apt install hotspot
hotspot captures/runtime/perf_jetty.data
```

Click any thread in the timeline to filter all views (flamegraph, top-down, bottom-up) to that thread.

### Full Pipeline (end-to-end)

Run everything in one command — capture all worlds, analyze, and produce a ranked list of optimization targets:

```bash
# Full pipeline: capture + analyze + cross-world ranking
./scripts/gz_full_pipeline.sh worlds/

# Skip capture, analyze existing data
./scripts/gz_full_pipeline.sh worlds/ --skip-capture

# Full pipeline + publish to repository
./scripts/gz_full_pipeline.sh worlds/ --publish
```

The main output is `captures/summary/cross_world_summary.tsv` — a single ranked list showing each Gazebo function's composite score, how many worlds it affects, and multi-dimensional evidence.

For post-capture analysis only (no simulation needed):

```bash
# Analyze existing captures: hotspots + per-thread + cache comparison + cross-world merge
./scripts/gz_analyze.sh captures/
```

### Publishing a Run

Two options:

```bash
# Option A: One-shot (capture + analyze + publish in one command)
./scripts/gz_full_pipeline.sh worlds/ --publish
git add 2026-05-02/ && git commit -m "Add profiling run 2026-05-02" && git push

# Option B: Iterative (inspect results before publishing)
./scripts/gz_full_pipeline.sh worlds/
# ... inspect captures/summary/cross_world_summary.tsv, re-run if needed ...
./scripts/gz_publish_run.sh captures/
git add 2026-05-02/ && git commit -m "Add profiling run 2026-05-02" && git push
```

`gz_publish_run.sh` will:
- Create a `YYYY-MM-DD/` directory with `runtime/`, `loading/`, `cache/`, `c2c/`, `sched/`, `threads/`, `summary/`
- Copy `.svg`, `.folded`, `.tsv` files (skip large `perf_*.data` — those stay local)
- Run `gz_hotspots.sh` and `gz_summary.sh` on all worlds if not already done
- Generate `YYYY-MM-DD/index.html` with links to all flamegraphs and analysis reports
- Update the top-level `index.html` to include the new run

Options:
```bash
# Custom date
./scripts/gz_publish_run.sh captures/ --date 2026-05-02

# With description for the index page
./scripts/gz_publish_run.sh captures/ --description "After EachNoCache fix"
```

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `GZ_SIM_MAIN` | auto-detect from PATH | Path to `gz-sim-main` binary |
| `SKIP_PERF` | `0` | `1`: run the world without perf and only write the stats snapshot |
| `FLAMEGRAPH_DIR` | `./FlameGraph` | Path to Brendan Gregg's FlameGraph scripts |
| `OUTPUT_DIR` | `./captures/runtime` or `./captures/loading` | Where to write output files |
| `SCHED_THRESHOLD_MS` | `1.0` | Scheduler delay threshold for flagging threads (ms) |

## GUI Profiling

The scripts above profile the headless server (`gz-sim-main`). To profile the
**GUI** process (`gz-sim-gui-client`) instead, use the GUI-specific tools. A
server is launched to feed the GUI world state; `perf` attaches to the GUI
process only. See the [`2026-07-03/`](2026-07-03/) run for a full example
(GUI profiled on PR #3447 / EnTT ECM).

```bash
# Runtime: attach perf to the settled GUI process for 30s (server playing, gz sim -r)
./scripts/gz_gui_flamegraph.sh worlds/3k_shapes.sdf 3k_shapes_dynamic 30 runtime

# Loading: wrap the GUI launch (Qt init + render-engine init + initial scene build)
./scripts/gz_gui_flamegraph.sh worlds/jetty.sdf jetty 20 loading

# GUI-aware subsystem + hotspot breakdown (render pipeline, ECS sync, Qt, driver)
./scripts/gz_gui_analyze.sh captures_gui/runtime/3k_shapes_dynamic.folded

# Per-thread split (render thread vs Qt main vs transport)
FLAMEGRAPH_DIR=~/FlameGraph OUTPUT_DIR=captures_gui/threads \
  ./scripts/gz_per_thread_flamegraph.sh captures_gui/runtime/perf_3k_shapes_dynamic.data 3k_shapes_dynamic
```

Notes:

- All capture scripts (server and GUI) use `perf record -e task-clock` (not the
  default `cycles`) so hybrid P/E cores are sampled uniformly; the weights in the
  `.folded` files are therefore nanoseconds of CPU time, not sample counts.
- To render on NVIDIA via PRIME offload, export
  `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia` before capturing.
- The GUI spawns behind an `sh` launcher wrapper; the script selects the real GUI
  process by thread count.
- Output goes to `captures_gui/{runtime,loading,threads}/`.

## Output Files

| Extension | Description |
|---|---|
| `*.svg` | Interactive flamegraph. Open in a browser; click frames to zoom, Ctrl+F to search |
| `*.folded` | Collapsed stack traces (text). Input for `flamegraph.pl`, useful for CLI analysis |
| `*.tsv` | Machine-readable metrics (tab-separated). Input for `gz_summary.sh`, suitable for CI |
| `perf_*.data` | Raw perf binary capture. Can be re-analyzed with `perf report` or KDAB Hotspot |
| `*_wallclock.txt` | Wall-clock loading time from `time` command |

## Viewing Flamegraphs

Open any `.svg` file in a web browser for interactive exploration:
- **Click** any frame to zoom into that subtree
- **Ctrl+F** to search and highlight matching frames
- **Hover** over a frame for full function name and sample count
- Use `?s=<regex>` URL parameter to pre-highlight (e.g., `flamegraph.svg?s=ProcessRecreate|Write`)
