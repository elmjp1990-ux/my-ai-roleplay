-- DRAFT / READ-ONLY AUDIT — Encounter lifecycle trigger attachment & ACL
-- Run only against a disposable local DB or a read-only connection.
-- This file performs catalog SELECTs only; it does not modify schema or data.
--
-- Purpose: replacing a trigger function body is ineffective if the expected
-- trigger is absent/disabled or attached to a different relation. Confirm the
-- real attachment before promoting lifecycle guard drafts to migrations.

-- 1) Show every non-internal trigger on the lifecycle/evidence tables, including
--    disabled state, event definition, and the exact attached function.
SELECT
  n.nspname AS table_schema,
  c.relname AS table_name,
  t.tgname AS trigger_name,
  t.tgenabled AS enabled_state, -- O=origin, D=disabled, R=replica, A=always
  pg_get_triggerdef(t.oid, true) AS trigger_definition,
  pn.nspname AS function_schema,
  p.proname AS function_name,
  p.oid::regprocedure AS function_signature,
  p.prosecdef AS security_definer,
  p.proconfig AS function_settings
FROM pg_trigger AS t
JOIN pg_class AS c ON c.oid = t.tgrelid
JOIN pg_namespace AS n ON n.oid = c.relnamespace
JOIN pg_proc AS p ON p.oid = t.tgfoid
JOIN pg_namespace AS pn ON pn.oid = p.pronamespace
WHERE NOT t.tgisinternal
  AND n.nspname = 'public'
  AND c.relname IN (
    'encounter_session_lifecycle',
    'encounter_session_turns',
    'encounter_evaluation_jobs',
    'story_relationship_states',
    'story_relationship_batches'
  )
ORDER BY c.relname, t.tgname;

-- 2) Show whether the intended validator functions exist and which triggers
--    actually reference them. A function existing without an attached trigger
--    does not enforce anything.
SELECT
  p.oid::regprocedure AS function_signature,
  p.prosecdef AS security_definer,
  p.proconfig AS function_settings,
  COALESCE(
    array_agg(format('%I.%I:%I [%s]', n.nspname, c.relname, t.tgname, t.tgenabled))
      FILTER (WHERE t.oid IS NOT NULL),
    ARRAY[]::text[]
  ) AS attached_triggers
FROM pg_proc AS p
JOIN pg_namespace AS pn ON pn.oid = p.pronamespace
LEFT JOIN pg_trigger AS t ON t.tgfoid = p.oid AND NOT t.tgisinternal
LEFT JOIN pg_class AS c ON c.oid = t.tgrelid
LEFT JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE pn.nspname = 'public'
  AND p.proname IN (
    'validate_affinity_session_link',
    'validate_encounter_evaluation_job_link'
  )
GROUP BY p.oid, p.prosecdef, p.proconfig
ORDER BY p.oid::regprocedure::text;

-- 3) Verify EXECUTE ACLs on privileged lifecycle entry points and report owner.
--    The output includes inherited PUBLIC grants as well as explicit ACLs.
SELECT
  p.oid::regprocedure AS function_signature,
  pg_get_userbyid(p.proowner) AS function_owner,
  p.prosecdef AS security_definer,
  p.proconfig AS function_settings,
  acl.grantee,
  CASE WHEN acl.grantee = 0 THEN 'PUBLIC'
       ELSE pg_get_userbyid(acl.grantee) END AS grantee_name,
  acl.privilege_type,
  acl.is_grantable
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
WHERE n.nspname = 'public'
  AND p.proname IN (
    'set_encounter_session_lifecycle_state',
    'settle_encounter_session',
    'validate_affinity_session_link',
    'validate_encounter_evaluation_job_link'
  )
ORDER BY p.oid::regprocedure::text, acl.grantee;
