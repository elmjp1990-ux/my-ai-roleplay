-- Keep account-deletion archival restricted to trusted server-side workers.
-- The function validates that the deletion request is due and verifies the
-- archived row counts and payloads before returning an archived batch.
REVOKE ALL ON FUNCTION public.archive_account_deletion_data(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_account_deletion_data(uuid)
  TO service_role;
