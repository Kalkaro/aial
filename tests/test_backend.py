from datetime import date, datetime, time, timedelta
import math
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

import numpy as np

from backend import (SearchService, Store, VECTOR_KEY, desktop_entry, exec_arguments, launch, packed,
                     terminal_command)


def document(path, title, body="", fingerprint="one"):
    return dict(id=str(path), title=title, body=body, subtitle="~/Documents", kind="file",
                icon="text-x-generic", fingerprint=fingerprint)


def modified_at(base, relative, moment):
    """A file under ~/ saved at a datetime, fingerprinted like the indexer does."""
    path = base / relative
    return dict(document(path, path.name, fingerprint=f"{int(moment.timestamp() * 1e9)}:10"),
                subtitle="~/" + str(Path(relative).parent))


class SearchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.store = Store(self.directory)
        self.service = SearchService(self.store)
        self.service.np = np

    def tearDown(self):
        self.store.db.close()
        self.temp.cleanup()

    def test_persistent_document_and_query_vectors_survive_restart(self):
        item = document(self.directory / "notes.txt", "notes.txt")
        self.store.upsert(item)
        self.store.save_vectors([item], [[1, 0]])
        self.store.save_query("notes", [1, 0])
        reopened = Store(self.directory)
        try:
            self.assertEqual(reopened.counts(), (1, 1))
            self.assertEqual(reopened.query_vector("notes"), packed([1, 0]))
            self.assertEqual(reopened.rows("SELECT vector_key FROM items")[0][0], VECTOR_KEY)
        finally:
            reopened.db.close()

    def test_only_changed_documents_lose_their_embeddings(self):
        item = document(self.directory / "notes.txt", "notes.txt")
        self.store.upsert(item)
        self.store.save_vectors([item], [[1, 0]])
        self.store.upsert(item)
        self.assertEqual(self.store.counts(), (1, 1))
        changed = dict(item, fingerprint="two", body="updated content")
        self.store.upsert(changed)
        self.assertEqual(self.store.counts(), (1, 0))
        # An in-flight embedding for the old content cannot overwrite the update.
        self.store.save_vectors([item], [[1, 0]])
        self.assertEqual(self.store.counts(), (1, 0))

    def test_semantics_find_a_document_without_shared_query_words(self):
        relevant = document(self.directory / "a.txt", "Weekend plans", "Take the train")
        unrelated = document(self.directory / "b.txt", "Kitchen", "Make some soup")
        for item in (relevant, unrelated):
            self.store.upsert(item)
        self.store.save_vectors([relevant, unrelated], [[1, 0], [0, 1]])
        self.assertEqual(self.service.results("transportation"), [])
        hits = self.service.results("transportation", packed([1, 0]))
        self.assertEqual([hit["title"] for hit in hits], ["Weekend plans"])

    def test_exact_names_outrank_semantic_matches(self):
        exact = document(self.directory / "a.txt", "Terminal")
        similar = document(self.directory / "b.txt", "Console")
        for item in (exact, similar):
            self.store.upsert(item)
        self.store.save_vectors([exact, similar], [[0, 1], [1, 0]])
        hits = self.service.results("terminal", packed([1, 0]))
        self.assertEqual(hits[0]["title"], "Terminal")

    def test_folder_and_ordinal_find_the_numbered_file_before_embedding(self):
        second = dict(document(self.directory / "ASD/02 - complexity2.pdf", "02 - complexity2.pdf"),
                      subtitle="~/Documents/PJATK/ASD")
        third = dict(document(self.directory / "ASD/03 - searching3.pdf", "03 - searching3.pdf"),
                     subtitle="~/Documents/PJATK/ASD")
        unrelated = dict(document(self.directory / "ANG/2", "2"), subtitle="~/Documents/PJATK/ANG")
        for item in (second, third, unrelated):
            self.store.upsert(item)
        # Strong semantic scores for the wrong files must not override an explicit location/number.
        self.store.save_vectors([third, unrelated], [[1, 0], [1, 0]])
        for query in ("second asd", "2nd asd", "2 asd", "second file in asd"):
            with self.subTest(query=query):
                for vector in (None, packed([1, 0])):
                    hits = self.service.results(query, vector)
                    self.assertEqual([hit["id"] for hit in hits], [second["id"]])

    def test_nonexistent_number_in_folder_does_not_return_semantic_filler(self):
        item = dict(document(self.directory / "ASD/01 - notes.pdf", "01 - notes.pdf"),
                    subtitle="~/Documents/PJATK/ASD")
        self.store.upsert(item)
        self.store.save_vectors([item], [[1, 0]])
        self.assertEqual(self.service.results("second asd", packed([1, 0])), [])

    def test_explicit_folder_matches_outrank_unrelated_semantic_matches(self):
        scoped = dict(document(self.directory / "ASD/notes.pdf", "notes.pdf"),
                      subtitle="~/Documents/PJATK/ASD")
        unrelated = document(self.directory / "random-asd-cache.json", "random-asd-cache.json")
        for item in (scoped, unrelated):
            self.store.upsert(item)
        self.store.save_vectors([unrelated], [[1, 0]])
        hits = self.service.results("asd", packed([1, 0]))
        self.assertEqual(hits[0]["id"], scoped["id"])

    def test_ordinal_in_an_ordinary_content_query_does_not_force_a_file_number(self):
        item = document(self.directory / "physics.md", "Physics", "Second law of thermodynamics")
        self.store.upsert(item)
        self.store.upsert(document(self.directory / "law/02 - contract.txt", "02 - contract.txt"))
        hits = self.service.results("second law of thermodynamics")
        self.assertEqual([hit["id"] for hit in hits], [item["id"]])

    def test_removed_files_are_removed_from_semantic_search(self):
        item = document(self.directory / "a.txt", "notes")
        self.store.upsert(item)
        self.store.save_vectors([item], [[1, 0]])
        self.assertEqual(len(self.service.results("journey", packed([1, 0]))), 1)
        self.store.prune(set())
        self.assertEqual(self.service.results("journey", packed([1, 0])), [])

    def test_invalid_vectors_are_rejected(self):
        for vector in ([], [math.nan], [math.inf]):
            with self.assertRaises(ValueError):
                packed(vector)

    def test_query_cache_is_bounded(self):
        for index in range(270):
            self.store.save_query(str(index), [1, 0])
        self.assertEqual(self.store.rows("SELECT count(*) FROM queries")[0][0], 256)
        self.assertIsNone(self.store.query_vector("0"))
        self.assertIsNotNone(self.store.query_vector("269"))

    def test_warm_result_cache_tracks_changed_metadata(self):
        item = document(self.directory / "a.txt", "Old name")
        self.store.upsert(item)
        self.assertEqual(self.service.results("new name"), [])
        self.store.upsert(dict(item, title="New name", fingerprint="updated"))
        self.assertEqual(self.service.results("new name")[0]["title"], "New name")
        self.assertEqual(self.service.results("old name"), [])

    def test_warm_result_cache_tracks_updated_embeddings(self):
        first = document(self.directory / "a.txt", "First")
        second = document(self.directory / "b.txt", "Second")
        for item in (first, second):
            self.store.upsert(item)
        self.store.save_vectors([first, second], [[1, 0], [0, 1]])
        self.assertEqual(self.service.results("journey", packed([1, 0]))[0]["id"], first["id"])
        self.store.save_vectors([first, second], [[0, 1], [1, 0]])
        self.assertEqual(self.service.results("journey", packed([1, 0]))[0]["id"], second["id"])

    def test_warm_catalog_notices_another_connection_updating_the_index(self):
        self.assertEqual(self.service.results("notes"), [])
        other = Store(self.directory)
        try:
            other.upsert(document(self.directory / "notes.txt", "Notes"))
        finally:
            other.db.close()
        self.assertEqual(self.service.results("notes")[0]["title"], "Notes")

    def test_cached_results_cannot_be_modified_by_a_caller(self):
        self.store.upsert(document(self.directory / "notes.txt", "Notes"))
        result = self.service.results("notes")
        result[0]["title"] = "Modified"
        self.assertEqual(self.service.results("notes")[0]["title"], "Notes")

    def recent(self, relative, minutes_ago):
        item = modified_at(self.directory, relative, datetime.now() - timedelta(minutes=minutes_ago))
        self.store.upsert(item)
        return item

    def test_last_screenshot_lists_screenshots_newest_first(self):
        older = self.recent("Pictures/Screenshots/2026-10-01_03-18-09.png", 900)
        newest = self.recent("Pictures/Screenshots/2026-10-21_17-44-17.png", 5)
        grim = self.recent("Pictures/20260808_13h37m49s_grim.png", 60)
        self.recent("Pictures/wallpaper.jpg", 1)
        unrelated = self.recent("Documents/screen notes.txt", 2)
        # A semantic match for another file does not reorder or join the list.
        self.store.save_vectors([unrelated], [[1, 0]])
        expected = [newest["id"], grim["id"], older["id"]]
        for query in ("last screenshot", "latest screenshots", "the most recent screenshot i took"):
            with self.subTest(query=query):
                for vector in (None, packed([1, 0])):
                    self.assertEqual([hit["id"] for hit in self.service.results(query, vector)], expected)
        self.assertEqual([hit["id"] for hit in self.service.results("last 2 screenshots")], expected[:2])

    def test_recent_files_are_labeled_with_their_time(self):
        for name, moment in (("today.pdf", datetime.combine(date.today(), time(9, 5))),
                             ("yesterday.pdf", datetime.combine(date.today() - timedelta(days=1), time(21, 30))),
                             ("old.pdf", datetime(date.today().year - 1, 8, 7, 12))):
            self.store.upsert(modified_at(self.directory, f"Downloads/{name}", moment))
        self.assertEqual([hit["subtitle"] for hit in self.service.results("recent")],
                         ["~/Downloads · Today, 09:05", "~/Downloads · Yesterday, 21:30",
                          f"~/Downloads · Aug 7, {date.today().year - 1}"])

    def test_kind_words_find_the_newest_file_of_that_type_anywhere(self):
        photo = self.recent("Downloads/IMG_0042.jpg", 30)
        screenshot = self.recent("Pictures/Screenshots/shot.png", 10)
        clip = self.recent("Downloads/clip.mp4", 20)
        code = self.recent("Documents/site.ts", 1)
        report = self.recent("Downloads/report.pdf", 40)
        self.recent("Documents/report.pdf", 50)
        self.assertEqual([hit["id"] for hit in self.service.results("last 2 photos")], [screenshot["id"], photo["id"]])
        # .ts names TypeScript as well as MPEG video; the indexer reads it as text.
        self.assertEqual([hit["id"] for hit in self.service.results("latest video")], [clip["id"]])
        self.assertEqual([hit["id"] for hit in self.service.results("last downloaded pdf")], [report["id"]])
        self.assertEqual(self.service.results("newest file")[0]["id"], code["id"])

    def test_names_containing_the_query_stay_on_top_and_other_words_fall_back(self):
        game = dict(id=str(self.directory / "game.desktop"), title="The Last of Us Part I", subtitle="Application",
                    kind="app", icon="", body="", fingerprint="sha")
        self.store.upsert(game)
        self.recent("Documents/us-of-a.txt", 1)
        self.assertEqual(self.service.results("last of us")[0]["id"], game["id"])
        notes = self.recent("Documents/notes.txt", 5)
        self.store.save_vectors([notes], [[1, 0]])
        # No file is named after invoices, so semantic search answers as usual, without times.
        self.assertEqual(self.service.results("last invoice", packed([1, 0])),
                         [{field: notes[field] for field in ("id", "title", "subtitle", "kind")} | {"icon": "text-plain"}])


class DirectoryExclusionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.docs = self.base / "Documents"
        self.store = Store(self.base / "cache")

    def tearDown(self):
        self.store.db.close()
        self.temp.cleanup()

    def write(self, name, body="example"):
        path = self.docs / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        return path

    def scan(self, excluded="", paths=None):
        self.service = service = SearchService(self.store)
        environment = dict(APPLESEARCH_PATHS=paths or str(self.docs), APPLESEARCH_EXCLUDE_PATHS=excluded,
                           XDG_CONFIG_HOME=str(self.base / "config"),
                           XDG_DATA_HOME=str(self.base / "data"), XDG_DATA_DIRS=str(self.base / "data"))
        with patch.dict(os.environ, environment):
            thread = threading.Thread(target=service.scan)
            thread.start()
            try:
                self.assertTrue(service.scan_done.wait(5), "Index scan did not finish")
            finally:
                service.closed.set()
                service.scan_requested.set()
                thread.join(5)
            self.assertFalse(thread.is_alive())
        return {row["id"] for row in self.store.rows("SELECT id FROM items")}

    def test_dependency_build_and_custom_directories_never_enter_the_index(self):
        keep = self.write("Project/src/main.py")
        for folder in ("node_modules", "vendor", "build", "out", "coverage", "site-packages"):
            self.write(f"Project/{folder}/generated.txt")
        ignored = self.write("Archive/private.txt")
        indexed = self.scan(str(ignored.parent))
        self.assertEqual(indexed, {str(keep)})

    def test_profiles_environments_and_app_bundles_are_detected_by_markers(self):
        keep = self.write("Browsers/notes.md")
        for name in ("prefs.js", "places.sqlite", "session-state.json"):
            self.write(f"firefox backup/abc.default/{name}")
        for name in ("Preferences", "History", "session.json"):
            self.write(f"chromium backup/Default/{name}")
        self.write("Editor/resources/app.asar")
        self.write("Editor/README.md")
        self.write("Environment/pyvenv.cfg")
        self.write("Environment/lib/pkg.py")
        self.write("Application.app/Contents/data.txt")
        self.assertEqual(self.scan(), {str(keep)})

    def test_refresh_removes_excluded_cached_rows_and_preserves_good_vectors(self):
        keep = self.write("Notes.txt")
        ignored = self.write("Project/node_modules/cache.json")
        for path in (keep, ignored):
            stat = path.stat()
            item = document(path, path.name, fingerprint=f"{stat.st_mtime_ns}:{stat.st_size}")
            self.store.upsert(item)
            self.store.save_vectors([item], [[1, 0]])
        self.assertEqual(self.scan(), {str(keep)})
        self.assertEqual(self.store.counts(), (1, 1))

    def test_exclusions_match_whole_directories_and_may_exclude_a_search_root(self):
        self.write("Archive/ignored.txt")
        keep = self.write("Archive-copy/keep.txt")
        self.assertEqual(self.scan(str(self.docs / "Archive")), {str(keep)})
        self.assertEqual(self.scan(str(self.docs)), set())

    def test_exclude_file_lists_folders_one_per_line(self):
        keep = self.write("Notes/keep.txt")
        self.write("Archive/old.txt")
        self.write("Games/save.txt")
        config = self.base / "config/applesearch"
        config.mkdir(parents=True)
        (config / "exclude").write_text(f"# Not worth searching\n\n{self.docs / 'Archive'}\n  ~/Documents/Games  \n")
        with patch.dict(os.environ, HOME=str(self.base)):
            self.assertEqual(self.scan(), {str(keep)})

    def test_minecraft_servers_and_worlds_are_detected_by_markers(self):
        keep = self.write("Games/notes.md")
        # Without a Minecraft eula.txt, server.properties is ordinary configuration.
        config = self.write("Broker/server.properties")
        for name in ("server.properties", "eula.txt", "config/quests.json"):
            self.write(f"Games/server/{name}")
        for name in ("level.dat", "region/r.0.0.mca"):
            self.write(f"Games/saves/World/{name}")
        self.assertEqual(self.scan(), {str(keep), str(config)})

    def test_the_file_limit_is_shared_between_folders(self):
        big = [self.write(f"Big/{index:02}.txt") for index in range(10)]
        small = [self.write(f"Small/{index}.txt") for index in range(2)]
        roots = os.pathsep.join((str(self.docs / "Big"), str(self.docs / "Small")))
        with patch("backend.MAX_ITEMS", 6), patch("backend.emit") as emitted:
            indexed = self.scan(paths=roots)
        # The small folder fits entirely; the big one gets the rest of the limit.
        self.assertEqual(indexed, {str(path) for path in big[:4] + small})
        self.assertTrue(emitted.call_args.kwargs["limited"])

    def test_opening_the_panel_refreshes_only_after_a_watched_folder_changed(self):
        self.write("Screenshots/old.png")
        self.write("PJATK/ASD/01.pdf")
        self.write("Archive/old.txt")
        for folder in (self.docs, *self.docs.rglob("*")):
            if folder.is_dir():
                os.utime(folder, ns=(0, 0))
        self.scan(str(self.docs / "Archive"))
        service = self.service
        service.scan_requested.clear()
        service.set_active(True)
        self.assertFalse(service.scan_requested.is_set())
        self.write("Archive/new.txt")
        service.set_active(True)
        self.assertFalse(service.scan_requested.is_set(), "Excluded folders are not watched")
        self.write("Screenshots/new.png")
        service.set_active(False)
        self.assertFalse(service.scan_requested.is_set())
        service.set_active(True)
        self.assertTrue(service.scan_requested.is_set())
        service.scan_requested.clear()
        os.utime(self.docs / "Screenshots", ns=(0, 0))
        # A folder that only holds folders is watched too.
        (self.docs / "PJATK/GUI").mkdir()
        service.set_active(True)
        self.assertTrue(service.scan_requested.is_set())


