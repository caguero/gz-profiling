# Gazebo Performance Profiling

CPU flamegraph benchmarks for [Gazebo](https://gazebosim.org). Interactive flamegraphs and reports are published at:

**https://caguero.github.io/gz-profiling-flamegraphs/**

## Repository Structure

```
scripts/                    # Reusable capture automation
  gz_flamegraph.sh          # Runtime capture (30s steady-state)
  gz_loading_flamegraph.sh  # Loading/startup capture (1 iteration)
  capture_all.sh            # Captures all worlds in a directory
worlds/                     # Benchmark world SDFs (all RTF=0)
  3k_shapes.sdf             # 3000 dynamic entities
  3k_shapes_static.sdf      # 3000 static entities
  sensors.sdf               # Non-rendering sensors (IMU, mag, etc.)
  jetty.sdf                 # Complex real-world scene
  gpu_lidar_sensor.sdf      # GPU lidar rendering
  gpu_lidar_sensor.topics   # Sensor topics for subscriber
  sensors_demo.sdf          # 6 rendering sensors
  sensors_demo.topics       # Sensor topics for subscriber
2026-04-21/                 # Benchmark run results
  runtime/*.svg             # Interactive runtime flamegraphs
  loading/*.svg             # Interactive loading flamegraphs
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

## Build Configuration

Build your Gazebo workspace with debug symbols and frame pointers. Use `ENABLE_PROFILER=OFF` for clean flamegraph captures (discovery phase). Use `ENABLE_PROFILER=ON` for before/after optimization validation with Remotery.

```bash
cd ~/your_ws
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
source ~/your_ws/install/setup.bash
export GZ_CONFIG_PATH=~/your_ws/install/share/gz:$GZ_CONFIG_PATH
export GZ_SIM_MAIN=~/your_ws/install/libexec/gz/sim/gz-sim-main
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

# Use your own worlds
./scripts/capture_all.sh /path/to/my/worlds/
```

Output goes to `captures/runtime/` and `captures/loading/` under the current working directory.

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

### Custom Worlds

To add a new benchmark world:

1. Copy the SDF to your worlds directory
2. Set `<real_time_factor>0</real_time_factor>` in the `<physics>` element to run at maximum speed
3. If it has rendering sensors, create a `.topics` companion file
4. Run `capture_all.sh` pointing to your directory

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `GZ_SIM_MAIN` | auto-detect from PATH | Path to `gz-sim-main` binary |
| `FLAMEGRAPH_DIR` | `./FlameGraph` | Path to Brendan Gregg's FlameGraph scripts |
| `OUTPUT_DIR` | `./captures/runtime` or `./captures/loading` | Where to write output files |

## Output Files

| Extension | Description |
|---|---|
| `*.svg` | Interactive flamegraph. Open in a browser; click frames to zoom, Ctrl+F to search |
| `*.folded` | Collapsed stack traces (text). Input for `flamegraph.pl`, useful for CLI analysis |
| `perf_*.data` | Raw perf binary capture. Can be re-analyzed with `perf report` |
| `*_wallclock.txt` | Wall-clock loading time from `time` command |

## Viewing Flamegraphs

Open any `.svg` file in a web browser for interactive exploration:
- **Click** any frame to zoom into that subtree
- **Ctrl+F** to search and highlight matching frames
- **Hover** over a frame for full function name and sample count
- Use `?s=<regex>` URL parameter to pre-highlight (e.g., `flamegraph.svg?s=ProcessRecreate|Write`)
