#!/usr/bin/env bash
# moving_robots_and_sensors.setup.sh — drive the robots after the world is loaded.
#
# Mirrors what BM_MobileRobot in gz-sim's test/benchmark/server_run.cc does:
# one Twist to each vehicle (diff drive and Ackermann keep the last command)
# and one 1000 point JointTrajectory to the RR_position_control arm.
# gz_flamegraph.sh runs this automatically after the startup wait.

set -eo pipefail

TWIST='linear { x: 1.0 } angular { z: 0.2 }'
gz topic -t /model/vehicle_1/cmd_vel -m gz.msgs.Twist -p "$TWIST"
gz topic -t /model/vehicle_2/cmd_vel -m gz.msgs.Twist -p "$TWIST"

TRAJ=$(python3 - <<'PY'
import math
lines = ['joint_names: "RR_position_control_joint1"',
         'joint_names: "RR_position_control_joint2"']
for i in range(1, 1001):
    t = i * 0.5
    sec = int(t)
    nsec = int((t - sec) * 1e9)
    lines.append('points { time_from_start { sec: %d nsec: %d } '
                 'positions: %.6f positions: %.6f }'
                 % (sec, nsec, math.sin(t), math.cos(t)))
print("\n".join(lines))
PY
)
gz topic -t /model/RR_position_control/joint_trajectory \
    -m gz.msgs.JointTrajectory -p "$TRAJ"
