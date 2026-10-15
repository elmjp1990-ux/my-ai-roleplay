-- Test environments use a short grace period for account deletion flow validation.
-- The frontend must display the backend-provided scheduled_for timestamp, not a hardcoded duration.
-- This affects only future requests; existing requests are unchanged. No deletion job is scheduled.
ALTER TABLE public.account_deletion_requests
  ALTER COLUMN scheduled_for SET DEFAULT (now() + interval '5 minutes');
