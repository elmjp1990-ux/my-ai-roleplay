-- Character ages are descriptive role-card text, not a numeric age-gate input.
-- Existing integer values remain unchanged as text (for example, 28 -> '28').
-- Account adult access is enforced independently through profiles.birthdate.
ALTER TABLE public.characters
  ALTER COLUMN age TYPE text
  USING age::text;

COMMENT ON COLUMN public.characters.age IS
  'Creator-provided descriptive character age text; adult account eligibility is enforced using profiles.birthdate.';
