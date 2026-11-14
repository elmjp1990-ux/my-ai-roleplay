import { assertEquals } from "jsr:@std/assert";
import { asRecord, asTrimmedString, isUuid } from "./ai-value-utils.ts";

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
