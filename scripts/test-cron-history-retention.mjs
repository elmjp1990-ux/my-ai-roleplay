import assert from 'node:assert/strict';
import fs from 'node:fs';

const migrationPath = 'supabase/migrations/20261113040000_retain_cron_job_history_seven_days.sql';
const sql = fs.readFileSync(migrationPath, 'utf8');

assert.match(sql, /to_regclass\('cron\.job'\)/);
assert.match(sql, /to_regclass\('cron\.job_run_details'\)/);
assert.match(sql, /to_regprocedure\('cron\.schedule\(text,text,text\)'\)/);
assert.match(sql, /jobname = 'poyozz-cron-history-retention'/);
assert.match(sql, /PERFORM cron\.unschedule\(v_job_id\)/);
assert.match(sql, /PERFORM cron\.schedule\(/);
assert.match(sql, /'17 3 \* \* \*'/);
assert.match(sql, /DELETE FROM cron\.job_run_details/);
assert.match(sql, /end_time < clock_timestamp\(\) - interval '7 days'/);

// The maintenance task must not alter application data, job definitions,
// Storage objects, or use a table rewrite/locking VACUUM FULL.
assert.doesNotMatch(sql, /DELETE FROM public\./i);
assert.doesNotMatch(sql, /TRUNCATE\s/i);
assert.doesNotMatch(sql, /DROP\s+TABLE/i);
assert.doesNotMatch(sql, /VACUUM\s+FULL/i);
assert.doesNotMatch(sql, /UPDATE\s+cron\.job\b/i);

console.log('Cron history retention contract passed (7-day retention, named-job replacement, cron metadata only).');
