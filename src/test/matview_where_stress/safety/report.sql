SELECT ord, id, expect,
       max(verdict) FILTER (WHERE form='bare')         AS bare,
       max(verdict) FILTER (WHERE form='concurrently') AS conc,
       max(diffrows) AS diff,
       max(pushed) AS pushdown, max(leafrows) AS leaf, max(baserows) AS base
  FROM probe_result GROUP BY ord, id, expect ORDER BY ord;
