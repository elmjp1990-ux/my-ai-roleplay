-- Profile mutations should go through the owner-checked save_my_profile RPC.
-- The frontend initialization fallback now uses this RPC as well.
-- Keep direct reads constrained by existing column grants and RLS.
REVOKE INSERT (id, handle, nickname, avatar_url, bio, birthdate, persona_presets),
       UPDATE (id, handle, nickname, avatar_url, bio, birthdate, persona_presets)
ON TABLE public.profiles
FROM authenticated;
