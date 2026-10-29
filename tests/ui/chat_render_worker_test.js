'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const { loadMarked } = require('../../lua/codeit/ui/chat_render.js');

test('loads CommonJS and ESM Marked constructors without external dependencies', async () => {
  // Spaces and URL-reserved characters also catch bare-path import failures.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'codeit marked #'));
  try {
    const fixtures = [
      ['commonjs.cjs', 'module.exports = Object.assign({}, { Marked: class Marked { parse() { return "cjs"; } } });', 'cjs'],
      ['named.cjs', 'exports.Marked = class Marked { parse() { return "named"; } };', 'named'],
      ['module.mjs', 'export class Marked { parse() { return "esm"; } }', 'esm'],
    ];
    for (const [name, source, expected] of fixtures) {
      const filename = path.join(dir, name);
      fs.writeFileSync(filename, source);
      const Marked = await loadMarked(filename);
      assert.equal(new Marked().parse(), expected);
    }
    const invalid = path.join(dir, 'invalid.cjs');
    fs.writeFileSync(invalid, 'module.exports = {};');
    await assert.rejects(loadMarked(invalid), /does not export a Marked constructor/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
