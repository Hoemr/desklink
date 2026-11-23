const { copyFileSync, readFileSync, writeFileSync } = require('node:fs');
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

change('src/updater.rs', [
  ['fn check_update(manually: bool) -> ResultType<()> {',
    'fn check_update(manually: bool) -> ResultType<()> {\n    if crate::is_custom_client() {\n        return Ok(());\n    }'],
  ['/var/run/rustdesk-update.lock', '/var/run/desklink-update.lock'],
]);

copyFileSync(join(__dirname, 'account-access.rs'), join(root, 'src/desklink_account.rs'));
change('src/lib.rs', [['mod auth_2fa;', 'mod auth_2fa;\nmod desklink_account;']]);

change('src/server/connection.rs', [
  ['    SwitchSides = 4,', '    SwitchSides = 4,\n    DesklinkAccount = 5,'],
  [/ipc::Data::Authorize => \{[\s\S]*?(?=                        ipc::Data::Close =>)/,
    'ipc::Data::Authorize => {}\n'],
  [/            #\[cfg\(not\(any\(target_os = "android", target_os = "ios"\)\)\)\]\n            if !should_use_terminal_os_login_scope\(self\.terminal, &lr\.os_login\.username\) \{[\s\S]*?(?=        \} else if let Some\(message::Union::Auth2fa\(tfa\)\) = msg\.union \{)/,
    `            let account_scope = matches!(
                self.lr.union.as_ref(),
                None | Some(login_request::Union::FileTransfer(_))
            );
            let id = Config::get_id();
            let authorized = account_scope
                && lr.username == id
                && crate::desklink_account::session_passwords(&id).is_some_and(|passwords| {
                    passwords.iter().any(|password| self.validate_password_plain(password))
                });
            if !authorized {
                self.send_login_error("Open this device from your Desklink account to connect.").await;
                return false;
            }
            self.require_2fa = None;
            self.set_conn_audit_primary_auth(ConnAuditPrimaryAuth::DesklinkAccount);
            self.try_start_cm_ipc();
            if !self.send_logon_response_and_keep_alive().await {
                return false;
            }
            self.try_start_cm(lr.my_id, lr.my_name, self.authorized);
`],
  [/        \} else if let Some\(message::Union::SwitchSidesResponse\(_s\)\) = msg\.union \{[\s\S]*?(?=        \} else if self\.authorized \{)/,
    '        } else if matches!(msg.union.as_ref(), Some(message::Union::SwitchSidesResponse(_))) {\n            return false;\n'],
]);

change('libs/portable/src/main.rs', [
  ['RuntimeBroker_rustdesk.exe', 'RuntimeBroker_desklink.exe'],
  ['rustdesk-verified-', 'desklink-verified-'],
]);
