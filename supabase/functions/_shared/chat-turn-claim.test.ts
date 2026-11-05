import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { releaseGenerationClaim } from "./chat-turn-claim.ts";

function makeAdmin(result: { data: unknown; error: unknown }) {
  const trace: Array<{ method: string; args: unknown[] }> = [];
  const query = {
    update(...args: unknown[]) { trace.push({ method: "update", args }); return this; },
    eq(...args: unknown[]) { trace.push({ method: "eq", args }); return this; },
    select(...args: unknown[]) { trace.push({ method: "select", args }); return this; },
    async maybeSingle() { trace.push({ method: "maybeSingle", args: [] }); return result; },
  };
  return {
    trace,
    admin: {
      from(table: string) {
        trace.push({ method: "from", args: [table] });
        return query;
      },
    },
  };
}

Deno.test("releaseGenerationClaim confirms the exact claimed turn was released", async () => {
  const { admin, trace } = makeAdmin({
    data: { turn_id: "turn-1" },
    error: null,
  });
  assertEquals(await releaseGenerationClaim(admin, "turn-1", "user-1"), true);
  assertEquals(trace.filter((item) => item.method === "eq").map((item) => item.args), [
    ["turn_id", "turn-1"],
    ["user_id", "user-1"],
    ["status", "needs_reconciliation"],
    ["failure_code", "provider_generation_in_progress"],
  ]);
  assertEquals(trace.some((item) => item.method === "select" && item.args[0] === "turn_id"), true);
});

Deno.test("releaseGenerationClaim fails closed when the database update errors", async () => {
  const { admin } = makeAdmin({ data: null, error: { message: "database unavailable" } });
  assertEquals(await releaseGenerationClaim(admin, "turn-1", "user-1"), false);
});

Deno.test("releaseGenerationClaim fails closed when no matching claim was updated", async () => {
  const { admin } = makeAdmin({ data: null, error: null });
  assertEquals(await releaseGenerationClaim(admin, "turn-1", "user-1"), false);
});

Deno.test("releaseGenerationClaim rejects an unexpected returned turn id", async () => {
  const { admin } = makeAdmin({ data: { turn_id: "another-turn" }, error: null });
  assertEquals(await releaseGenerationClaim(admin, "turn-1", "user-1"), false);
});
