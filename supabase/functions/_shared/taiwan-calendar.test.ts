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

Deno.test("does not treat a generic weekend category as a named special event", () => {
  const rows = parseTaiwanCalendarRows([
    { date: "2026-11-21", isholiday: true, name: "", holidaycategory: "週末假期", description: "" },
    { date: "2026-11-22", isholiday: true, name: "星期日", holidaycategory: "週末假期", description: "放假" },
    { date: "2026-11-23", isholiday: true, name: "星期日", holidaycategory: "國定假日", description: "補假" },
    { date: "2026-11-24", isholiday: true, name: "", holidaycategory: "國定假日", description: "" },
  ]);
  assertEquals(rows[0]?.day_type, "holiday");
  assertEquals(rows[0]?.holiday_name, null);
  assertEquals(rows[1]?.holiday_name, null);
  assertEquals(rows[2]?.holiday_name, "補假");
  assertEquals(rows[3]?.holiday_name, "國定假日");
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
