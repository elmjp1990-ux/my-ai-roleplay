-- Run only after the migration and Edge Function are deployed.
-- Replace the two placeholders below with server-side secrets; never commit real keys.
-- Enable pg_net first if it is not already enabled.
create extension if not exists pg_net;

select vault.create_secret(
  'https://ouyewoagbmtqehbofrje.supabase.co',
  'personax_project_url'
);

select vault.create_secret(
  '<SUPABASE_SERVICE_ROLE_KEY>',
  'personax_service_role_key'
);

select cron.schedule(
  'personax-memory-album-expiry',
  '17 3 * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'personax_project_url')
      || '/functions/v1/expire-memory-album-photos',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'personax_service_role_key'),
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'personax_service_role_key')
    ),
    body := jsonb_build_object('scheduled_at', now()),
    timeout_milliseconds := 10000
  ) as request_id;
  $$
);
