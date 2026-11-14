import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync("notifications-screen.js", "utf8");
const html = readFileSync("index.html", "utf8");
const build = readFileSync("scripts/build-vercel-static.mjs", "utf8");

assert.match(html, /<script src="\.\/notifications-screen\.js"><\/script>/,
  "notifications module must load before the main app script");
assert.match(html, /window\.PoyozzNotifications\?\.destroy\(\)/,
  "leaving the notifications page must dispose its observer");
assert.match(build, /'notifications-screen\.js'/,
  "notifications module must be included in Vercel static output");

const window = {};
vm.runInNewContext(source, { window });
const module = window.PoyozzNotifications;
assert.ok(Object.isFrozen(module), "notifications module API must be immutable");

const notifications = Array.from({ length: 12 }, (_, index) => ({
  id: String(index + 1),
  title: "通知 " + (index + 1),
  body: "內容 " + (index + 1),
  at: index,
  read: false,
}));
let markup = "";
let observerCallback = null;
let disconnectCount = 0;
const sentinel = {};
const deps = {
  route: { page: "notifications", unread: false },
  state: { notifications },
  $: selector => selector === "view"
    ? { set innerHTML(value) { markup = value; } }
    : selector === "notificationsSentinel" && markup.includes("notificationsSentinel")
      ? sentinel : null,
  e: value => String(value),
  timeText: value => "時間 " + value,
  PoyozzListPagination: {
    pageSize: () => 10,
    observeEnd: (node, callback) => {
      assert.equal(node, sentinel);
      observerCallback = callback;
      return { disconnect() { disconnectCount++; } };
    },
  },
};

module.render(deps);
assert.equal((markup.match(/class="notice"/g) || []).length, 10,
  "initial notifications render must be limited to ten rows");
assert.match(markup, /notificationsSentinel/,
  "a next-page sentinel must appear when more notifications exist");
assert.equal(typeof observerCallback, "function");
observerCallback();
assert.equal((markup.match(/class="notice"/g) || []).length, 12,
  "loading the next page must reveal the remaining notifications");
assert.doesNotMatch(markup, /notificationsSentinel/,
  "the sentinel must disappear after the last page is loaded");
module.destroy();
assert.ok(disconnectCount >= 1, "destroy must disconnect the active observer");

deps.route.unread = true;
module.render(deps);
assert.equal((markup.match(/class="notice"/g) || []).length, 0,
  "unread-only filter must show no rows when all notifications are already read");
module.destroy();

console.log("Notifications screen module contract passed.");
