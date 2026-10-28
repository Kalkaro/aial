"""launch.sh's piped menus, against a stand-in qs that answers like the panel,
and its app launches, against stand-in commands."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

# Pretends to be Quickshell. Starting the daemon prints to stdout, as the real
# one does; ipc calls need a started instance. showMenu notes the images it is
# given, then answers with the line numbered FAKE_PICK, "cancel" cancels, and
# "never" leaves the menu open.
FAKE_QS = '''
import json, os, sys
from pathlib import Path
state = Path(os.environ["FAKE_QS_STATE"])
if sys.argv[1] != "ipc":
    print("No running instances")
    state.write_text(os.environ.get("APPLESEARCH_HIDDEN", ""))
    sys.exit(0)
if not state.exists():
    sys.exit(255)
call = sys.argv[sys.argv.index("spotlight") + 1:]
with open(f"{state}.calls", "a") as calls:
    calls.write(json.dumps(call) + "\\n")
if call[0] == "showMenu":
    images = Path(call[3])
    Path(f"{state}.images").write_text(json.dumps({image.name: image.read_text() for image in images.iterdir()}
                                                  if images.is_dir() else None))
    pick = os.environ["FAKE_PICK"]
    if pick != "never":
        lines = Path(call[1]).read_text().splitlines()
        Path(call[2] + ".tmp").write_text("cancelled\\n" if pick == "cancel" else f"selected\\n{lines[int(pick)]}\\n")
        os.replace(call[2] + ".tmp", call[2])
if call[0] in ("showMenu", "processId"):
    print(os.environ["FAKE_QS_PID"])
'''

# Stands in for systemd-run, a terminal or an app: records its arguments and
# working directory, then exits with STATUS.
FAKE_COMMAND = '''
import json, os, sys
from pathlib import Path
record = Path(os.environ["RECORDS"], Path(sys.argv[0]).name + ".json")
Path(f"{record}.tmp").write_text(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd()}))
os.replace(f"{record}.tmp", record)
sys.exit(STATUS)
'''

# Stands in for cliphist: decoding an ID prints "image ID", except for 404, an
# entry deleted since it was listed.
FAKE_CLIPHIST = '''
import sys
if sys.argv[1:2] != ["decode"] or sys.argv[2] == "404":
    sys.exit(1)
print(f"image {sys.argv[2]}", end="")
'''


class MenuTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        (base / "bin").mkdir()
        (base / "run").mkdir(mode=0o700)
        qs = base / "bin/qs"
        qs.write_text(f"#!{sys.executable}" + FAKE_QS)
        qs.chmod(0o755)
        self.state = base / "instance"
        self.runtime = base / "run"
        # The menu watches this process as the instance's.
        self.instance = subprocess.Popen(["sleep", "60"])
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("APPLESEARCH_")}
        self.env.update(PATH=f"{base / 'bin'}{os.pathsep}{os.environ['PATH']}", XDG_RUNTIME_DIR=str(self.runtime),
                        WAYLAND_DISPLAY="wayland-test", FAKE_QS_STATE=str(self.state),
                        FAKE_QS_PID=str(self.instance.pid), FAKE_PICK="1")

    def tearDown(self):
        self.instance.kill()
        self.instance.wait()
        self.temp.cleanup()

    def launch(self, *args, lines=None, pick="1"):
        return subprocess.Popen([str(ROOT / "launch.sh"), *args], env=dict(self.env, FAKE_PICK=pick), text=True,
                                stdin=subprocess.DEVNULL if lines is None else subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def menu(self, lines, *args, pick="1"):
        process = self.launch(*args, lines=lines, pick=pick)
        return process.communicate(lines, timeout=10)[0], process.returncode

    def calls(self):
        path = Path(f"{self.state}.calls")
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def images(self):
        """The files in the last menu's images folder when it opened."""
        return json.loads(Path(f"{self.state}.images").read_text())

    def wait_for_call(self, name):
        deadline = time.monotonic() + 10
        while not any(call[0] == name for call in self.calls()):
            self.assertLess(time.monotonic(), deadline, f"no {name} call")
            time.sleep(0.02)

    def test_piped_lines_print_the_chosen_one_and_nothing_else(self):
        output, code = self.menu("1\tfirst\n2\tsecond  with\ttabs\n")
        # Even when the menu starts the instance, its log stays off stdout.
        self.assertEqual((output, code), ("2\tsecond  with\ttabs\n", 0))
        self.assertEqual(self.state.read_text(), "1", "a menu starts the panel hidden")
        show = next(call for call in self.calls() if call[0] == "showMenu")
        self.assertEqual(Path(show[3]), Path(show[1]).with_name("images"))
        self.assertEqual(self.images(), {})
        self.assertEqual(list((self.runtime / "applesearch").glob("menu.*")), [])
        # The running instance takes the next menu.
        self.assertEqual(self.menu("only\n", pick="0"), ("only\n", 0))

    def test_cliphist_images_are_decoded_for_the_menu(self):
        cliphist = Path(self.env["PATH"].split(os.pathsep)[0], "cliphist")
        cliphist.write_text(f"#!{sys.executable}" + FAKE_CLIPHIST)
        cliphist.chmod(0o755)
        image = "9\t[[ binary data 2 MiB png 1920x1080 ]]\n"
        lines = (image + "8\tplain text\n"
                 # Not cliphist's image lines: a third column, no ID.
                 + "7\t[[ binary data 1 KiB gif 1x1 ]]\textra\n"
                 + "[[ binary data 1 KiB png 1x1 ]]\n"
                 + "404\t[[ binary data 3 KiB jpeg 10x10 ]]\n"
                 + "".join(f"{n}\tfiller\n" for n in range(100, 195))
                 # The 101st line, past those the menu lists.
                 + "5\t[[ binary data 1 KiB png 2x2 ]]\n")
        self.assertEqual(self.menu(lines, pick="0"), (image, 0))
        self.assertEqual(self.images(), {"9": "image 9"})
        # A last line without a line break counts too.
        self.assertEqual(self.menu("3\t[[ binary data 1 KiB bmp 2x2 ]]", pick="0"),
                         ("3\t[[ binary data 1 KiB bmp 2x2 ]]\n", 0))
        self.assertEqual(self.images(), {"3": "image 3"})

    def test_cancelled_and_empty_menus_exit_1(self):
        self.assertEqual(self.menu("a\nb\n", pick="cancel"), ("", 1))
        self.state.unlink()
        self.assertEqual(self.menu(""), ("", 1))
        self.assertFalse(self.state.exists(), "empty input does not start the panel")

    def test_other_launches_run_while_a_menu_waits(self):
        menu = self.launch(lines="a\nb\n", pick="never")
        menu.stdin.write("a\nb\n")
        menu.stdin.close()
        self.wait_for_call("showMenu")
        toggle = self.launch()
        self.assertEqual(toggle.wait(timeout=5), 0)
        self.assertEqual(self.calls()[-1], ["toggle"])
        # A menu whose instance stopped without answering ends instead of waiting forever.
        self.instance.kill()
        self.instance.wait()
        self.assertEqual(menu.wait(timeout=5), 1)
        self.assertEqual(menu.stdout.read(), "")
        menu.stdout.close()
        menu.stderr.close()
        toggle.stdout.close()
        toggle.stderr.close()


