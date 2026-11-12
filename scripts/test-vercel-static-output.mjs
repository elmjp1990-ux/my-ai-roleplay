import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const outputDir = path.join(root, 'dist');
const fileBudgets = {
  'LOGO_WEBICON.webp': 20_000,
  'LOGO_WEBLOGO.webp': 40_000,
  'encounter-default-scene.webp': 350_000,
  'index.html': 900_000,
  'memory-capture.js': 12_000,
};
const expectedFiles = Object.keys(fileBudgets).sort();
const assetExtensions = '(?:webp|png|jpe?g|svg|js|css|json|ico|woff2?|ttf|mp4|webm|avif)';

const vercelConfig = JSON.parse(fs.readFileSync(path.join(root, 'vercel.json'), 'utf8'));
assert.equal(vercelConfig.buildCommand, 'node scripts/build-vercel-static.mjs');
assert.equal(vercelConfig.outputDirectory, 'dist');

assert.ok(fs.existsSync(outputDir), 'Vercel output directory must exist.');
const actualFiles = fs.readdirSync(outputDir).sort();
assert.deepEqual(actualFiles, expectedFiles, 'Vercel output must contain only the runtime allowlist.');

let totalBytes = 0;
for (const [file, maxBytes] of Object.entries(fileBudgets)) {
  const filePath = path.join(outputDir, file);
  const stat = fs.lstatSync(filePath);
  assert.ok(stat.isFile() && !stat.isSymbolicLink(), 'Runtime output must be a regular file: ' + file);
  assert.ok(stat.size > 0, 'Runtime output must not be empty: ' + file);
  assert.ok(stat.size <= maxBytes, file + ' exceeds its individual deployment budget: ' + stat.size + ' > ' + maxBytes);
  totalBytes += stat.size;
}
assert.ok(totalBytes <= 1_500_000, 'Vercel static output exceeds the 1.5 MB deployment budget: ' + totalBytes + ' bytes.');

const html = fs.readFileSync(path.join(outputDir, 'index.html'), 'utf8');
const references = new Set();
const addReference = (value) => {
  if (!value || value.startsWith('data:') || value.startsWith('blob:') || value.startsWith('http:') || value.startsWith('https:')) return;
  const clean = value.split(/[?#]/, 1)[0].trim();
  if (!clean || !/^(?:\.\/|\/)/.test(clean) || !new RegExp('\\.' + assetExtensions + '$', 'i').test(clean)) return;
  references.add(clean);
};

// HTML resource attributes, including responsive image candidates.
for (const tag of html.matchAll(/<[a-z][^>]*>/gi)) {
  for (const attr of tag[0].matchAll(/\b(?:src|href|poster|data-src|data-href)\s*=\s*["']([^"']+)["']/gi)) {
    addReference(attr[1]);
  }
  for (const attr of tag[0].matchAll(/\bsrcset\s*=\s*["']([^"']+)["']/gi)) {
    for (const candidate of attr[1].split(',')) addReference(candidate.trim().split(/\s+/)[0]);
  }
}

// CSS url() references in style blocks and inline style attributes only.
for (const styleBlock of html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)) {
  for (const url of styleBlock[1].matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/gi)) addReference(url[1]);
}
for (const styleAttr of html.matchAll(/\bstyle\s*=\s*["']([^"']*)["']/gi)) {
  for (const url of styleAttr[1].matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/gi)) addReference(url[1]);
}

// Literal local asset paths in inline and external runtime JavaScript.
const runtimeJs = [html, fs.readFileSync(path.join(outputDir, 'memory-capture.js'), 'utf8')];
const localAssetPatterns = [
  new RegExp('"((?:\\.\\/|\\/)[^"\\s?#]+' + assetExtensions + ')"', 'gi'),
  new RegExp("'((?:\\.\\/|\\/)[^'\\s?#]+" + assetExtensions + ")'", 'gi'),
  new RegExp('`((?:\\.\\/|\\/)[^`\\s?#]+' + assetExtensions + ')`', 'gi'),
];
for (const source of runtimeJs) {
  for (const pattern of localAssetPatterns) {
    for (const match of source.matchAll(pattern)) addReference(match[1]);
  }
}

for (const reference of references) {
  const relativePath = reference.replace(/^\.\//, '').replace(/^\//, '');
  const resolved = path.resolve(outputDir, relativePath);
  assert.ok(resolved.startsWith(outputDir + path.sep), 'Runtime reference must not escape the output directory: ' + reference);
  assert.ok(fs.existsSync(resolved) && fs.statSync(resolved).isFile(), 'Local runtime reference is missing from Vercel output: ' + reference);
}

for (const required of ['LOGO_WEBICON.webp', 'LOGO_WEBLOGO.webp', 'encounter-default-scene.webp', 'memory-capture.js']) {
  assert.ok(references.has('./' + required) || references.has('/' + required) || html.includes(required),
    'Required runtime asset must remain referenced: ' + required);
}

for (const file of expectedFiles) {
  const bytes = fs.statSync(path.join(outputDir, file)).size;
  console.log('  ' + file + ': ' + bytes + ' bytes / ' + fileBudgets[file] + ' byte budget');
}
console.log(
  'Vercel static output verified: ' + actualFiles.length + ' files, ' +
  references.size + ' local asset references resolved, ' + totalBytes +
  ' bytes total. Individual and total file budgets passed.'
);
