-- Defense in depth: this decision cache is accessed only through SECURITY DEFINER RPCs.
ALTER TABLE public.encounter_schedule_weather_decisions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.encounter_schedule_weather_decisions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.encounter_schedule_weather_decisions TO service_role;
