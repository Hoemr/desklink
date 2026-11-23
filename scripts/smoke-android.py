import hashlib
import io
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
from urllib.parse import parse_qs, urlsplit
import xml.etree.ElementTree as ET
from contextlib import ExitStack, suppress
from pathlib import Path

from PIL import Image


WORK = Path(sys.argv[1])
REPORT = WORK / "reports"
PACKAGE = "com.carriez.flutter_hbb"
PASSWORD = "DesklinkFixture2026"
FIXTURE_ID = "42420042"


def adb(*args):
    return subprocess.check_output(["adb", *args], timeout=30)


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def ui():
    adb("shell", "uiautomator", "dump", "/sdcard/window.xml")
    xml = REPORT / "latest.xml"
    adb("pull", "/sdcard/window.xml", str(xml))
    return list(ET.parse(xml).iter("node"))


def tap_node(node):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
    tap((x1 + x2) // 2, (y1 + y2) // 2)


def wait_for(probe, description, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = probe()
            if isinstance(value, ET.Element) or value:
                return value
        except (OSError, subprocess.CalledProcessError, ET.ParseError):
            pass
        time.sleep(0.5)
    raise RuntimeError(f"Timed out waiting for {description}")


def label(*texts):
    return next((node for node in ui() if node.get("text") in texts or node.get("content-desc") in texts), None)


def password_field():
    nodes = ui()
    labels = {node.get("text"): node for node in nodes}
    if "Got it" in labels:
        tap_node(labels["Got it"])
        return None
    if "Pixel Launcher isn't responding" in labels and "Close app" in labels:
        tap_node(labels["Close app"])
        return None
    return next((node for node in nodes if node.get("password") == "true"), None)


def screenshot(name):
    path = REPORT / f"{name}.png"
    path.write_bytes(adb("exec-out", "screencap", "-p"))
    return Image.open(io.BytesIO(path.read_bytes())).convert("RGB")


def remote_frame():
    image = screenshot("desktop")
    width, height = image.size
    sample = image.crop((width // 4, height // 3, 3 * width // 4, 2 * height // 3))
    colors = sample.resize((40, 40)).getdata()
    return sum(r > 125 and g < 100 and b > 130 for r, g, b in colors) > 300


def tcp_ready():
    with socket.create_connection(("127.0.0.1", 21118), timeout=2) as conn:
        return conn.recv(64)


def keyboard_visible():
    state = adb("shell", "dumpsys", "input_method")
    (REPORT / "input-method.txt").write_bytes(state)
    return b"mInputShown=true" in state


def verify_file_download(desktop_link, expected):
    adb("shell", "am", "force-stop", PACKAGE)
    adb("shell", "appops", "set", "--uid", PACKAGE, "MANAGE_EXTERNAL_STORAGE", "allow")
    link = desktop_link.replace("rustdesk://connection/new/", "rustdesk://file-transfer/", 1)
    adb("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", link, "-p", PACKAGE)

    def open_remote():
        if remote := label("Remote"):
            tap_node(remote)
            return True
        if password := password_field():
            tap_node(password)
            adb("shell", "input", "text", PASSWORD)
            tap_node(wait_for(lambda: label("OK", "Confirm"), "file transfer password confirmation"))
        return False

    wait_for(open_remote, "file manager remote side", 40)
    row = wait_for(lambda: label(expected.name), "remote file", 30)
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", row.get("bounds")))
    x, y = str((x1 + x2) // 2), str((y1 + y2) // 2)
    adb("shell", "input", "swipe", x, y, x, y, "700")
    tap_node(wait_for(lambda: label("Local"), "file manager local side"))
    tap_node(wait_for(lambda: label("Paste here?"), "file transfer paste action"))
    want = hashlib.sha256(expected.read_bytes()).digest()

    def transferred():
        paths = adb("shell", "find", "/sdcard/", "-name", expected.name, "-type", "f").decode().splitlines()
        return any(hashlib.sha256(adb("exec-out", "dd", f"if={path}", "status=none")).digest() == want for path in paths)

    wait_for(transferred, "downloaded file SHA-256", 30)
    screenshot("file-transfer")
    print("PASS Android file manager downloads the host file with matching SHA-256", flush=True)


def fixture(log):
    import tkinter as tk

    root = tk.Tk()
    root.configure(background="#ae32b1")
    root.geometry("800x600+0+0")
    root.overrideredirect(True)
    value = tk.StringVar()
    value.trace_add("write", lambda *_: (log / "typed.txt").write_text(value.get(), encoding="utf-8"))
    tk.Label(root, text="Desklink Android fixture", bg="#ae32b1", fg="white", font=("Sans", 28)).pack(pady=25)
    entry = tk.Entry(root, textvariable=value)
    entry.pack()
    entry.focus_force()

    def log_button(event):
        with (log / "mouse.txt").open("a", encoding="utf-8") as file:
            file.write(f"button {event.num}\n")

    root.bind_all("<ButtonPress>", log_button)
    root.mainloop()


def main():
    relay = os.environ.get("DESKLINK_TEST_ROUTE") == "relay"
    target = FIXTURE_ID if relay else "127.0.0.1:21118"
    config = WORK / "desklink.json"
    devices = {"devices": [{"name": "fixture", "id": target}]}
    os.environ["XDG_CONFIG_HOME"] = str((WORK / "fixture-config").resolve())
    rustdesk_config = Path(os.environ["XDG_CONFIG_HOME"]) / "rustdesk"
    rustdesk_config.mkdir(parents=True, exist_ok=True)

    with ExitStack() as stack:
        expected = Path.home() / "desklink-transfer-fixture.bin"
        expected.write_bytes(os.urandom(2 * 1024 * 1024))
        stack.callback(expected.unlink, missing_ok=True)
        def start(name, *args, cwd=None, env=None):
            log = stack.enter_context((REPORT / f"{name}.log").open("wb"))
            child = subprocess.Popen(args, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
            stack.callback(child.terminate)

        host_options = {'direct-server': 'Y', 'custom-rendezvous-server': '127.0.0.1:29997'}
        host_identity = f'password = "{PASSWORD}"\n'
        if relay:
            server = WORK / "amd64"
            state = WORK / "relay-state"
            state.mkdir()
            start("hbbs", str(server / "hbbs"), "-r", "127.0.0.1:21117", "-k", "_", cwd=state,
                  env={**os.environ, "ALWAYS_USE_RELAY": "Y", "RUST_LOG": "debug"})
            key = wait_for(lambda: (state / "id_ed25519.pub").read_text().strip(), "self-hosted server public key")
            start("hbbr", str(server / "hbbr"), "-k", "_", cwd=state)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
                route.connect(("192.0.2.1", 9))
                relay_ip = route.getsockname()[0]
            # hbbr reserves raw TCP from loopback for its local console. Relay
            # the emulator-facing local port through the runner's normal IP.
            start("relay-forward", "socat", "TCP-LISTEN:22117,bind=127.0.0.1,reuseaddr,fork", f"TCP:{relay_ip}:21117")
            devices.update(id_server="127.0.0.1:21116", server_key=key)
            host_options = {'direct-server': 'N', 'custom-rendezvous-server': '127.0.0.1:21116',
                            'relay-server': f'{relay_ip}:21117', 'key': key}
            host_identity += f'id = "{FIXTURE_ID}"\n'

        config.write_text(json.dumps(devices), encoding="utf-8")
        host_options.update({'approve-mode': 'password', 'verification-method': 'use-permanent-password',
                             'enable-audio': 'N', 'enable-lan-discovery': 'N'})
        (rustdesk_config / "RustDesk.toml").write_text(host_identity, encoding="utf-8")
        (rustdesk_config / "RustDesk2.toml").write_text(
            '[options]\n' + ''.join(f'{name} = "{value}"\n' for name, value in host_options.items()), encoding="utf-8"
        )

        os.environ.update(DISPLAY=":137", XDG_SESSION_TYPE="x11", RUSTDESK_FORCED_DISPLAY_SERVER="x11")
        start("xvfb", "Xvfb", ":137", "-screen", "0", "800x600x24", "-nolisten", "tcp")
        wait_for(lambda: not subprocess.run(["xdpyinfo"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode, "Xvfb")
        start("fixture", sys.executable, __file__, str(WORK), "host")
        start("rustdesk", "dbus-run-session", "--", "/usr/bin/rustdesk", "--server")
        if relay:
            wait_for(lambda: f"update_pk {FIXTURE_ID} " in (REPORT / "hbbs.log").read_text(), "fixture registration with hbbs")
        else:
            wait_for(tcp_ready, "RustDesk direct IP listener")
        start("panel", str(WORK / "desklink"), "-config", str(config), "panel")
        html = wait_for(lambda: urllib.request.urlopen("http://127.0.0.1:22180/", timeout=2).read(), "Desklink panel")
        href = re.search(rb'href="(rustdesk://connection/new/[^"]+)"', html).group(1).decode()
        if relay:
            profile = json.loads(subprocess.check_output([str(WORK / "desklink"), "-config", str(config), "profile"]))
            link = urlsplit(href)
            assert link.path == f'/new/{target}@{profile["host"]}'
            assert parse_qs(link.query) == {"key": [profile["key"]]}
        else:
            assert href == f"rustdesk://connection/new/{target}", href

        adb("install", "-g", str(WORK / "rustdesk.apk"))
        adb("shell", "settings", "put", "global", "hide_error_dialogs", "1")
        adb("shell", "settings", "put", "secure", "immersive_mode_confirmations", "confirmed")
        adb("shell", "wm", "size", "480x960")
        adb("shell", "wm", "density", "160")
        adb("shell", "settings", "put", "system", "accelerometer_rotation", "0")
        adb("shell", "settings", "put", "system", "user_rotation", "0")
        if relay:
            adb("reverse", "tcp:21115", "tcp:21115")
            adb("reverse", "tcp:21116", "tcp:21116")
            adb("reverse", "tcp:21117", "tcp:22117")
        else:
            adb("reverse", "tcp:21118", "tcp:21118")
        print(adb("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", href, "-p", PACKAGE).decode(), flush=True)

        password = wait_for(password_field, "RustDesk password field")
        screenshot("password")
        tap_node(password)
        adb("shell", "input", "text", PASSWORD)
        accept = wait_for(lambda: label("OK", "Confirm"), "password confirmation")
        tap_node(accept)
        wait_for(remote_frame, "coloured remote desktop frame", 35)
        print("PASS Android receives a live X11 desktop from the Desklink link", flush=True)
        if relay:
            wait_for(lambda: "got paired" in (REPORT / "hbbr.log").read_text(), "hbbr pairing both RustDesk peers")
            print("PASS self-hosted hbbs registers the host and hbbr relays its desktop", flush=True)

        # These controls are unlabeled in the RustDesk 1.5.3 accessibility tree.
        # Use their verified positions on the pinned 480x960, 160 dpi viewport.
        tap(168, 936)
        tap_node(wait_for(lambda: label("Touch mode"), "Touch mode"))
        control = wait_for(lambda: label("Show virtual mouse"), "virtual mouse toggle")
        tap_node(control)
        screenshot("gesture-settings")
        ui()
        (REPORT / "gesture-settings.xml").write_bytes((REPORT / "latest.xml").read_bytes())
        screenshot("virtual-mouse")
        tap(264, 468)
        wait_for(lambda: (REPORT / "mouse.txt").read_text().count("button 3") > 0, "virtual right-click on the X11 host")
        print("PASS Android virtual mouse sends a right-click", flush=True)

        tap(440, 558)  # Close the gesture help sheet using its floating button.
        wait_for(lambda: label("Show virtual mouse") is None, "gesture help to close")
        tap(120, 936)  # Open the remote session's keyboard.
        wait_for(keyboard_visible, "Android soft keyboard")
        screenshot("keyboard")
        # Tap d, e, s, k in the emulator's US QWERTY soft keyboard.
        for x, y in [(144, 762), (119, 704), (96, 762), (382, 762)]:
            tap(x, y)
        wait_for(lambda: (REPORT / "typed.txt").read_text() == "desk", "soft-key taps on the remote desktop")
        screenshot("keyboard-result")
        print("PASS Android on-screen keyboard taps type 'desk' on the desktop", flush=True)
        verify_file_download(href, expected)


if len(sys.argv) > 2 and sys.argv[2] == "host":
    fixture(REPORT)
else:
    serial = adb("get-serialno").decode().strip()
    if not re.fullmatch(r"emulator-\d+", serial):
        raise RuntimeError("The smoke test requires an Android emulator")
    try:
        main()
    except Exception:
        with suppress(OSError, subprocess.SubprocessError):
            screenshot("failure")
        raise
