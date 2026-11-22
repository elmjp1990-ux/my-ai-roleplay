import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleEncounterScheduleOrganizer } from "../_shared/encounter-schedule-organizer-handler.ts";

// Scheduled Supabase dispatch remains below pg_net's 120s ceiling.
// Manual test generation is routed through Vercel's 300s Node.js Function.
Deno.serve((request) =>
  handleEncounterScheduleOrganizer(request, Deno.env, createClient, 100_000)
);
