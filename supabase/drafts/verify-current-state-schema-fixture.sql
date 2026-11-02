DO $$
DECLARE
  v_tables integer;
  v_columns integer;
  v_constraints integer;
  v_indexes integer;
  v_policies integer;
  v_triggers integer;
  v_routines integer;
  v_views integer;
  v_sequences integer;
  v_rls integer;
  v_nonempty text;
  v_has_rows boolean;
BEGIN
  SELECT count(*) INTO v_tables FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r';
  SELECT count(*) INTO v_columns FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND a.attnum>0 AND NOT a.attisdropped;
  SELECT count(*) INTO v_constraints FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public';
  SELECT count(*) INTO v_indexes FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public';
  SELECT count(*) INTO v_policies FROM pg_policies WHERE schemaname='public';
  SELECT count(DISTINCT (t.tgrelid,t.tgname)) INTO v_triggers FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal;
  SELECT count(*) INTO v_routines FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('public','private') AND p.prokind IN ('f','p');
  SELECT count(*) INTO v_views FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='v';
  SELECT count(*) INTO v_sequences FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='S';
  SELECT count(*) INTO v_rls FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity;
  IF (v_tables,v_columns,v_constraints,v_indexes,v_policies,v_triggers,v_routines,v_views,v_sequences,v_rls)
     IS DISTINCT FROM (47,416,288,140,95,23,77,1,2,47) THEN
    RAISE EXCEPTION 'disposable schema fingerprint mismatch: tables %, columns %, constraints %, indexes %, policies %, triggers %, routines %, views %, sequences %, rls %',
      v_tables,v_columns,v_constraints,v_indexes,v_policies,v_triggers,v_routines,v_views,v_sequences,v_rls;
  END IF;
  FOR v_nonempty IN
    SELECT format('%I.%I', n.nspname, c.relname)
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='r'
  LOOP
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM ' || v_nonempty || ')' INTO STRICT v_has_rows;
    IF v_has_rows THEN RAISE EXCEPTION 'schema-only fixture unexpectedly contains rows in %', v_nonempty; END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM auth.users) THEN RAISE EXCEPTION 'auth.users stub must be empty'; END IF;
END;
$$;
