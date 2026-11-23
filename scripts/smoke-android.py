import io
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from contextlib import ExitStack, suppress
from pathlib import Path

from PIL import Image


WORK = Path(sys.argv[1])
REPORT = WORK / "reports"
PACKAGE = "com.carriez.flutter_hbb"
PASSWORD = "DesklinkFixture2026"


def adb(*args):
    return subprocess.check_output(["adb", *args], timeout=30)


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def ui():
    adb("shell", "uiautomator", "dump", "/sdcard/window.xml")
    xml = adb("exec-out", "cat", "/sdcard/window.xml")
    (REPORT / "latest.xml").write_bytes(xml)
    return list(ET.fromstring(xml).iter("node"))


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
    hint = next((node for node in nodes if node.get("text") == "Got it"), None)
    if hint is not None:
        tap_node(hint)
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
    host = "10.0.2.2:21118"
    config = WORK / "desklink.json"
    config.write_text(json.dumps({"devices": [{"name": "fixture", "id": host}]}), encoding="utf-8")
    rustdesk_config = Path.home() / ".config/rustdesk"
    rustdesk_config.mkdir(parents=True, exist_ok=True)
    (rustdesk_config / "RustDesk.toml").write_text(f'password = "{PASSWORD}"\n', encoding="utf-8")
    (rustdesk_config / "RustDesk2.toml").write_text(
        '[options]\ndirect-server = "Y"\napprove-mode = "password"\n'
        'verification-method = "use-permanent-password"\ncustom-rendezvous-server = "127.0.0.1:29997"\n'
        'enable-audio = "N"\nenable-lan-discovery = "N"\n', encoding="utf-8"
    )

    with ExitStack() as stack:
        def start(name, *args):
            log = stack.enter_context((REPORT / f"{name}.log").open("wb"))
            child = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
            stack.callback(child.terminate)

        os.environ.update(DISPLAY=":137", XDG_SESSION_TYPE="x11", RUSTDESK_FORCED_DISPLAY_SERVER="x11")
        start("xvfb", "Xvfb", ":137", "-screen", "0", "800x600x24", "-nolisten", "tcp")
        wait_for(lambda: not subprocess.run(["xdpyinfo"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode, "Xvfb")
        start("fixture", sys.executable, __file__, str(WORK), "host")
        start("rustdesk", "dbus-run-session", "--", "/usr/bin/rustdesk", "--server")
        wait_for(tcp_ready, "RustDesk direct IP listener")
        start("panel", str(WORK / "desklink"), "-config", str(config), "panel")
        html = wait_for(lambda: urllib.request.urlopen("http://127.0.0.1:22180/", timeout=2).read(), "Desklink panel")
        href = re.search(rb'href="(rustdesk://connection/new/[^"]+)"', html).group(1).decode()
        assert href == f"rustdesk://connection/new/{host}", href

        adb("install", "-g", str(WORK / "rustdesk.apk"))
        adb("shell", "wm", "size", "480x960")
        adb("shell", "wm", "density", "160")
        adb("shell", "settings", "put", "system", "accelerometer_rotation", "0")
        adb("shell", "settings", "put", "system", "user_rotation", "0")
        print(adb("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", href, "-p", PACKAGE).decode(), flush=True)

        password = wait_for(password_field, "RustDesk password field")
        screenshot("password")
        tap_node(password)
        adb("shell", "input", "text", PASSWORD)
        accept = wait_for(lambda: label("OK", "Confirm"), "password confirmation")
        tap_node(accept)
        wait_for(remote_frame, "coloured remote desktop frame", 35)
        print("PASS Android receives a live X11 desktop from the Desklink link", flush=True)

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
        tap(120, 936)  # Open the remote session's keyboard.
        wait_for(keyboard_visible, "Android soft keyboard")
        screenshot("keyboard")
        # Tap d, e, s, k in the emulator's US QWERTY soft keyboard.
        for x, y in [(144, 762), (119, 704), (96, 762), (382, 762)]:
            tap(x, y)
        wait_for(lambda: (REPORT / "typed.txt").read_text() == "desk", "soft-key taps on the remote desktop")
        screenshot("keyboard-result")
        print("PASS Android on-screen keyboard taps type 'desk' on the desktop", flush=True)


if len(sys.argv) > 2 and sys.argv[2] == "host":
    fixture(REPORT)
else:
    try:
        main()
    except Exception:
        with suppress(OSError, subprocess.SubprocessError):
            screenshot("failure")
        raise
