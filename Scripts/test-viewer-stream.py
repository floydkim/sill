#!/usr/bin/env python3
"""Exercise the real host, TLS pairing, HEVC rendering and pinned reconnect on loopback.

Synthetic frames only: no screen capture, Accessibility input or external Mac.
The integration test removes its temporary saved host record; the viewer's own
Keychain identity is created if it does not already exist.
"""
import os
from pathlib import Path
import pty
import re
import selectors
import subprocess
import time
import threading

root = Path(__file__).resolve().parent.parent
subprocess.run(["swift", "build", "--product", "SillHost"], cwd=root, check=True)
subprocess.run(["swift", "test", "list"], cwd=root, check=True, stdout=subprocess.DEVNULL)
bin_dir = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=root, text=True).strip()
master, slave = pty.openpty()
env = dict(os.environ, SILL_TEST_LOOPBACK="1")
host = subprocess.Popen([str(Path(bin_dir) / "SillHost"), "--synthetic", "--pairing", "--remote"],
                        cwd=root, env=env, stdout=slave, stderr=slave)
os.close(slave)
selector = selectors.DefaultSelector()
selector.register(master, selectors.EVENT_READ)
log = ""
reader_thread = None
try:
    until = time.monotonic() + 25
    code = port = None
    while time.monotonic() < until:
        if selector.select(timeout=1):
            log += os.read(master, 65536).decode(errors="replace")
            offer = re.search(r"Remote access for this run on port (\d+).*?Pair with ([\d ]+) or", log)
            if offer:
                port, code = offer.group(1), offer.group(2).strip()
                break
        if host.poll() is not None:
            break
    if not code:
        raise RuntimeError("Synthetic host did not offer pairing:\n" + log)
    def drain():
        while host.poll() is None:
            if selector.select(timeout=0.2):
                try:
                    chunk = os.read(master, 65536).decode(errors="replace")
                    with (root / ".build/viewer-test-host.log").open("a") as output:
                        output.write(chunk)
                except OSError:
                    break
    (root / ".build/viewer-test-host.log").write_text(log)
    reader_thread = threading.Thread(target=drain, daemon=True)
    reader_thread.start()
    env.update(SILL_VIEWER_TEST_ADDRESS=f"127.0.0.1:{port}", SILL_VIEWER_TEST_CODE=code)
    result = subprocess.run(["swift", "test", "--skip-build", "--filter", "ViewerIntegrationTests"],
                            cwd=root, env=env, timeout=75)
    raise SystemExit(result.returncode)
finally:
    host.terminate()
    try:
        host.wait(timeout=5)
    except subprocess.TimeoutExpired:
        host.kill()
        host.wait()
    if reader_thread is not None:
        reader_thread.join(timeout=2)
    selector.close()
    os.close(master)
