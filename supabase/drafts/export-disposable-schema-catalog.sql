-- READ-ONLY CATALOG EXPORT — DISPOSABLE TEST FIXTURE INPUT ONLY.
-- This script exports schema metadata and definitions; it never reads application table rows.
-- Run against a source database with a client that can save the single JSON result.
-- Do NOT apply the result to the connected hosted database and do NOT put it in supabase/migrations/.

BEGIN TRANSACTION READ ONLY;

SELECT jsonb_pretty(jsonb_build_object(
  'capture', jsonb_build_object(
    'captured_at', pg_catalog.statement_timestamp(),
    'database', current_database(),
    'server_version', current_setting('server_version'),
    'scope', jsonb_build_array('public', 'private'),
    'purpose', 'current-state schema-only disposable fixture; not historical migration provenance'
  ),
  'relations', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'name', c.relname, 'kind', c.relkind,
      'owner', pg_catalog.pg_get_userbyid(c.relowner), 'acl', c.relacl::text,
      'rls_enabled', c.relrowsecurity, 'force_rls', c.relforcerowsecurity,
      'replica_identity', c.relreplident, 'persistence', c.relpersistence,
      'options', c.reloptions, 'comment', pg_catalog.obj_description(c.oid, 'pg_class')
    ) ORDER BY n.nspname, c.relname), '[]'::jsonb)
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'private')
      AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
  ),
  'columns', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'table', c.relname, 'ordinal', a.attnum,
      'name', a.attname, 'type', pg_catalog.format_type(a.atttypid, a.atttypmod),
      'not_null', a.attnotnull, 'default', pg_catalog.pg_get_expr(ad.adbin, ad.adrelid),
      'identity', a.attidentity, 'generated', a.attgenerated,
      'collation', CASE WHEN a.attcollation <> t.typcollation THEN a.attcollation::regcollation::text END,
      'comment', pg_catalog.col_description(c.oid, a.attnum)
    ) ORDER BY n.nspname, c.relname, a.attnum), '[]'::jsonb)
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
    LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = c.oid AND ad.adnum = a.attnum
    WHERE n.nspname IN ('public', 'private') AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  ),
  'constraints', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'table', c.conrelid::regclass::text, 'name', c.conname, 'type', c.contype,
      'definition', pg_catalog.pg_get_constraintdef(c.oid, true),
      'validated', c.convalidated, 'deferrable', c.condeferrable,
      'initially_deferred', c.condeferred
    ) ORDER BY c.conrelid::regclass::text, c.conname), '[]'::jsonb)
    FROM pg_catalog.pg_constraint c
    JOIN pg_catalog.pg_class r ON r.oid = c.conrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname IN ('public', 'private')
  ),
  'indexes', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'table', i.indrelid::regclass::text, 'name', ci.relname,
      'definition', pg_catalog.pg_get_indexdef(i.indexrelid),
      'valid', i.indisvalid, 'ready', i.indisready
    ) ORDER BY i.indrelid::regclass::text, ci.relname), '[]'::jsonb)
    FROM pg_catalog.pg_index i
    JOIN pg_catalog.pg_class ci ON ci.oid = i.indexrelid
    JOIN pg_catalog.pg_class t ON t.oid = i.indrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname IN ('public', 'private')
  ),
  'relation_privileges', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'relation', n.nspname || '.' || c.relname,
      'grantee', CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE gr.rolname END,
      'privilege', x.privilege_type, 'grantable', x.is_grantable
    ) ORDER BY n.nspname, c.relname, x.grantee, x.privilege_type), '[]'::jsonb)
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(c.relacl,
      pg_catalog.acldefault(CASE WHEN c.relkind = 'S' THEN 'S' ELSE 'r' END, c.relowner))) x
    LEFT JOIN pg_catalog.pg_roles gr ON gr.oid = x.grantee
    WHERE n.nspname IN ('public', 'private') AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
  ),
  'column_acl', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'table', n.nspname || '.' || c.relname, 'column', a.attname,
      'grantee', CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE gr.rolname END,
      'privilege', x.privilege_type, 'grantable', x.is_grantable
    ) ORDER BY n.nspname, c.relname, a.attnum, x.grantee, x.privilege_type), '[]'::jsonb)
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(a.attacl) x
    LEFT JOIN pg_catalog.pg_roles gr ON gr.oid = x.grantee
    WHERE n.nspname IN ('public', 'private') AND a.attnum > 0 AND NOT a.attisdropped
      AND a.attacl IS NOT NULL
  ),
  'policies', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'table', schemaname || '.' || tablename, 'name', policyname,
      'permissive', permissive, 'roles', roles, 'command', cmd,
      'using', qual, 'with_check', with_check
    ) ORDER BY schemaname, tablename, policyname), '[]'::jsonb)
    FROM pg_catalog.pg_policies WHERE schemaname IN ('public', 'private')
  ),
  'triggers', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'table', n.nspname || '.' || c.relname, 'name', t.tgname,
      'enabled', t.tgenabled, 'definition', pg_catalog.pg_get_triggerdef(t.oid, true)
    ) ORDER BY n.nspname, c.relname, t.tgname), '[]'::jsonb)
    FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'private') AND NOT t.tgisinternal
  ),
  'routines', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'name', p.proname,
      'identity_arguments', pg_catalog.pg_get_function_identity_arguments(p.oid),
      'kind', p.prokind, 'language', l.lanname, 'owner', pg_catalog.pg_get_userbyid(p.proowner),
      'security_definer', p.prosecdef, 'volatility', p.provolatile,
      'strict', p.proisstrict, 'returns_set', p.proretset,
      'config', p.proconfig, 'acl', p.proacl::text,
      'privileges', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'grantee', CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE gr.rolname END,
        'privilege', x.privilege_type, 'grantable', x.is_grantable
      ) ORDER BY x.grantee, x.privilege_type), '[]'::jsonb)
      FROM pg_catalog.aclexplode(COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))) x
      LEFT JOIN pg_catalog.pg_roles gr ON gr.oid = x.grantee),
      'definition', pg_catalog.pg_get_functiondef(p.oid)
    ) ORDER BY n.nspname, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid)), '[]'::jsonb)
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_catalog.pg_language l ON l.oid = p.prolang
    WHERE n.nspname IN ('public', 'private') AND p.prokind IN ('f', 'p')
  ),
  'views', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'name', c.relname, 'definition', pg_catalog.pg_get_viewdef(c.oid, true)
    ) ORDER BY n.nspname, c.relname), '[]'::jsonb)
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'private') AND c.relkind IN ('v', 'm')
  ),
  'sequences', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'name', c.relname, 'owner', pg_catalog.pg_get_userbyid(c.relowner),
      'sequence_type', pg_catalog.format_type(s.seqtypid, NULL),
      'start', s.seqstart, 'increment', s.seqincrement, 'min', s.seqmin,
      'max', s.seqmax, 'cache', s.seqcache, 'cycle', s.seqcycle,
      'owned_by', (SELECT jsonb_build_object('table', d.refobjid::regclass::text, 'column', a.attname)
        FROM pg_catalog.pg_depend d
        JOIN pg_catalog.pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
        WHERE d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = c.oid
          AND d.refclassid = 'pg_catalog.pg_class'::regclass AND d.deptype IN ('a', 'i')
        LIMIT 1)
    ) ORDER BY n.nspname, c.relname), '[]'::jsonb)
    FROM pg_catalog.pg_sequence s
    JOIN pg_catalog.pg_class c ON c.oid = s.seqrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'private')
  ),
  'types', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'name', t.typname, 'kind', t.typtype,
      'definition', CASE WHEN t.typtype = 'e' THEN (
        SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder)
        FROM pg_catalog.pg_enum e WHERE e.enumtypid = t.oid
      ) ELSE NULL END
    ) ORDER BY n.nspname, t.typname), '[]'::jsonb)
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname IN ('public', 'private') AND t.typtype IN ('e', 'd')
  ),
  'extensions', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'name', e.extname, 'version', e.extversion, 'schema', n.nspname
    ) ORDER BY e.extname), '[]'::jsonb)
    FROM pg_catalog.pg_extension e
    LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
  ),
  'table_privileges', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', table_schema, 'table', table_name, 'grantee', grantee,
      'privilege', privilege_type, 'grantable', is_grantable
    ) ORDER BY table_schema, table_name, grantee, privilege_type), '[]'::jsonb)
    FROM information_schema.table_privileges WHERE table_schema IN ('public', 'private')
  ),
  'column_privileges', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', table_schema, 'table', table_name, 'column', column_name,
      'grantee', grantee, 'privilege', privilege_type, 'grantable', is_grantable
    ) ORDER BY table_schema, table_name, column_name, grantee, privilege_type), '[]'::jsonb)
    FROM information_schema.column_privileges WHERE table_schema IN ('public', 'private')
  ),
  'routine_privileges', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', routine_schema, 'routine', routine_name, 'grantee', grantee,
      'privilege', privilege_type, 'grantable', is_grantable
    ) ORDER BY routine_schema, routine_name, grantee, privilege_type), '[]'::jsonb)
    FROM information_schema.routine_privileges WHERE routine_schema IN ('public', 'private')
  ),
  'schema_privileges', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'owner', pg_catalog.pg_get_userbyid(n.nspowner),
      'acl', n.nspacl::text,
      'privileges', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'grantee', CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE gr.rolname END,
        'privilege', x.privilege_type, 'grantable', x.is_grantable
      ) ORDER BY x.grantee, x.privilege_type), '[]'::jsonb)
      FROM pg_catalog.aclexplode(COALESCE(n.nspacl, pg_catalog.acldefault('n', n.nspowner))) x
      LEFT JOIN pg_catalog.pg_roles gr ON gr.oid = x.grantee)
    ) ORDER BY n.nspname), '[]'::jsonb)
    FROM pg_catalog.pg_namespace n WHERE n.nspname IN ('public', 'private')
  ),
  'sequence_privileges', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'sequence', c.relname,
      'grantee', CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE gr.rolname END,
      'privilege', x.privilege_type, 'grantable', x.is_grantable
    ) ORDER BY n.nspname, c.relname, x.grantee, x.privilege_type), '[]'::jsonb)
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(c.relacl, pg_catalog.acldefault('S', c.relowner))) x
    LEFT JOIN pg_catalog.pg_roles gr ON gr.oid = x.grantee
    WHERE n.nspname IN ('public', 'private') AND c.relkind = 'S'
  ),
  'default_privileges', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'owner', pg_catalog.pg_get_userbyid(d.defaclrole),
      'object_type', d.defaclobjtype, 'acl', d.defaclacl::text,
      'privileges', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'grantee', CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE gr.rolname END,
        'privilege', x.privilege_type, 'grantable', x.is_grantable
      ) ORDER BY x.grantee, x.privilege_type), '[]'::jsonb)
      FROM pg_catalog.aclexplode(d.defaclacl) x
      LEFT JOIN pg_catalog.pg_roles gr ON gr.oid = x.grantee)
    ) ORDER BY n.nspname, d.defaclobjtype), '[]'::jsonb)
    FROM pg_catalog.pg_default_acl d
    LEFT JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
    WHERE n.nspname IN ('public', 'private')
  )
)) AS schema_catalog_export;

ROLLBACK;
