#!/bin/bash
# Consolidated report tables: cost attribution normalized to in-query CPU.
BASE=/tmp/claude-0/-home-user-postgres/3270ba05-7bc8-5226-9a93-a3534b405d6f/scratchpad
OUT=$BASE/results

# in-query CPU = samples under exec_simple_query (simple) or PostgresMain-driven
# execution (prepared uses exec_bind_message/exec_execute_message)
inquery() {
  awk '$1 ~ /;exec_simple_query;|;exec_execute_message;|;exec_bind_message;|;exec_parse_message;/ {s+=$NF} END{print s+0}' "$1"
}

incl() { # file, total, fn
  awk -v tot="$2" -v pat=";$3;|;$3\$" '$1 ~ pat {s+=$NF} END{ if (tot>0) printf "%.2f", 100*s/tot; else printf "0" }' "$1"
}

echo "############ COST ATTRIBUTION (% of in-query backend CPU) ############"
printf "%-32s %8s %8s %8s %8s %8s %8s %8s\n" \
  workload ExecMT BRUpdTrg GetTupTrg heapLock trgFunc AllUpdCols heapUpd

for n in narrow_notrig_redundant narrow_trig_redundant \
         narrow_notrig_changing narrow_trig_changing \
         wide_notrig_redundant wide_trig_redundant \
         wide_notrig_changing wide_trig_changing \
         narrow_notrig_redundant_prep narrow_trig_redundant_prep \
         narrow_notrig_changing_prep narrow_trig_changing_prep \
         wide_notrig_redundant_prep wide_trig_redundant_prep \
         idx_notrig_redundant_prep idx_trig_redundant_prep \
         idx_notrig_changing_prep idx_trig_changing_prep ; do
  f=$OUT/$n.folded
  [ -s "$f" ] || continue
  q=$(inquery "$f")
  [ "$q" -gt 0 ] 2>/dev/null || continue
  printf "%-32s %8s %8s %8s %8s %8s %8s %8s\n" "$n" \
    "$(incl "$f" "$q" ExecModifyTable)" \
    "$(incl "$f" "$q" ExecBRUpdateTriggers)" \
    "$(incl "$f" "$q" GetTupleForTrigger)" \
    "$(incl "$f" "$q" heap_lock_tuple)" \
    "$(incl "$f" "$q" suppress_redundant_updates_trigger)" \
    "$(incl "$f" "$q" ExecGetAllUpdatedCols)" \
    "$(incl "$f" "$q" heap_update)"
done

echo
echo "############ TRIGGER OVERHEAD BREAKDOWN (share of ExecBRUpdateTriggers) ############"
for n in narrow_trig_redundant wide_trig_redundant narrow_trig_redundant_prep \
         wide_trig_redundant_prep idx_trig_redundant_prep narrow_trig_changing_prep \
         idx_trig_changing_prep; do
  f=$OUT/$n.folded; [ -s "$f" ] || continue
  br=$(awk '$1 ~ /;ExecBRUpdateTriggers;/ {s+=$NF} END{print s+0}' "$f")
  [ "$br" -gt 0 ] 2>/dev/null || continue
  echo "-- $n (ExecBRUpdateTriggers = 100%)"
  for fn in GetTupleForTrigger heap_lock_tuple ExecCallTriggerFunc \
            suppress_redundant_updates_trigger ExecGetAllUpdatedCols ExecFetchSlotHeapTuple; do
    printf "     %6s%%  %s\n" "$(incl "$f" "$br" "$fn")" "$fn"
  done
done

echo
echo "############ THROUGHPUT ############"
if [ -s "$OUT/tps_clean.txt" ]; then
  echo "-- phase 3 (clean, VACUUM FULL between reps, median of 3, prepared):"
  awk '{printf "  %-28s %10.1f\n",$1,$2}' "$OUT/tps_clean.txt"
  awk '{v[$1]=$2} END{
    print "";
    printf "  %-28s %10s %10s %9s\n","comparison","notrig","trig","delta";
    split("narrow_redundant narrow_changing wide_redundant wide_changing idx_redundant idx_changing", k, " ");
    for(i in k){
      split(k[i], p, "_"); base=p[1]; kind=p[2];
      a=v[base "_notrig_" kind]; b=v[base "_trig_" kind];
      if(a>0 && b>0) printf "  %-28s %10.1f %10.1f %+8.1f%%\n", k[i], a, b, 100*(b-a)/a;
    }
  }' "$OUT/tps_clean.txt"
fi
echo
echo "-- phase 1/2 (single run, profiled):"
[ -s "$OUT/tps_summary.txt" ] && awk '{printf "  %-32s %10.1f\n",$1,$2}' "$OUT/tps_summary.txt"
