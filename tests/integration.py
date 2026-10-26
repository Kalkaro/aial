"""Real-model, offline smoke test. Run after the first model download."""
import json
import os
from pathlib import Path
import queue
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


class Backend:
    def __init__(self, environment, log):
        self.messages = queue.Queue()
        self.process = subprocess.Popen(
            [sys.executable, "-u", str(ROOT / "backend.py")], env=environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True,
        )
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            self.messages.put(json.loads(line))

    def send(self, **message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def wait(self, predicate, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if message.get("phase") == "error" or message["type"] == "error":
                raise AssertionError(message)
            if predicate(message):
                return message
        raise TimeoutError("Backend did not produce the expected event")

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
            raise AssertionError("The backend did not exit after stdin closed")
        self.process.stdout.close()


def main():
    with tempfile.TemporaryDirectory(prefix="applesearch-test-") as directory:
        base = Path(directory)
        docs = base / "docs"
        docs.mkdir()
        (docs / "Weekend.txt").write_text("Purchase tomatoes, onions, basil, parmesan, and pasta at the supermarket.")
        (docs / "Connection.txt").write_text("Router IP addresses, ethernet cables and wireless connectivity.")
        (docs / "Evening.txt").write_text("Read a novel, turn off the lights and sleep for eight hours.")
        (docs / "ASD").mkdir()
        for number, topic in ((1, "correctness"), (2, "complexity"), (3, "searching")):
            (docs / "ASD" / f"0{number} - {topic}.txt").write_text(f"Algorithms: {topic}")
        (docs / "node_modules").mkdir()
        (docs / "node_modules/session-state.json").write_text("second asd")
        env = dict(os.environ, APPLESEARCH_PATHS=str(docs), APPLESEARCH_CACHE_DIR=str(base / "cache"),
                   XDG_CONFIG_HOME=str(base / "config"),
                   XDG_DATA_HOME=str(base / "data"), XDG_DATA_DIRS=str(base / "system"),
                   HF_HUB_OFFLINE="1", TOKENIZERS_PARALLELISM="false", APPLESEARCH_THREADS="2",
                   APPLESEARCH_EXCLUDE_PATHS="")
        # A deterministic opener records arguments instead of opening a real app.
        binaries = base / "bin"
        binaries.mkdir()
        opener = binaries / "xdg-open"
        opener.write_text(f'#!{sys.executable}\nimport json,sys\nopen({str(base / "opened.json")!r}, "w").write(json.dumps(sys.argv[1:]))\n')
        opener.chmod(0o755)
        capture = binaries / "capture-app"
        capture.write_text(f'#!{sys.executable}\nimport json,sys\nopen({str(base / "app.json")!r}, "w").write(json.dumps(sys.argv[1:]))\n')
        capture.chmod(0o755)
        applications = base / "data/applications"
        applications.mkdir(parents=True)
        desktop = applications / "probe.desktop"
        desktop.write_text(f'[Desktop Entry]\nType=Application\nName=Launch Probe\nExec="{capture}" "argument with spaces"\n')
        env["PATH"] = str(binaries) + os.pathsep + env["PATH"]
        if Path("/run/current-system/sw/share/nix-ld/lib").exists():
            env["LD_LIBRARY_PATH"] = "/run/current-system/sw/share/nix-ld/lib" + os.pathsep + env.get("LD_LIBRARY_PATH", "")
        with (base / "log").open("w+") as log:
            backend = Backend(env, log)
            try:
                backend.wait(lambda m: m["type"] == "ready")
                backend.wait(lambda m: m.get("phase") == "ready")
                start = time.monotonic()
                backend.send(action="search", id=1, query="cooking ingredients")
                result = backend.wait(lambda m: m["type"] == "results" and m["id"] == 1 and m["semantic"])
                elapsed = time.monotonic() - start
                assert result["results"][0]["title"] == "Weekend.txt", result
                print(f'Offline semantic retrieval: Weekend.txt ranked first ({elapsed * 1000:.0f} ms)')
                backend.send(action="search", id=5, query="second asd")
                numbered = backend.wait(lambda m: m["type"] == "results" and m["id"] == 5 and m["semantic"])
                assert [r["title"] for r in numbered["results"]] == ["02 - complexity.txt"], numbered
                print("Ordinal + folder retrieval: only the second ASD document returned")

                backend.send(action="open", id=str(docs / "Weekend.txt"), reveal=True)
                backend.wait(lambda m: m["type"] == "opened")
                deadline = time.monotonic() + 3
                while not (base / "opened.json").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                assert json.loads((base / "opened.json").read_text()) == [str(docs)]
                print("Result activation: containing directory passed intact to the opener")
                backend.send(action="search", id=4, query="launch probe")
                app = backend.wait(lambda m: m["type"] == "results" and m["id"] == 4)
                assert app["results"][0]["kind"] == "app"
                backend.send(action="open", id=str(desktop))
                backend.wait(lambda m: m["type"] == "opened")
                deadline = time.monotonic() + 3
                while not (base / "app.json").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                assert json.loads((base / "app.json").read_text()) == ["argument with spaces"]
                print("Application discovery and actual gio launch: passed")

                backend.send(action="active", value=True)
                (docs / "Delayed.txt").write_text("A document added while the search panel is open.")
                backend.send(action="refresh")
                backend.wait(lambda m: m["type"] == "index" and m["items"] == 8)
                backend.send(action="search", id=6, query="delayed")
                active_result = backend.wait(lambda m: m["type"] == "results" and m["id"] == 6 and m["semantic"])
                assert active_result["results"][0]["title"] == "Delayed.txt"
                connection = sqlite3.connect(base / "cache/index.sqlite3")
                assert connection.execute("SELECT vector FROM items WHERE title='Delayed.txt'").fetchone()[0] is None
                connection.close()
                backend.send(action="active", value=False)
                backend.wait(lambda m: m.get("phase") == "ready" and m["embedded"] == 8)
                print("Foreground queries run while document embedding is paused; indexing resumes on hide")
            finally:
                backend.close()

            # Restart against the same index with networking explicitly disabled.
            start = time.monotonic()
            backend = Backend(env, log)
            try:
                backend.wait(lambda m: m["type"] == "ready")
                backend.send(action="search", id=2, query="weekend")
                cached = backend.wait(lambda m: m["type"] == "results" and m["id"] == 2)
                assert cached["results"][0]["title"] == "Weekend.txt"
                print(f'Cold-process cached filename search: {(time.monotonic() - start) * 1000:.0f} ms')
                backend.wait(lambda m: m.get("phase") == "ready")
                start = time.monotonic()
                backend.send(action="search", id=3, query="cooking ingredients")
                cached = backend.wait(lambda m: m["type"] == "results" and m["id"] == 3 and m["semantic"])
                assert cached["results"][0]["title"] == "Weekend.txt"
                print(f'Restarted-process cached semantic search: {(time.monotonic() - start) * 1000:.0f} ms')
                connection = sqlite3.connect(base / "cache/index.sqlite3")
                assert connection.execute("SELECT count(vector) FROM items").fetchone()[0] == 8
                assert connection.execute("SELECT count(*) FROM items WHERE id LIKE '%/node_modules/%'").fetchone()[0] == 0
                connection.close()
            finally:
                backend.close()


if __name__ == "__main__":
    main()
