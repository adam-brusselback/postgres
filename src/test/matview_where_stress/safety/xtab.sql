SELECT pushed AS "planner push-down", verdict AS "measured", count(*),
       string_agg(id, ', ' ORDER BY ord) AS cases
  FROM probe_result WHERE form='bare' GROUP BY 1,2 ORDER BY 1,2;
