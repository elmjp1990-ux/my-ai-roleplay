const WEATHER_STATES = [
  { text: "晴朗", raining: false, weight: 24 },
  { text: "晴時多雲", raining: false, weight: 20 },
  { text: "多雲", raining: false, weight: 20 },
  { text: "陰天", raining: false, weight: 14 },
  { text: "毛毛雨", raining: true, weight: 6 },
  { text: "短暫陣雨", raining: true, weight: 7 },
  { text: "小雨", raining: true, weight: 5 },
  { text: "雷陣雨", raining: true, weight: 2 },
  { text: "有風", raining: false, weight: 2 },
];

function hash32(value) {
  let hash = 2166136261;
  for (let i = 0; i < value.length; i += 1) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

function seasonWeights(month) {
  // Taipei-like seasonal variation, intentionally illustrative rather than forecast data.
  if ([5, 6, 7, 8, 9].includes(month)) {
    return { rain: 1.45, thunder: 1.8, wind: 0.75, cloud: 1.05 };
  }
  if ([12, 1, 2].includes(month)) {
    return { rain: 0.85, thunder: 0.45, wind: 1.55, cloud: 1.3 };
  }
  return { rain: 1, thunder: 0.8, wind: 1, cloud: 1 };
}

/**
 * Creates a stable, lightweight fictional city-weather state for one 6-hour slot.
 * It is intentionally not a forecast and requires no external weather API.
 */
export function createEncounterWeather(now = new Date(), previousWeatherText = "") {
  const date = now instanceof Date ? now : new Date(now);
  if (!Number.isFinite(date.getTime())) throw new Error("invalid_weather_time");
  const slot = Math.floor(date.getTime() / (6 * 60 * 60 * 1000));
  const month = date.getUTCMonth() + 1;
  const season = seasonWeights(month);
  const weighted = WEATHER_STATES.map((state) => ({
    ...state,
    weight: state.weight * (
      state.raining ? (state.text.includes("雷") ? season.thunder : season.rain)
        : state.text === "有風" ? season.wind
          : state.text === "多雲" || state.text === "陰天" ? season.cloud : 1
    ),
  }));
  const total = weighted.reduce((sum, state) => sum + state.weight, 0);
  const roll = hash32("poyozz-taipei-weather-" + slot) % Math.floor(total * 1000);
  let cursor = roll / 1000;
  let selected = weighted[0];
  for (const state of weighted) {
    cursor -= state.weight;
    if (cursor < 0) { selected = state; break; }
  }

  // Repeated states are allowed; the weighted seasonal sequence creates natural variation.

  const seasonalTemperature = month >= 6 && month <= 9 ? 29
    : [12, 1, 2].includes(month) ? 17 : 23;
  const temperatureC = seasonalTemperature + (hash32("poyozz-temp-" + slot) % 7) - 3;
  return {
    cityKey: "taipei",
    weatherText: selected.text,
    temperatureC,
    isRaining: selected.raining,
    precipitation1hMm: selected.raining ? null : 0,
    observedAt: date.toISOString(),
    slot,
    source: "poyozz_fictional_seasonal",
  };
}

export function isRainWeatherText(weatherText) {
  return /雨|陣雨|雷雨|毛毛雨|霧雨|豪雨|大雨|小雨|飄雨/.test(String(weatherText || ""));
}
