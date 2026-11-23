const { readFileSync, renameSync, writeFileSync } = require('node:fs');
const { overrides } = require('./package.json');

const entry = require.resolve('meshcentral');
const original = readFileSync(entry, 'utf8');
let source = original;

// MeshCentral 1.3.1 checks exact versions before starting its server.
for (const [name, upstream] of Object.entries({ compression: '1.8.1', express: '4.22.2', 'node-forge': '1.4.0' })) {
  const expected = `'${name}@${upstream}'`;
  const patched = `'${name}@${overrides[name]}'`;
  if (source.includes(patched)) continue;
  if (source.split(expected).length !== 2) throw new Error(`MeshCentral dependency check changed for ${name}`);
  source = source.replace(expected, patched);
}

if (source !== original) {
  const staged = `${entry}.${process.pid}.tmp`;
  writeFileSync(staged, source, { flag: 'wx' });
  renameSync(staged, entry);
}
