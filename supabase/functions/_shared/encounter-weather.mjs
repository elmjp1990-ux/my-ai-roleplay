export function asStationArray(payload) {
  const value = payload?.records?.Station ?? payload?.records?.station ?? [];
  if (Array.isArray(value)) return value;
  return value && typeof value === "object" ? [value] : [];
}

function validNumber(value) {
  if (value === null || value === undefined || value === "" || value === "-99" || value === "-98" || value === "X") return null;
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

export function parseCwaWeatherObservation(payload, stationId = "466920") {
  const station = asStationArray(payload).find((row) => String(row?.StationId ?? "") === stationId);
  if (!station) return null;
  const element = station.WeatherElement || {};
  const rawWeather = String(element.Weather ?? "").trim();
  const weatherText = rawWeather && !["-99", "-98", "X"].includes(rawWeather)
    ? rawWeather
    : "";
  const temperatureC = element.AirTemperature === undefined
    ? null
    : Number(element.AirTemperature);
  const observedAt = station.ObsTime?.DateTime || null;
  return {
    stationId,
    stationName: String(station.StationName || "臺北"),
    weatherText,
    temperatureC: Number.isFinite(temperatureC) && temperatureC > -80 ? temperatureC : null,
    observedAt: observedAt && Number.isFinite(Date.parse(observedAt)) ? new Date(observedAt).toISOString() : null,
  };
}

function parsePrecipitation(value) {
  if (String(value ?? "").trim().toUpperCase() === "T") return 0.1;
  return validNumber(value);
}

export function parseCwaRainfallObservation(payload, stationId = "466920") {
  const station = asStationArray(payload).find((row) => String(row?.StationId ?? "") === stationId);
  if (!station) return null;
  const element = station.RainfallElement || {};
  const past1h = parsePrecipitation(element.Past1hr?.Precipitation ?? element.Past1Hr?.Precipitation);
  const past10m = parsePrecipitation(element.Past10Min?.Precipitation);
  return {
    stationId,
    precipitation1hMm: past1h,
    precipitation10mMm: past10m,
    isRaining: (past1h ?? 0) > 0 || (past10m ?? 0) > 0,
  };
}

export function isRainWeatherText(weatherText) {
  return /雨|陣雨|雷雨|毛毛雨|霧雨|豪雨|大雨|小雨|飄雨/.test(String(weatherText || ""));
}
