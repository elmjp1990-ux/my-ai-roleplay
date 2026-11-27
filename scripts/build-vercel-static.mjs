import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { build } from 'esbuild';

const root = process.cwd();
const outputDir = path.join(root, 'dist');
const generatedApiDir = path.join(root, 'api', '_generated');

// Vercel's function tracer previously left the Supabase shared TypeScript
// handler as a runtime import outside the function bundle. Bundle the complete
// local handler graph into the API directory before Vercel collects functions.
fs.mkdirSync(generatedApiDir, { recursive: true });
const handlerBuild = await build({
  entryPoints: [path.join(root, 'supabase/functions/_shared/encounter-schedule-organizer-handler.ts')],
  outfile: path.join(generatedApiDir, 'encounter-schedule-organizer-handler.mjs'),
  bundle: true,
  platform: 'node',
  format: 'esm',
  packages: 'external',
  target: 'node20',
  sourcemap: false,
  metafile: true,
});
const handlerOutput = handlerBuild.metafile.outputs[path.join('api/_generated/encounter-schedule-organizer-handler.mjs')]
  || Object.entries(handlerBuild.metafile.outputs).find(([file]) => file.endsWith('/api/_generated/encounter-schedule-organizer-handler.mjs'))?.[1];
if (!handlerOutput || handlerOutput.imports.some((item) => !item.external)) {
  throw new Error('Encounter schedule handler bundle still contains unresolved local runtime imports');
}
if (!fs.existsSync(path.join(generatedApiDir, 'encounter-schedule-organizer-handler.mjs'))) {
  throw new Error('Encounter schedule handler bundle was not emitted inside api/');
}
// Load the emitted ESM artifact in Node exactly as the Vercel Function will.
// Importing the module is safe: provider/database work starts only when the
// exported request handler is called.
const bundledHandler = await import(pathToFileURL(path.join(generatedApiDir, 'encounter-schedule-organizer-handler.mjs')).href);
if (typeof bundledHandler.handleEncounterScheduleOrganizer !== 'function') {
  throw new Error('Encounter schedule handler bundle failed its runtime export smoke test');
}
// Compile and invoke the actual API route with a synthetic GET request. This
// proves the route + local bundle can be loaded together while exiting before
// auth, database, or provider work; GET must return 405.
const routeSmokePath = path.join(generatedApiDir, 'encounter-schedule-route-smoke.mjs');
await build({
  entryPoints: [path.join(root, 'api/encounter-schedule-organizer.ts')],
  outfile: routeSmokePath,
  bundle: true,
  platform: 'node',
  format: 'esm',
  packages: 'external',
  target: 'node20',
  sourcemap: false,
});
const routeModule = await import(pathToFileURL(routeSmokePath).href);
if (typeof routeModule.default !== 'function') {
  throw new Error('Encounter schedule API route failed its runtime import smoke test');
}
const smokeResponse = {
  statusCode: 0,
  payload: null,
  setHeader() {},
  status(code) { this.statusCode = code; return this; },
  json(payload) { this.payload = payload; return this; },
};
await routeModule.default({ method: 'GET', headers: {}, url: '/api/encounter-schedule-organizer' }, smokeResponse);
if (smokeResponse.statusCode !== 405 || smokeResponse.payload?.error !== 'method_not_allowed') {
  throw new Error('Encounter schedule API route GET smoke test did not stop safely with 405');
}
fs.rmSync(routeSmokePath, { force: true });

// Explicit deployment allowlist. Keep repository tooling, SQL, drafts, and unused
// source assets in GitHub, but do not publish them as Vercel static files.
const runtimeFiles = [
  'index.html',
  'policy-center.html',
  'wallet-ui.js',
  'chat-keyboard-viewport.js',
  'poyozz-ui.css',
  'memory-album.css',
  'diary-ui.css',
  'wallet-ui.css',
  'group-author-forms.css',
  'group-wizard.css',
  'character-illustration-gallery.css',
  'chat-composer-states.css',
  'city-map-ui.css',
  'city-location-panel.css',
  'chat-layout-shell.css',
  'chat-keyboard-viewport.css',
  'memory-capture.js',
  'chat-render-lifecycle.js',
  'image-compression.js',
  'signed-url-manager.js',
  'core-utils.js',
  'city-map.js',
  'character-editor-cloud.js',
  'encounter-history.js',
  'followed-authors.js',
  'list-pagination.js',
  'notifications-screen.js',
  'author-profile.js',
  'comment-renderer.js',
  'custom-tag-picker.js',
  'memory-album.js',
  'encounter-scene.js',
  'encounter-scene.css',
  'group-opening-presets.js',
  'LOGO_WEBICON.webp',
  'LOGO_WEBLOGO.webp',
  'encounter-default-scene.webp',
];

fs.rmSync(outputDir, { recursive: true, force: true });
fs.mkdirSync(outputDir, { recursive: true });

for (const relativePath of runtimeFiles) {
  const source = path.join(root, relativePath);
  if (!fs.existsSync(source)) {
    throw new Error('Required Vercel runtime file is missing: ' + relativePath);
  }
  const sourceStat = fs.lstatSync(source);
  if (!sourceStat.isFile() || sourceStat.isSymbolicLink()) {
    throw new Error('Vercel runtime source must be a regular, non-symlink file: ' + relativePath);
  }
  fs.copyFileSync(source, path.join(outputDir, relativePath));
}

// Every local stylesheet linked by index.html must be present in the static output.
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const linkedStylesheets = [...html.matchAll(/<link\b(?=[^>]*\brel=["']stylesheet["'])(?=[^>]*\bhref=["']([^"'?#]+)["'])[^>]*>/gi)]
  .map(match => match[1].replace(/^\.\//, ''));
for (const stylesheet of linkedStylesheets) {
  if (path.isAbsolute(stylesheet) || stylesheet.split(/[\\/]/).includes('..')) {
    throw new Error('Unsafe local stylesheet path in index.html: ' + stylesheet);
  }
  if (!runtimeFiles.includes(stylesheet)) {
    throw new Error('Linked stylesheet is missing from Vercel runtime allowlist: ' + stylesheet);
  }
}

console.log('Prepared Vercel static output with ' + runtimeFiles.length + ' runtime files.');