class RunTests(unittest.TestCase):
    """--run, which the panel starts apps with."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.bin = self.base / "bin"
        self.records = self.base / "records"
        self.bin.mkdir()
        self.records.mkdir()
        # Nothing else is on PATH, so no real terminal or systemd-run is found.
        for tool in ("dirname", "setsid"):
            (self.bin / tool).symlink_to(shutil.which(tool))
        self.env = dict(PATH=str(self.bin), HOME=str(self.base), RECORDS=str(self.records))

    def tearDown(self):
        self.temp.cleanup()

    def fake(self, name, status=0):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}" + FAKE_COMMAND.replace("STATUS", str(status)))
        path.chmod(0o755)
        return path

    def run_app(self, *args, **env):
        return subprocess.run([shutil.which("bash"), str(ROOT / "launch.sh"), "--run", *args],
                              env=dict(self.env, **env), text=True, capture_output=True, timeout=10)

    def record(self, name):
        """What a fake was run with. Apps started directly run in the background."""
        path = self.records / f"{name}.json"
        deadline = time.monotonic() + 5
        while not path.exists():
            self.assertLess(time.monotonic(), deadline, f"{name} did not run")
            time.sleep(0.02)
        return json.loads(path.read_text())

    def test_apps_start_in_a_systemd_unit_with_the_session_display(self):
        self.fake("systemd-run")
        result = self.run_app("--directory", "/srv", "--", "mpv", "--player-operation-mode=pseudo-gui", "a b",
                              WAYLAND_DISPLAY="wayland-7", XDG_CURRENT_DESKTOP="Hyprland")
        self.assertEqual(result.returncode, 0, result.stderr)
        command = self.record("systemd-run")["argv"]
        for option in ("--user", "--collect", "--property=ExitType=cgroup", "--setenv=WAYLAND_DISPLAY=wayland-7",
                       "--setenv=XDG_CURRENT_DESKTOP=Hyprland", "--working-directory=/srv"):
            self.assertIn(option, command)
        self.assertFalse([option for option in command if option.startswith("--setenv=DISPLAY")],
                         "unset variables are left out")
        self.assertEqual(command[command.index("--"):], ["--", "mpv", "--player-operation-mode=pseudo-gui", "a b"])

    def test_apps_start_directly_without_a_working_systemd_run(self):
        self.fake("mpv")
        directory = self.base / "work"
        directory.mkdir()
        self.assertEqual(self.run_app("--directory", str(directory), "--", "mpv", "a b").returncode, 0)
        self.assertEqual(self.record("mpv"), {"argv": ["a b"], "cwd": str(directory)})
        (self.records / "mpv.json").unlink()
        # For example, without a user bus.
        self.fake("systemd-run", status=1)
        result = self.run_app("--", "mpv")
        self.assertIn("starting directly", result.stderr)
        self.assertEqual(self.record("mpv"), {"argv": [], "cwd": str(self.base)})

    def test_terminal_apps_prefer_terminal_then_known_emulators(self):
        self.fake("systemd-run")
        alacritty, foot = self.fake("alacritty"), self.fake("foot")
        self.run_app("--terminal", "--", "btop", TERMINAL="alacritty")
        self.assertEqual(self.record("systemd-run")["argv"][-4:], ["--", str(alacritty), "-e", "btop"])
        self.run_app("--terminal", "--", "btop")
        self.assertEqual(self.record("systemd-run")["argv"][-3:], ["--", str(foot), "btop"])
        alacritty.unlink()
        foot.unlink()
        (self.records / "systemd-run.json").unlink()
        result = self.run_app("--terminal", "--", "btop")
        self.assertEqual((result.returncode, result.stderr), (1, "No terminal emulator found for this application\n"))
        self.assertFalse((self.records / "systemd-run.json").exists())

    def test_an_entry_without_a_command_starts_nothing(self):
        self.fake("systemd-run")
        result = self.run_app("--")
        self.assertEqual((result.returncode, result.stderr), (1, "This application has no command to run\n"))
        self.assertFalse((self.records / "systemd-run.json").exists())


if __name__ == "__main__":
    unittest.main()
