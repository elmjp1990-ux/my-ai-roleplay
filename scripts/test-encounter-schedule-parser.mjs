import assert from "node:assert/strict";
import fs from "node:fs";

const html = fs.readFileSync("index.html", "utf8");
const start = html.indexOf("function parseEncounterScheduleText(raw) {");
const end = html.indexOf("\nasync function saveEncounterSchedules", start);
assert.ok(start >= 0 && end > start, "Encounter schedule parser must exist in index.html");

const parserSource = html.slice(start, end);
const parseEncounterScheduleText = new Function(
  parserSource + "\nreturn parseEncounterScheduleText;"
)();

const validTwoRows = "1|09:00|12:00|cafe|在咖啡廳工作\n*|18:00|20:00|park|傍晚散步";
assert.equal(parseEncounterScheduleText(validTwoRows).length, 2);
assert.equal(parseEncounterScheduleText(validTwoRows.replaceAll("\n", "\r\n")).length, 2);
assert.deepEqual(parseEncounterScheduleText(""), []);

const fiftyRows = Array.from(
  { length: 50 },
  (_, i) => `1|09:${String(i % 60).padStart(2, "0")}|10:${String(i % 60).padStart(2, "0")}|cafe|工作`,
).join("\n");
assert.equal(parseEncounterScheduleText(fiftyRows).length, 50);
assert.throws(() => parseEncounterScheduleText(fiftyRows + "\n2|10:00|11:00|park|散步"), /最多設定 50/);

for (const [name, row, expectedError] of [
  ["bad time", "1|25:00|12:00|cafe|工作", /時間格式錯誤/],
  ["bad weekday", "7|09:00|12:00|cafe|工作", /星期必須是 0 到 6/],
  ["bad location", "1|09:00|12:00|咖啡廳|工作", /地點代碼只能使用英文/],
  ["empty activity", "1|09:00|12:00|cafe|", /活動不可空白/],
  ["same start/end", "1|09:00|09:00|cafe|工作", /時間格式錯誤/],
  ["wrong column count", "1|09:00|cafe|工作", /格式錯誤/],
]) {
  assert.throws(() => parseEncounterScheduleText(row), expectedError, name);
}

console.log("Encounter schedule parser tests passed.");
