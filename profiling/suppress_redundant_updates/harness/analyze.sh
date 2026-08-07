#!/bin/bash
# Summarize folded stacks: self time per function, and inclusive cost of key frames.
OUT=/tmp/claude-0/-home-user-postgres/3270ba05-7bc8-5226-9a93-a3534b405d6f/scratchpad/results

summarize() {
  local f=$1 name=$2
  local total
  total=$(awk '{s+=$NF} END{print s}' "$f")
  echo "=================================================================="
  echo "== $name   (total samples: $total)"
  echo "=================================================================="

  echo "-- top 18 by SELF time:"
  awk -v tot="$total" '{
      n=split($1, parts, ";");
      leaf=parts[n];
      self[leaf]+=$NF
    }
    END{ for (k in self) printf "%7.2f%%  %s\n", 100*self[k]/tot, k }' "$f" \
    | sort -rn | head -18

  echo "-- inclusive cost of key frames:"
  for fn in ExecBRUpdateTriggers GetTupleForTrigger heap_lock_tuple \
            ExecCallTriggerFunc suppress_redundant_updates_trigger \
            ExecGetAllUpdatedCols bms_union heap_form_tuple \
            ExecFetchSlotHeapTuple tts_virtual_materialize \
            ExecModifyTable ExecUpdate heap_update \
            XLogInsert XLogInsertRecord ExecProcNode \
            ExecutorRun PortalRun pg_plan_queries pg_analyze_and_rewrite \
            exec_simple_query LockAcquire heap_prune_page_opt ; do
    awk -v tot="$total" -v pat=";$fn;|;$fn\$" '
      $1 ~ pat { s+=$NF }
      END{ if (s>0) printf "%7.2f%%  %s\n", 100*s/tot, "'"$fn"'" }' "$f"
  done
  echo
}

for f in "$OUT"/*.folded; do
  [ -s "$f" ] || continue
  summarize "$f" "$(basename "$f" .folded)"
done
