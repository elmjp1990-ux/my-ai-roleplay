import fs from "node:fs";

const inputPath = process.argv[2];
const outputPath = process.argv[3] || "supabase/drafts/encounter-weather-baseline-2025.json";
if (!inputPath) {
  console.error("Usage: node scripts/import-encounter-weather-baseline-2025.mjs <CWA-CODiS-CSV> [output.json]");
  process.exit(2);
}

function parseCsv(text) {
  const rows = [];
  let row = [], field = "", quoted = false;
  const source = text.replace(/^\uFEFF/, "");
  for (let i = 0; i < source.length; i++) {
    const ch = source[i], next = source[i + 1];
    if (quoted) {
      if (ch === '"' && next === '"') { field += '"'; i++; }
      else if (ch === '"') quoted = false;
      else field += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ",") { row.push(field); field = ""; }
    else if (ch === "\n") { row.push(field); rows.push(row); row = []; field = ""; }
    else if (ch !== "\r") field += ch;
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  return rows.filter((item) => item.some((value) => String(value).trim() !== ""));
}

const normalize = (value) => String(value || "").toLowerCase().replace(/[\s()（）_\-℃°]/g, "");
const headers = parseCsv(fs.readFileSync(inputPath, "utf8"));
if (headers.length < 2) throw new Error("CSV has no data rows");
const header = headers[0].map((value) => String(value).trim());
const find = (patterns) => header.findIndex((value) => patterns.some((pattern) => normalize(value).includes(pattern)));
const dateIndex = find(["datetime", "觀測時間", "年月日時", "日期時間"]);
const temperatureIndex = find(["airtemperature", "氣溫", "溫度"]);
const rainfallIndex = find(["past1hr", "過去1小時", "時雨量", "一小時降水量", "hourlyprecipitation"]);
const stationIndex = find(["stationid", "測站代碼", "測站編號"]);
if (dateIndex < 0 || temperatureIndex < 0 || rainfallIndex < 0) {
  throw new Error("CSV must include observation time, air temperature, and hourly rainfall (Past1hr / 過去1小時 / 時雨量). Daily accumulated precipitation is not valid for hourly rain probability");
}

const buckets = new Map();
for (const values of headers.slice(1)) {
  if (stationIndex >= 0 && String(values[stationIndex] || "").trim() !== "466920") continue;
  const dateText = String(values[dateIndex] || "").trim().replace(/\//g, "-");
  const match = /^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2})/.exec(dateText);
  if (!match || Number(match[1]) !== 2025) continue;
  const month = Number(match[2]), hour = Number(match[4]);
  if (month < 1 || month > 12 || hour < 0 || hour > 23) continue;
  const rawTemperature = String(values[temperatureIndex] || "").trim();
  const temperature = Number(rawTemperature);
  if (!rawTemperature || !Number.isFinite(temperature) || temperature <= -80 || temperature >= 60) continue;
  const rawRain = String(values[rainfallIndex] || "").trim().toUpperCase();
  const rainfall = rawRain === "T" ? 0.1 : Number(rawRain);
  const key = month + "-" + hour;
  const bucket = buckets.get(key) || { month, hour, temperatureSum: 0, temperatureCount: 0, rainCount: 0 };
  bucket.temperatureSum += temperature;
  bucket.temperatureCount += 1;
  if (Number.isFinite(rainfall) && rainfall > 0) bucket.rainCount += 1;
  buckets.set(key, bucket);
}

const rows = [...buckets.values()]
  .filter((bucket) => bucket.temperatureCount > 0)
  .sort((a, b) => a.month - b.month || a.hour - b.hour)
  .map((bucket) => ({
    month: bucket.month,
    hour: bucket.hour,
    average_temperature_c: Math.round((bucket.temperatureSum / bucket.temperatureCount) * 10) / 10,
    rain_probability: Math.round((bucket.rainCount / bucket.temperatureCount) * 10000) / 10000,
    sample_count: bucket.temperatureCount,
    source: "CWA CODiS Taipei station 466920, 2025",
  }));

if (rows.length < 240) {
  throw new Error("Only " + rows.length + "/288 month-hour buckets were found; verify that the CSV covers all of 2025 and station 466920");
}
fs.writeFileSync(outputPath, JSON.stringify(rows, null, 2) + "\n");
console.log("Wrote " + rows.length + " Taipei 2025 hourly baseline rows to " + outputPath);
