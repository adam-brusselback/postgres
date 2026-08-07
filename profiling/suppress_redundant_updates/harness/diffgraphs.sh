#!/bin/bash
# Differential flamegraphs: what does adding the trigger change?
# Red = more time with the trigger, blue = less.
BASE=/tmp/claude-0/-home-user-postgres/3270ba05-7bc8-5226-9a93-a3534b405d6f/scratchpad
FG=$BASE/FlameGraph
OUT=$BASE/results

mkdir -p "$OUT/diff"

mkdiff() {
  local notrig=$1 trig=$2 label=$3
  [ -s "$OUT/$notrig.folded" ] && [ -s "$OUT/$trig.folded" ] || { echo "skip $label (missing input)"; return; }
  # normalize sample counts so the two runs are comparable (-n)
  "$FG/difffolded.pl" -n "$OUT/$notrig.folded" "$OUT/$trig.folded" \
    | "$FG/flamegraph.pl" --title "$label (red = added by trigger)" --width 1400 \
    > "$OUT/diff/$label.svg" 2>/dev/null
  echo "  wrote diff/$label.svg"
}

mkdiff narrow_notrig_redundant      narrow_trig_redundant      narrow_redundant_simple
mkdiff narrow_notrig_changing       narrow_trig_changing       narrow_changing_simple
mkdiff wide_notrig_redundant        wide_trig_redundant        wide_redundant_simple
mkdiff wide_notrig_changing         wide_trig_changing         wide_changing_simple
mkdiff narrow_notrig_redundant_prep narrow_trig_redundant_prep narrow_redundant_prepared
mkdiff narrow_notrig_changing_prep  narrow_trig_changing_prep  narrow_changing_prepared
mkdiff wide_notrig_redundant_prep   wide_trig_redundant_prep   wide_redundant_prepared
mkdiff idx_notrig_redundant_prep    idx_trig_redundant_prep    idx_redundant_prepared
mkdiff idx_notrig_changing_prep     idx_trig_changing_prep     idx_changing_prepared
echo "diff graphs done"
