import { assertEquals } from "jsr:@std/assert";
import { asRecord, asTrimmedString, isUuid, jsonResponse } from "./ai-value-utils.ts";

Deno.test("asRecord accepts only non-array objects", () => {
  assertEquals(asRecord({ id: "a" }), { id: "a" });
  assertEquals(asRecord(null), {});
  assertEquals(asRecord(["a"]), {});
  assertEquals(asRecord("value"), {});
});

Deno.test("asTrimmedString trims strings and rejects other values", () => {
  assertEquals(asTrimmedString("  POYOZZ  "), "POYOZZ");
  assertEquals(asTrimmedString(123), "");
  assertEquals(asTrimmedString(null), "");
});

Deno.test("isUuid accepts UUIDs and rejects malformed identifiers", () => {
  assertEquals(isUuid("8b8985c4-1e22-4585-8e1b-6fcb3cccba4e"), true);
  assertEquals(isUuid("not-a-uuid"), false);
  assertEquals(isUuid(null), false);
});

Deno.test("jsonResponse preserves status and CORS headers with a JSON content type", async () => {
  const response = jsonResponse({ error: "invalid_request" }, 422, {
    "Access-Control-Allow-Origin": "*",
    "X-Request-Mode": "story",
  });
  assertEquals(response.status, 422);
  assertEquals(response.headers.get("Content-Type"), "application/json");
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "*");
  assertEquals(response.headers.get("X-Request-Mode"), "story");
  assertEquals(await response.json(), { error: "invalid_request" });
});
