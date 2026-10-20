# MEMORY-ALBUM-01 — deploy and test checklist

This feature is staged in Draft PR #99. The migration has **not** been applied to the test database and the Edge Function has **not** been deployed.

## Before browser testing

1. Review and merge/deploy the PR only when ready for the test environment.
2. Apply `supabase/migrations/20261020120000_unified_memory_album.sql` to the test project.
3. Deploy `supabase/functions/expire-memory-album-photos/index.ts`.
4. Set the Edge Function secret `MEMORY_ALBUM_CRON_SECRET` to a newly generated long random value. Keep it out of Git and browser code.
5. Run `supabase/operations/schedule-memory-album-expiry.sql` only after replacing its placeholders with server-side secrets. It stores the project URL, service-role key, and the same cron secret in Supabase Vault, then schedules the cleanup worker daily at 03:17 UTC.
6. Confirm `pg_cron`, `pg_net`, and Vault are available in the project before running the schedule SQL. Never put a real service-role key or cron secret in this repository.

## Minimum acceptance tests

- Upload one JPEG, PNG, and WebP in a single chat; reload and confirm all persist.
- Upload a separate photo in a group; confirm it appears only in that group and not in the single chat or another group.
- Confirm the caption and created date are shown, tapping the thumbnail opens the full image, and download returns the original uploaded file.
- Confirm unsupported MIME types and files over 10 MiB are rejected.
- Confirm signed URLs expire and a fresh album load creates a new URL.
- With a dedicated test record whose `expires_at` is set to the past by an authorized test-only setup, invoke the Edge Function and confirm it clears only that photo's background reference, does not select another image, removes the Storage object and metadata, and safely retries failures.
- Test with another authenticated account and confirm it cannot list or sign URLs for photos belonging to someone else's session/group.

## Important current limitation

The new album UI/upload and the expiry worker are separate from the existing background picker. The background picker still needs to write stable references like `memory-photo:<photo UUID>` for single chats and the new photo UUID for groups before the background-expiry acceptance test can pass. Do not describe one-year deletion as active until the worker is deployed, scheduled, and verified.
