const { readFileSync, writeFileSync } = require('node:fs');
const { join, resolve } = require('node:path');

const root = resolve(process.argv[2]);
if (!readFileSync(join(root, 'Cargo.toml'), 'utf8').includes('version = "1.5.3"')) {
  throw new Error('Expected RustDesk 1.5.3');
}

function change(file, replacements) {
  const path = join(root, file);
  let text = readFileSync(path, 'utf8').replaceAll('\r\n', '\n');
  for (const [before, after] of replacements) {
    const found = typeof before === 'string' ? text.includes(before) : before.test(text);
    if (!found) {
      throw new Error(`Expected source in ${file}: ${before}`);
    }
    text = text.replaceAll(typeof before === 'string' ? before : new RegExp(before, 'g'), after);
  }
  writeFileSync(path, text);
}

change('libs/hbb_common/src/config.rs', [
  ['ORG: RwLock<String> = RwLock::new("com.carriez"', 'ORG: RwLock<String> = RwLock::new("com.hoemr"'],
  ['APP_NAME: RwLock<String> = RwLock::new("RustDesk"', 'APP_NAME: RwLock<String> = RwLock::new("Desklink"'],
  // Use the upstream mobile ID range, which is disjoint from stock desktop IDs.
  [/    fn get_auto_id\(\) -> Option<String> \{[\s\S]*?\n    \}\n\n    pub fn get_auto_password/,
    `    fn get_auto_id() -> Option<String> {
        Some(
            rand::thread_rng()
                .gen_range(1_000_000_000..2_000_000_000)
                .to_string(),
        )
    }

    pub fn get_auto_password`],
]);

change('src/platform/macos.rs', [
  ['    s = s.replace("rustdesk",', '    s = s.replace("com.carriez.", "com.hoemr.");\n    s = s.replace("rustdesk",'],
  ['com.carriez.{}_', 'com.hoemr.{}_'],
]);

change('src/platform/windows.rs', [
  ['dir.join("rustdesk.exe")', 'dir.join("desklink.exe")'],
]);

change('src/privacy_mode/win_topmost_window.rs', [
  ['RuntimeBroker_rustdesk.exe', 'RuntimeBroker_desklink.exe'],
]);

change('src/platform/windows/verified_update.rs', [
  ['rustdesk-verified-', 'desklink-verified-'],
]);

change('libs/portable/src/main.rs', [
  ['RuntimeBroker_rustdesk.exe', 'RuntimeBroker_desklink.exe'],
  ['rustdesk-verified-', 'desklink-verified-'],
]);