class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.store = Store(self.base / "cache")
        self.service = SearchService(self.store)

    def tearDown(self):
        self.store.db.close()
        self.temp.cleanup()

    def app(self, name, lines):
        path = self.base / f"{name}.desktop"
        path.write_text("[Desktop Entry]\nType=Application\n" + lines)
        self.store.upsert(dict(id=str(path), title=name, subtitle="Application", kind="app",
                               icon="", body="", fingerprint="one"))
        return path

    def test_exec_lines_drop_file_codes_and_expand_the_rest(self):
        path = self.app("notes", 'Name=Notes\nIcon=notes\nExec=notes --title=%c %i --file=%f "a b" 100%% %U\n')
        self.assertEqual(exec_arguments(desktop_entry(path), path),
                         ["notes", "--title=Notes", "--icon", "notes", "--file=", "a b", "100%"])

    def test_desktop_string_escapes_apply_before_quoting(self):
        path = self.app("say", r'Exec=say one\stwo "back\\\\slash"' + "\n")
        self.assertEqual(exec_arguments(desktop_entry(path), path), ["say", "one", "two", "back\\slash"])

    def test_terminal_apps_prefer_terminal_then_known_emulators(self):
        installed = {"alacritty", "foot"}
        with patch.dict(os.environ), patch("backend.shutil.which",
                                           lambda name: f"/bin/{name}" if name in installed else None):
            os.environ["TERMINAL"] = "alacritty"
            self.assertEqual(terminal_command(["btop"]), ["/bin/alacritty", "-e", "btop"])
            del os.environ["TERMINAL"]
            self.assertEqual(terminal_command(["btop"]), ["/bin/foot", "btop"])
            installed.clear()
            self.assertRaises(ValueError, terminal_command, ["btop"])

    def test_launch_starts_a_systemd_unit_with_the_session_display(self):
        with patch.dict(os.environ, {"WAYLAND_DISPLAY": "wayland-7"}), \
                patch("backend.shutil.which", return_value="/bin/systemd-run"), \
                patch("backend.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run, \
                patch("backend.subprocess.Popen") as popen:
            launch(["mpv"], "/srv")
        command = run.call_args.args[0]
        for option in ("--user", "--collect", "--property=ExitType=cgroup",
                       "--setenv=WAYLAND_DISPLAY=wayland-7", "--working-directory=/srv"):
            self.assertIn(option, command)
        self.assertEqual(command[-2:], ["--", "mpv"])
        popen.assert_not_called()

    def test_launch_falls_back_to_a_detached_process(self):
        failed = subprocess.CompletedProcess([], 1, "", "Failed to connect to bus")
        with patch("backend.shutil.which", return_value="/bin/systemd-run"), \
                patch("backend.subprocess.run", return_value=failed), \
                patch("backend.subprocess.Popen") as popen, self.assertLogs(level="WARNING"):
            launch(["mpv"])
        self.assertEqual(popen.call_args.args[0], ["mpv"])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_opening_an_app_runs_its_exec_line_without_gio(self):
        gui = self.app("player", "Exec=mpv --player-operation-mode=pseudo-gui -- %U\n")
        tui = self.app("monitor", "Terminal=true\nPath=/srv\nExec=btop\n")
        with patch.dict(os.environ), patch("backend.launch") as started, patch("backend.emit"), \
                patch("backend.shutil.which", lambda name: "/bin/kitty" if name == "kitty" else None):
            os.environ.pop("TERMINAL", None)
            self.service.open(str(gui))
            started.assert_called_with(["mpv", "--player-operation-mode=pseudo-gui", "--"], None)
            self.service.open(str(tui))
            started.assert_called_with(["/bin/kitty", "btop"], "/srv")


if __name__ == "__main__":
    unittest.main()
