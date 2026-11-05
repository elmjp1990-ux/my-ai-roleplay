/** Safely release a pre-provider generation claim after a confirmed non-generation failure. */
export async function releaseGenerationClaim(
  admin: any,
  turnId: string,
  userId: string,
): Promise<boolean> {
  const { data, error } = await admin.from("chat_turn_charges")
    .update({
      status: "reserved",
      failure_code: null,
      updated_at: new Date().toISOString(),
    })
    .eq("turn_id", turnId)
    .eq("user_id", userId)
    .eq("status", "needs_reconciliation")
    .eq("failure_code", "provider_generation_in_progress")
    .select("turn_id")
    .maybeSingle();

  return !error && data?.turn_id === turnId;
}
