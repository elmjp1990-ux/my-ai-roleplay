import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  isRainWeatherText,
  parseCwaRainfallObservation,
  parseCwaWeatherObservation,
} from "./encounter-weather.mjs";

Deno.test("parses Taipei station 466920 hourly weather", () => {
  const result = parseCwaWeatherObservation({
    records: { Station: [{
      StationId: "466920",
      StationName: "臺北",
      ObsTime: { DateTime: "2025-08-12T14:00:00+08:00" },
      WeatherElement: { Weather: "多雲", AirTemperature: "32.4" },
    }] },
  });
  assertEquals(result?.weatherText, "多雲");
  assertEquals(result?.temperatureC, 32.4);
  assertEquals(result?.observedAt, "2025-08-12T06:00:00.000Z");
});

Deno.test("ignores CWA missing and abnormal temperature values", () => {
  const result = parseCwaWeatherObservation({
    records: { Station: [{
      StationId: "466920",
      WeatherElement: { Weather: "-99", AirTemperature: "-99" },
    }] },
  });
  assertEquals(result?.weatherText, "");
  assertEquals(result?.temperatureC, null);
});

Deno.test("uses past-hour and past-ten-minute rainfall, including trace rain", () => {
  const result = parseCwaRainfallObservation({
    records: { Station: [{
      StationId: "466920",
      RainfallElement: {
        Past1hr: { Precipitation: "0.0" },
        Past10Min: { Precipitation: "T" },
      },
    }] },
  });
  assertEquals(result?.precipitation1hMm, 0);
  assertEquals(result?.precipitation10mMm, 0.1);
  assertEquals(result?.isRaining, true);
});

Deno.test("detects rain descriptions without treating cloudy weather as rain", () => {
  assertEquals(isRainWeatherText("短暫陣雨"), true);
  assertEquals(isRainWeatherText("多雲時晴"), false);
});
