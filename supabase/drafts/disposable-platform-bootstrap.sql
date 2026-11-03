-- Minimal platform compatibility bootstrap for disposable PostgreSQL fixture tests.
-- This is NOT a Supabase Auth database and contains no user records.
-- It provides only the roles/schema/function surface referenced by the app schema snapshot.

DO $$ BEGIN
  CREATE ROLE anon NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE authenticated NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE service_role NOLOGIN BYPASSRLS;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE supabase_admin NOLOGIN SUPERUSER;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION postgres;
CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY);

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    NULLIF(pg_catalog.current_setting('role', true), ''),
    current_user
  )
$$;


CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  )
$$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.role() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.jwt() TO anon, authenticated, service_role;
GRANT ALL ON SCHEMA public TO supabase_admin;
GRANT ALL ON SCHEMA auth TO supabase_admin;

-- Minimal Supabase Storage compatibility surface for disposable migration replay.
-- The app schema snapshot intentionally excludes platform-owned storage tables;
-- create only the columns and bucket metadata referenced by reviewed policies/tests.
CREATE SCHEMA IF NOT EXISTS storage AUTHORIZATION postgres;
CREATE TABLE IF NOT EXISTS storage.buckets (
  id text PRIMARY KEY,
  name text NOT NULL,
  public boolean NOT NULL DEFAULT false
);
CREATE TABLE IF NOT EXISTS storage.objects (
  bucket_id text NOT NULL,
  name text NOT NULL,
  PRIMARY KEY (bucket_id, name)
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
GRANT SELECT ON storage.objects TO authenticated, service_role;
GRANT ALL ON storage.buckets TO postgres, supabase_admin;
GRANT ALL ON storage.objects TO postgres, supabase_admin;
