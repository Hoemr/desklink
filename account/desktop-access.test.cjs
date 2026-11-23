const assert = require('node:assert/strict');
const { mkdtempSync, rmSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { test } = require('node:test');
const { enrollments, issue, passwordFor } = require('./desktop-access.cjs');

const device = { id: '1234567890', key: '01'.repeat(32) };
const binding = 'node//mini';

test('credentials are tied to a device and a time slot', () => {
  const password = passwordFor(device, 90_000);
  assert.equal(password, '4f7f902708a466309ab3fc78414732057e4b1c8bf4d5446f3370452f0cd08563');
  assert.equal(passwordFor(device, 119_999), password);
  assert.notEqual(passwordFor(device, 120_000), password);
  assert.notEqual(passwordFor({ ...device, id: '1234567891' }, 90_000), password);
});

test('only authorized accounts receive credentials for enrolled nodes', (t) => {
  const datapath = mkdtempSync(join(tmpdir(), 'desklink-account-test-'));
  t.after(() => rmSync(datapath, { recursive: true, force: true }));
  const path = join(datapath, 'desklink-devices.json');
  writeFileSync(path, JSON.stringify({ [binding]: device, 'node//broken': { id: 'spoof@server', key: device.key } }));
  assert.deepEqual([...enrollments(datapath).keys()], [binding]);

  const user = { _id: 'user//owner' };
  const domain = { id: '' };
  let rights = 8;
  let visible = true;
  const parent = {
    parent: { datapath },
    users: { [user._id]: user },
    meshes: { 'mesh//home': {} },
    GetNodeWithRights(authDomain, actor, nodeId, callback) {
      assert.equal(authDomain, domain);
      assert.equal(actor, user);
      callback({ _id: nodeId, meshid: 'mesh//home' }, rights, visible);
    },
  };
  function request(nodeId = binding) {
    let result;
    issue(parent, domain, user, nodeId, (value) => { result = value; });
    return result;
  }
  const access = request();
  assert.equal(access.id, device.id);
  assert.match(access.password, /^[0-9a-f]{64}$/);
  assert.notEqual(access.password, device.key);
  assert.equal(request('node//unregistered'), null);

  for (const deniedRights of [0, 8 | 256, 8 | 1024, 8 | 4096, 8 | 65536]) {
    rights = deniedRights;
    assert.equal(request(), null);
  }
  rights = 8;
  visible = false;
  assert.equal(request(), null);
  visible = true;
  domain.userconsentflags = 8;
  assert.equal(request(), null);
  domain.userconsentflags = 0;
  user.siteadmin = 32;
  assert.equal(request(), null);
  user.siteadmin = 0;
  writeFileSync(path, '{}');
  assert.equal(request(), null);
  delete parent.users[user._id];
  assert.equal(request(), null);
});
