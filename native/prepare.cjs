const { execFileSync } = require('node:child_process');
const { copyFileSync, mkdirSync } = require('node:fs');
const { join, resolve } = require('node:path');

if (!process.argv[2]) throw new Error('Usage: node native/prepare.cjs <RustDesk 1.5.3 checkout>');
const checkout = resolve(process.argv[2]);
const git = (...args) => execFileSync('git', ['-C', checkout, ...args], { encoding: 'utf8' }).trim();
if (git('rev-parse', 'HEAD') !== '95cca3f661f635b3cc85c04935fe8d96d8f432ef') {
  throw new Error('Expected the RustDesk 1.5.3 release commit');
}

const patch = join(__dirname, 'connection.patch');
git('apply', '--check', patch);
const target = join(checkout, 'flutter', 'lib', 'desklink');
mkdirSync(target);
for (const file of ['desklink_account.dart', 'desklink_page.dart']) {
  copyFileSync(join(__dirname, 'lib', file), join(target, file));
}
git('apply', patch);
console.log(`Desklink applied to ${checkout}`);
