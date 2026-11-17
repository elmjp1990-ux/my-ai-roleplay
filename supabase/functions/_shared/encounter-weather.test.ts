import { assertEquals, assertNotEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createEncounterWeather } from "./encounter-weather.mjs";

Deno.test("weather is stable within a Taipei-local six-hour slot", () => {
  const first = createEncounterWeather(new Date("2026-07-20T01:00:00+08:00"));
  const second = createEncounterWeather(new Date("2026-07-20T05:59:00+08:00"));
  assertEquals(first.weatherText, second.weatherText);
  assertEquals(first.temperatureC, second.temperatureC);
  assertEquals(first.slot, second.slot);
});

Deno.test("weather advances at Taipei-local six-hour boundaries", () => {
  const before = createEncounterWeather(new Date("2026-07-20T05:59:00+08:00"));
  const after = createEncounterWeather(new Date("2026-07-20T06:00:00+08:00"));
  assertNotEquals(before.slot, after.slot);
});

Deno.test("weather sequence has seasonal variety without forcing every slot to change", () => {
  const states = new Set();
  for (let slot = 0; slot < 28; slot += 1) {
    const weather = createEncounterWeather(new Date(Date.UTC(2026, 6, 1, slot * 6)));
    states.add(weather.weatherText);
  }
  if (states.size < 3) throw new Error("Weather sequence should include natural variation");
});

Deno.test("weather uses Taipei local month and the supported simple vocabulary", () => {
  const allowed = new Set(["晴朗", "晴時多雲", "多雲", "陰天", "毛毛雨", "短暫陣雨", "小雨", "雷陣雨", "有風", "強風"]);
  for (let day = 1; day <= 28; day += 1) {
    const weather = createEncounterWeather(new Date(Date.UTC(2026, 6, day, 4)));
    if (!allowed.has(weather.weatherText)) throw new Error("Unexpected weather: " + weather.weatherText);
    assertEquals(weather.cityKey, "taipei");
    assertEquals(weather.isRaining, /雨/.test(weather.weatherText));
    if (weather.temperatureC < 14 || weather.temperatureC > 33) throw new Error("Temperature outside broad seasonal bounds");
    assertEquals(weather.source, "poyozz_fictional_seasonal");
  }
  const taipeiMonthBoundary = createEncounterWeather(new Date("2026-05-31T23:30:00+08:00"));
  assertEquals(taipeiMonthBoundary.slot.startsWith("2026-05-31-"), true);
});

Deno.test("weather may naturally persist across slots without forced changes", () => {
  const first = createEncounterWeather(new Date("2026-07-20T06:00:00+08:00"));
  const second = createEncounterWeather(new Date("2026-07-20T06:00:00+08:00"));
  assertEquals(first.weatherText, second.weatherText);
  assertEquals(first.slot, second.slot);
});

Deno.test("invalid dates are rejected", () => {
  let thrown = false;
  try { createEncounterWeather(new Date("invalid")); } catch { thrown = true; }
  assertEquals(thrown, true);
});
