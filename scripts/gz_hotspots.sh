#!/usr/bin/env bash
# gz_hotspots.sh — Extract Gazebo-owned hotspots from a flamegraph .folded file
#
# Usage: ./gz_hotspots.sh <file.folded> [top_n]
#
# Analyzes a collapsed stack file and reports:
#   1. Top Gazebo-owned functions by self-time (leaf functions in gz:: namespace)
#   2. Top Gazebo-owned functions by inclusive time (anywhere in the stack)
#   3. Top external functions for context
#   4. Gazebo callers of hot external functions (attribution)
#
# Gazebo-owned: functions matching gz::sim::, gz::physics::, gz::rendering::,
# gz::common::, gz::math::, gz::transport::, gz::plugin::, gz::msgs::,
# SimulationRunner, SimulationFeatures, SceneBroadcaster, SceneManager,
# RenderUtil, BaseView, Barrier, stbi_* (vendored in gz-common),
# Image:: (gz::common::Image)

set +o pipefail

FOLDED="${1:?Usage: $0 <file.folded> [top_n]}"
TOP_N="${2:-15}"

if [[ ! -f "$FOLDED" ]]; then
    echo "ERROR: File not found: $FOLDED" >&2
    exit 1
fi

TOTAL=$(awk '{s+=$NF} END {print s}' "$FOLDED")
LABEL=$(basename "$FOLDED" .folded)

# Gazebo namespace pattern (regex for matching leaf functions)
# Uses gz:: prefix as primary match. Additional patterns for vendored/wrapped code.
# Excludes gz::physics::ForwardStep::World (thin C++ template wrapper around DART).
GZ_PATTERN='gz::sim::|gz::physics::dartsim::|gz::rendering::|gz::common::|gz::math::|gz::transport::|gz::plugin::|gz::msgs::|gz::sensors::|SimulationRunner::|SimulationFeatures::|gz::sim::v11::systems::|gz::sim::v11::detail::|gz::sim::v11::Entity|stbi__|gz::common::Image|SdfModelSerializer|ServerPrivate::DownloadAssets|ServerPrivate::LoadSdfRoot|pybind11::initialize'

# External pattern (things we know are NOT Gazebo)
# External pattern: third-party libraries + C++ stdlib containers + demangling noise
# Also includes gz::physics template wrappers (ForwardStep::World, SpecifyData, ExpectData)
# that are thin delegation layers, not actionable Gazebo code.
EXT_PATTERN='dart::|dxHash|dxGeom|dxSafe|dxSpace|dxSphere|dxCylinder|dGeom|dRfromQ|Ogre::|libnvidia|\[libdart|\[unknown\]|pthread_|_int_free|_int_malloc|malloc_consolidate|cfree|__memset|__memmove|__memcpy|clone3|start_thread|\[\[vdso\]\]|\[libstdc\+\+|BoxedLcp|ConstraintSolver|ConstrainedGroup|BodyNode::|Frame::get|DegreeOfFreedom::|Skeleton::|CollisionGroup::|CollisionObject::|ContactConstraint|OdeCollisionDetector|BulletCollisionDetector|ForwardStep::World|gz::physics::SpecifyData|gz::physics::ExpectData|gz::physics::CompositeData|gz::physics::FrameSemantics|std::_Hashtable|std::_Rb_tree|std::__detail|std::__cxx11|std::pair<std::|std::set<unsigned|std::unordered|std::vector|std::atomic|std::function|std::chrono|std::enable_if|std::_Optional|std::_Sp_counted|operator new|operator delete|Eigen::|sdf::v|tinyxml2::|google::protobuf|zmq_|__GI_|__poll|__tls_get|__scalbn|futex|lll_mutex|unlink_chunk'

echo "============================================"
echo "  Gazebo Hotspot Analysis: $LABEL"
echo "============================================"
echo "  Total samples: $TOTAL"
echo ""

# ---------------------------------------------------------------
# 1. Gazebo-owned functions by SELF-TIME (leaf)
# ---------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  1. Gazebo-owned functions (self-time)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Functions in gz:: namespaces ranked by time spent in the function"
echo "  itself (not its children). These are the direct CPU consumers —"
echo "  the code where the CPU is actually executing."
echo ""

awk '{ n=split($1,a,";"); printf "%s\t%d\n", a[n], $NF }' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | grep -E "$GZ_PATTERN" \
    | sort -rn \
    | head -"$TOP_N" \
    | awk -F'\t' -v total="$TOTAL" '{
        pct = $1 * 100.0 / total;
        printf "%6.1f%%  %s\n", pct, $2
    }'

