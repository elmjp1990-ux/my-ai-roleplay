import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Content-Type": "application/json",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST required" }), { status: 405, headers: corsHeaders });
  }

  // Keep platform JWT verification enabled and accept only the server-side service-role JWT.
  // The scheduler must retrieve this value from Vault; never expose it to browser clients.
  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authHeader = req.headers.get("Authorization") || "";
  if (!serviceRoleKey || authHeader !== `Bearer ${serviceRoleKey}`) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });
  }
  if (!url || !serviceRoleKey) {
    return new Response(JSON.stringify({ error: "Server environment is incomplete" }), { status: 500, headers: corsHeaders });
  }

  const supabase = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const now = new Date().toISOString();
  const { data: photos, error: listError } = await supabase
    .from("chat_memory_photos")
    .select("id,owner_id,chat_type,session_id,group_id,storage_path,expires_at,deletion_attempts")
    // Expire active photos, but also retry explicit deletions even when deleted_at is set.
    // soft_delete_chat_memory_photo marks rows as deleting and sets deleted_at immediately.
    .or(`and(expires_at.lte.${now},deleted_at.is.null),status.eq.deleting,status.eq.delete_failed`)
    .in("status", ["active", "deleting", "delete_failed"])
    .order("expires_at", { ascending: true })
    .limit(100);

  if (listError) {
    return new Response(JSON.stringify({ error: listError.message }), { status: 500, headers: corsHeaders });
  }

  const results: Array<{ id: string; result: string; detail?: string }> = [];
  for (const photo of photos || []) {
    try {
      // Clear a background reference first. Do not choose a replacement image.
      if (photo.chat_type === "single" && photo.session_id) {
        const { data: session, error } = await supabase
          .from("chat_sessions")
          .select("id,session_data")
          .eq("id", photo.session_id)
          .maybeSingle();
        if (error) throw error;
        const sessionData = session?.session_data && typeof session.session_data === "object"
          ? session.session_data as Record<string, unknown>
          : {};
        const currentBackground = String(sessionData.background || "");
        if (session && (currentBackground === `memory-photo:${photo.id}` || currentBackground === photo.id)) {
          const { error: updateError } = await supabase.from("chat_sessions")
            .update({ session_data: { ...sessionData, background: "none" }, updated_at: now })
            .eq("id", photo.session_id);
          if (updateError) throw updateError;
        }
      } else if (photo.chat_type === "group" && photo.group_id) {
        const { data: group, error } = await supabase.from("chat_groups")
          .select("id,background_mode,background_memory_photo_id")
          .eq("id", photo.group_id)
          .maybeSingle();
        if (error) throw error;
        if (group && group.background_memory_photo_id === photo.id) {
          const { error: updateError } = await supabase.from("chat_groups")
            .update({ background_mode: "none", background_memory_photo_id: null, updated_at: now })
            .eq("id", photo.group_id);
          if (updateError) throw updateError;
        }
      }

      const { error: markError } = await supabase.from("chat_memory_photos")
        .update({ status: "deleting", deletion_attempts: Number(photo.deletion_attempts || 0) + 1, last_deletion_error: null })
        .eq("id", photo.id);
      if (markError) throw markError;

      const { error: storageError } = await supabase.storage.from("personax-memory-photos").remove([photo.storage_path]);
      if (storageError) {
        await supabase.from("chat_memory_photos").update({
          status: "delete_failed",
          last_deletion_error: storageError.message.slice(0, 1000),
        }).eq("id", photo.id);
        results.push({ id: photo.id, result: "delete_failed", detail: storageError.message });
        continue;
      }

      const { error: deleteError } = await supabase.from("chat_memory_photos")
        .delete().eq("id", photo.id);
      if (deleteError) {
        await supabase.from("chat_memory_photos").update({
          status: "delete_failed",
          last_deletion_error: deleteError.message.slice(0, 1000),
        }).eq("id", photo.id);
        results.push({ id: photo.id, result: "metadata_delete_failed", detail: deleteError.message });
        continue;
      }
      results.push({ id: photo.id, result: "deleted" });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await supabase.from("chat_memory_photos").update({
        status: "delete_failed",
        deletion_attempts: Number(photo.deletion_attempts || 0) + 1,
        last_deletion_error: message.slice(0, 1000),
      }).eq("id", photo.id);
      results.push({ id: photo.id, result: "error", detail: message });
    }
  }

  return new Response(JSON.stringify({
    checked_at: now,
    processed: results.length,
    deleted: results.filter(item => item.result === "deleted").length,
    results,
  }), { status: 200, headers: corsHeaders });
});
