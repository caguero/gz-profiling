#!/usr/bin/env bash
# gz_gui_analyze.sh — GUI-aware hotspot + subsystem breakdown for a .folded file.
#
# Unlike gz_hotspots.sh (server-centric: physics/ECS), this categorises CPU by
# the subsystems that matter for the GUI process: the Ogre render pipeline
# (scene-graph traversal, forward+ lighting, culling), the gz-rendering scene
# store, the GPU/Mesa driver, Qt, and Gazebo-owned GUI code (RenderUtil,
# SceneManager, ECM state sync, GuiRunner).
#
# Correct folded parsing: the trailing integer is the sample weight; the stack
# is everything before it; frames are ';'-separated but C++ symbol names may
# themselves contain spaces, so we must NOT split on the first space.
#
# Usage: ./gz_gui_analyze.sh <file.folded> [top_n]

set +o pipefail
FOLDED="${1:?Usage: $0 <file.folded> [top_n]}"
TOP_N="${2:-25}"
[ -f "$FOLDED" ] || { echo "ERROR: not found: $FOLDED" >&2; exit 1; }
TOTAL=$(awk '{s+=$NF} END{print s}' "$FOLDED")
LABEL=$(basename "$FOLDED" .folded)

echo "================================================================"
echo "  GUI analysis: $LABEL   (total weight: $TOTAL)"
echo "================================================================"

AWK_COMMON='
function leafof(line,   stack, a, n) {
  stack = line
  sub(/ +[0-9]+$/, "", stack)      # strip trailing " <count>"
  n = split(stack, a, ";")
  return a[n]                        # full leaf, spaces preserved
}
function norm(s) {                   # clean name for display/grouping
  sub(/\+0x[0-9a-fA-F]+.*/, "", s)   # drop +offset and module
  sub(/ \(\/.*/, "", s)              # drop " (/path/lib.so)"
  gsub(/<[^<>]*>/, "", s); gsub(/<[^<>]*>/, "", s); gsub(/<[^<>]*>/, "", s)  # strip <templates>
  sub(/\(.*/, "", s)                 # drop argument list
  sub(/^(void|virtual|bool|int|unsigned|long|double|float|char|auto|static|const) +/, "", s)
  gsub(/^ +| +$/, "", s)
  return s
}
function categorize(leaf,   L) {
  L = leaf
  if (L ~ /gz::rendering|Ogre2Node|Ogre2Scene|BaseVisual|BaseStore|BaseNode|BaseScene|BaseCamera|BaseGeometry|BaseMaterial/) return "gz-rendering: scene store/PreRender"
  if (L ~ /gz::sim.*RenderUtil|gz::sim.*SceneManager|NodeById|MarkerManager/)            return "gz-sim: RenderUtil/SceneManager"
  if (L ~ /gz::sim.*EntityComponentManager|SetState|SerializedState|gz::sim.*GuiRunner|GzSceneManager/) return "gz-sim: ECM state sync"
  if (L ~ /gz::gui|MinimalScene|GzRenderer|RenderThread/)                                return "gz-gui: render loop"
  if (L ~ /gz::transport|zmq|libzmq|Zenoh|Discovery/)                                    return "gz-transport"
  if (L ~ /ForwardClustered|collectLight|LightForSlice/)                                 return "Ogre: forward+ lighting"
  if (L ~ /Frustum|isViewOutOfDate|cullFrustum|_makeRsProj|calcProjection|Camera::.*[Vv]iew/) return "Ogre: culling/frustum"
  if (L ~ /Ogre::Node|_getDerived|updateFromParent|convertLocalToWorld|_updateFromParent|Matrix4|Quaternion/) return "Ogre: scene-graph transforms"
  if (L ~ /Ogre::|OgreNext|libOgreNextMain/)                                             return "Ogre: other render"
  if (L ~ /libgallium|libnvidia|iris_|brw_|intel_|i965|radeonsi|libvulkan|libGLX|libEGL|libdrm/) return "GPU driver (Mesa/Intel)"
  if (L ~ /QSG|QQuick|libQt6Quick/)                                                      return "Qt Quick scene-graph"
  if (L ~ /libQt6|QMetaObject|QObject|QCoreApplication|QGuiApplication|QWindow|QOpenGL|QString/) return "Qt (core/gui)"
  if (L ~ /_int_malloc|_int_free|[^a-z]malloc|[^a-z]free|memcpy|memmove|memset|operator new|tcmalloc|_Sp_counted|__shared|exchange_and_add|atomic_add/) return "C++ alloc/refcount/memops"
  if (L ~ /poll|futex|pthread|__sched|nanosleep|clock_gettime|vdso|libc.so/)             return "kernel/sync/idle"
  if (L ~ /\[unknown\]/)                                                                 return "[unknown]"
  return "other"
}
'

# --- 1. Subsystem rollup -----------------------------------------------------
echo ""
echo "-- 1. CPU by subsystem (leaf-frame classification) --"
awk "$AWK_COMMON"'{ s[categorize(leafof($0))] += $NF } END { for (c in s) printf "%d\t%s\n", s[c], c }' "$FOLDED" \
| sort -rn | awk -F'\t' -v total="$TOTAL" '{printf "  %6.1f%%  %s\n", $1*100/total, $2}'

# --- 2. Top self-time leaves (normalised names) ------------------------------
echo ""
echo "-- 2. Top $TOP_N self-time leaves --"
awk "$AWK_COMMON"'{ s[norm(leafof($0))] += $NF } END { for (k in s) printf "%d\t%s\n", s[k], k }' "$FOLDED" \
| sort -rn | head -"$TOP_N" \
| awk -F'\t' -v total="$TOTAL" '{printf "  %6.2f%%  %s\n", $1*100/total, ($2==""?"(anon)":$2)}'

# --- 3. Gazebo-owned inclusive hotspots (optimization targets) ---------------
echo ""
echo "-- 3. Gazebo-owned functions by inclusive time (optimizable) --"
GZ='gz::sim::v11::RenderUtil|gz::sim::v11::SceneManager|gz::sim::v11::MarkerManager|gz::sim::v11::GuiRunner|gz::sim::v11::EntityComponentManager|gz::sim::v11::GzSceneManager|gz::gui::v[0-9]*::plugins|gz::gui::.*RenderThread|gz::gui::.*GzRenderer|gz::gui::.*MinimalScene|gz::rendering::v11'
awk "$AWK_COMMON"'{
  stack=$0; sub(/ +[0-9]+$/,"",stack); w=$NF; n=split(stack,a,";"); seen=""
  for(i=1;i<=n;i++){f=norm(a[i]); if(f=="")continue; if(index(seen,"|"f"|")>0) continue; seen=seen"|"f"|"; printf "%s\t%d\n",f,w}
}' "$FOLDED" \
| awk -F'\t' '{s[$1]+=$2} END{for(k in s) printf "%d\t%s\n",s[k],k}' \
| grep -E "$GZ" | grep -vE 'runGui|::exec$' \
| sort -rn | head -"$TOP_N" \
| awk -F'\t' -v total="$TOTAL" '{printf "  %6.2f%%  %s\n", $1*100/total, $2}'
