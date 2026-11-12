import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const outputDir = path.join(process.cwd(), 'dist');
const expectedFiles = [
  'LOGO_WEBICON.webp',
  'LOGO_WEBLOGO.webp',
  'encounter-default-scene.webp',
  'index.html',
  'memory-capture.js',
].sort();

assert.ok(fs.existsSync(outputDir), 'Vercel output directory must exist.');
const actualFiles = fs.readdirSync(outputDir).sort();
assert.deepEqual(actualFiles, expectedFiles, 'Vercel output must contain only the runtime allowlist.');

const html = fs.readFileSync(path.join(outputDir, 'index.html'), 'utf8');
const references = new Set();

for (const match of html.matchAll(/(?:src|href)\s*=\s*[\"']((?:\.\/|\/)[^\"'?#]+)[\"']/gi)) {
  references.add(match[1]);
}

for (const match of html.matchAll(/[\"'\x60](\.\/[^\"'\x60\s?#]+\.(?:webp|png|jpe?g|svg|js|css|json))[\"'\x60]/gi)) {
  references.add(match[1]);
}

for (const reference of references) {
  const relativePath = reference.replace(/^\.\//, '').replace(/^\//, '');
  assert.ok(fs.existsSync(path.join(outputDir, relativePath)), 'Local runtime reference is missing from Vercel output: ' + reference);
}

assert.ok(html.includes('memory-capture.js'), 'The memory capture script must remain referenced.');
assert.ok(html.includes('LOGO_WEBICON.webp'), 'The WebP favicon must remain referenced.');
assert.ok(html.includes('LOGO_WEBLOGO.webp'), 'The WebP logo must remain referenced.');
assert.ok(html.includes('encounter-default-scene.webp'), 'The encounter scene must remain referenced.');

for (const excluded of ['.github', 'docs', 'scripts', 'supabase', 'LOGO_WEBICON.png', 'LOGO_WEBLOGO.png']) {
  assert.ok(!actualFiles.includes(excluded), 'Repository-only content must not be deployed: ' + excluded);
}

console.log('Vercel static output verified: ' + actualFiles.length + ' files, ' + references.size + ' local references resolved.');
