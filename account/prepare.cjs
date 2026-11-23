const { copyFileSync, readFileSync, renameSync, writeFileSync } = require('node:fs');
const { dirname, join } = require('node:path');
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

const meshUser = join(dirname(entry), 'meshuser.js');
const originalMeshUser = readFileSync(meshUser, 'utf8');
let meshSource = originalMeshUser;
function patchMesh(anchor, replacement) {
  if (meshSource.includes(replacement)) return;
  if (meshSource.split(anchor).length !== 2) throw new Error('MeshCentral device command handler changed');
  meshSource = meshSource.replace(anchor, replacement);
}

copyFileSync(join(__dirname, 'desktop-access.cjs'), join(dirname(entry), 'desklink-desktop-access.cjs'));
patchMesh("            case 'nodes':", `            case 'desklink-desktop-access':
                require('./desklink-desktop-access.cjs').issue(parent, domain, user, command.nodeid, (access) => {
                    try { ws.send(JSON.stringify({ action: 'desklink-desktop-access', access })); } catch {}
                });
                break;
            case 'nodes':`);
patchMesh('                        var r = {}, nodeCount = docs.length;', `                        const desklinkDevices = command.desklink === true ? require('./desklink-desktop-access.cjs').enrollments(parent.parent.datapath) : null;
                        var r = {}, nodeCount = docs.length;`);
patchMesh('                            r[meshid].push(docs[i]);', `                            if (desklinkDevices) docs[i].desklinkNative = desklinkDevices.has(docs[i]._id);
                            r[meshid].push(docs[i]);`);
if (meshSource !== originalMeshUser) {
  const staged = `${meshUser}.${process.pid}.tmp`;
  writeFileSync(staged, meshSource, { flag: 'wx' });
  renameSync(staged, meshUser);
}
