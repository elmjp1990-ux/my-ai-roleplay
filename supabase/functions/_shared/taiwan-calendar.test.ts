import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseTaiwanCalendarRows } from "./taiwan-calendar.mjs";

Deno.test("uses official holiday flag for a weekday holiday", () => {
  const rows = parseTaiwanCalendarRows([
    { date: "2026-02-27", isholiday: "是", name: "和平紀念日補假" },
  ]);
  assertEquals(rows[0]?.day_type, "holiday");
  assertEquals(rows[0]?.holiday_name, "和平紀念日補假");
  assertEquals(rows[0]?.source, "data.gov.tw:123662");
});

Deno.test("keeps weekend make-up workdays as workdays", () => {
  const rows = parseTaiwanCalendarRows([
    { date: "2026-02-07", isholiday: "否", name: "補行上班" },
  ]);
  assertEquals(rows[0]?.day_type, "workday");
});

Deno.test("accepts alternate payload wrappers and ignores invalid dates", () => {
  const rows = parseTaiwanCalendarRows({
    data: [
      { date: "2027/01/01", isholiday: true, name: "開國紀念日" },
      { date: "2027-02-30", isholiday: true, name: "invalid" },
      { date: "2027-01-02", isholiday: "unknown", name: "unknown" },
    ],
  });
  assertEquals(rows.length, 1);
  assertEquals(rows[0].calendar_date, "2027-01-01");
});
