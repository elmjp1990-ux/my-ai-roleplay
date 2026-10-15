-- Restore the intended 30-day grace period after temporary test configuration.
-- This changes only the default for future requests; it does not reschedule existing requests.
ALTER TABLE public.account_deletion_requests
  ALTER COLUMN scheduled_for SET DEFAULT (now() + interval '30 days');
