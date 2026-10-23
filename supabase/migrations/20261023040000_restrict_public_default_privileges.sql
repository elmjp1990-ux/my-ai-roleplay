-- SECURITY-01-01: Make future public-schema objects private by default.
-- Existing object grants are not changed by ALTER DEFAULT PRIVILEGES.
-- Public RPCs must receive explicit GRANT EXECUTE in their own migrations.

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL PRIVILEGES ON TABLES FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated;
