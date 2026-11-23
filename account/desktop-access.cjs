const { createHmac } = require('node:crypto');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');

function enrollments(dataPath) {
  try {
    const entries = JSON.parse(readFileSync(join(dataPath, 'desklink-devices.json'), 'utf8'));
    return new Map(Object.entries(entries).filter(([node, device]) =>
      /^node\/[^/]*\/[^/]+$/.test(node) &&
      typeof device?.id === 'string' && /^[a-zA-Z0-9_-]{3,64}$/.test(device.id) &&
      typeof device?.key === 'string' && /^[0-9a-f]{64}$/.test(device.key)));
  } catch {
    return new Map();
  }
}

function passwordFor(device, now) {
  const slot = Math.floor(now / 30_000);
  return createHmac('sha256', Buffer.from(device.key, 'hex'))
    .update(`desklink-native-v1:${device.id}:${slot}`)
    .digest('hex');
}

function issue(parent, domain, user, nodeId, reply) {
  if (typeof nodeId !== 'string' || !parent.users[user._id]) return reply(null);
  parent.GetNodeWithRights(domain, parent.users[user._id], nodeId, (node, rights, visible) => {
    if (!node || !visible || !parent.users[user._id]) return reply(null);
    const remoteControl = 8;
    const restricted = 256 | 1024 | 4096 | 65536; // View only, no files, limited input, no desktop.
    if (rights !== 0xffffffff && (!(rights & remoteControl) || (rights & restricted))) return reply(null);
    const mesh = parent.meshes[node.meshid];
    const promptConsent = 8 | 32; // Desktop and files.
    if (!mesh || ((mesh.consent | domain.userconsentflags) & promptConsent)) return reply(null);
    const device = enrollments(parent.parent.datapath).get(node._id);
    reply(device ? { id: device.id, password: passwordFor(device, Date.now()) } : null);
  });
}

module.exports = { enrollments, issue, passwordFor };
