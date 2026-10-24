-- verify.sql — read-only structural check of the remarkable-bridge database
\pset pager off

SELECT n.nspname || '.' || c.relname AS relation,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view'
                      WHEN 'i' THEN 'index' WHEN 'p' THEN 'partitioned table' END AS kind
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('core','remarkable') AND c.relkind IN ('r','v','i')
ORDER BY 1;

SELECT n.nspname || '.' || p.proname AS function
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('core','remarkable')
ORDER BY 1;

SELECT schemaname || '.' || indexname AS index, indexdef
FROM pg_indexes
WHERE schemaname = 'remarkable'
ORDER BY 1;

SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname = 'rmbridge';