echo ""

# ---------------------------------------------------------------
# 2. Gazebo-owned functions by INCLUSIVE TIME (anywhere in stack)
# ---------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  2. Gazebo-owned functions (inclusive time)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Functions ranked by total time spent in the function AND all its"
echo "  children. High inclusive time means the function is responsible for"
echo "  a large call subtree. Useful for identifying which high-level"
echo "  Gazebo function 'owns' the most CPU."
echo ""

# For each stack, find all unique gz:: functions and attribute the full sample to each
awk '{
    n = split($1, a, ";")
    samples = $NF
    seen_func = ""
    for (i = 1; i <= n; i++) {
        func = a[i]
        # Deduplicate within same stack
        if (index(seen_func, "|" func "|") > 0) continue
        seen_func = seen_func "|" func "|"
        printf "%s\t%d\n", func, samples
    }
}' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | grep -E "$GZ_PATTERN" \
    | grep -v -E '^[0-9]+\tgz-sim-main$' \
    | sort -rn \
    | head -"$TOP_N" \
    | awk -F'\t' -v total="$TOTAL" '{
        pct = $1 * 100.0 / total;
        printf "%6.1f%%  %s\n", pct, $2
    }'

echo ""

# ---------------------------------------------------------------
# 3. External functions for context (self-time)
# ---------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  3. External functions (context, self-time)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Functions in third-party libraries (DART, ODE, Ogre, glibc, etc.)"
echo "  ranked by self-time. Not directly actionable in Gazebo code, but"
echo "  provides context. See section 4 for which Gazebo code triggers them."
echo ""

awk '{ n=split($1,a,";"); printf "%s\t%d\n", a[n], $NF }' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | grep -E "$EXT_PATTERN" \
    | sort -rn \
    | head -"$TOP_N" \
    | awk -F'\t' -v total="$TOTAL" '{
        pct = $1 * 100.0 / total;
        printf "%6.1f%%  %s\n", pct, $2
    }'

echo ""

# ---------------------------------------------------------------
# 4. Attribution: nearest Gazebo caller of hot external functions
# ---------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  4. Attribution: Gazebo callers of external hotspots"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Maps each external hotspot to the nearest Gazebo function that"
echo "  called it (format: GazeboFunc -> ExternalFunc). Answers the"
echo "  question: 'which Gazebo code is responsible for this external cost?'"
echo ""

# For each stack, find the leaf (external), then walk up to find the nearest gz:: caller
awk -v gz_pat="$GZ_PATTERN" '{
    n = split($1, a, ";")
    samples = $NF
    leaf = a[n]

    # Find nearest gz:: ancestor
    gz_caller = ""
    for (i = n; i >= 1; i--) {
        if (match(a[i], /gz::sim::|gz::physics::dartsim::|gz::rendering::|gz::common::|gz::transport::|SimulationRunner::|SimulationFeatures::|ServerPrivate::/)) {
            gz_caller = a[i]
            break
        }
    }

    if (gz_caller != "" && gz_caller != leaf) {
        printf "%s → %s\t%d\n", gz_caller, leaf, samples
    }
}' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | sort -rn \
    | head -"$TOP_N" \
    | awk -F'\t' -v total="$TOTAL" '{
        pct = $1 * 100.0 / total;
        printf "%6.1f%%  %s\n", pct, $2
    }'

echo ""
echo "============================================"
echo "  Summary"
echo "============================================"

# Calculate totals using awk to handle demangling artifacts (void, operator, unsigned, bool)
# that grep patterns can't reliably match as standalone words.
awk '{ n=split($1,a,";"); printf "%s\t%d\n", a[n], $NF }' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | awk -F'\t' -v total="$TOTAL" -v gz_pat="$GZ_PATTERN" -v ext_pat="$EXT_PATTERN" '
    BEGIN { gz=0; ext=0; other=0 }
    {
        samples = $1
        func = $2
        # Demangling artifacts — classify as external/noise
        if (func == "void" || func == "operator" || func == "unsigned" || func == "bool" || func == "non-virtual" || func == "virtual") {
            ext += samples
        } else if (match(func, gz_pat)) {
            gz += samples
        } else if (match(func, ext_pat)) {
            ext += samples
        } else {
            other += samples
        }
    }
    END {
        printf "\n"
        printf "  Gazebo-owned:  %6.1f%%\n", gz * 100.0 / total
        printf "  External libs: %6.1f%%\n", ext * 100.0 / total
        printf "  Other/noise:   %6.1f%%\n", other * 100.0 / total
    }'
