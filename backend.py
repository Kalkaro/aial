#!/usr/bin/env python3
"""JSON-lines bridge for shell.qml. Inference and indexing never block input."""
from __future__ import annotations

import array
import configparser
from collections import OrderedDict
from datetime import date, datetime
from functools import lru_cache
import hashlib
import heapq
from itertools import islice
import json
import logging
import math
import mimetypes
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import threading
import time

MODEL = "google/embeddinggemma-2"
REVISION = "914f7f89142e33e77833254d9c9b90c3cef7303b"
VECTOR_KEY = f"{MODEL}:{REVISION}:text:256:v1"
LIMIT = 7
MAX_ITEMS = int(os.environ.get("APPLESEARCH_MAX_ITEMS", "10000"))
# Tie launched apps to this session's display even if the compositor never
# exported these to the systemd user manager.
SESSION_VARIABLES = ("WAYLAND_DISPLAY", "DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE",
                     "XDG_SESSION_DESKTOP", "HYPRLAND_INSTANCE_SIGNATURE", "SWAYSOCK")
# Terminal=true apps use $TERMINAL or the first of these found, with the
# arguments that precede the command. GLib only knows a few of them.
TERMINALS = {
    "xdg-terminal-exec": [], "kitty": [], "foot": [], "alacritty": ["-e"],
    "wezterm": ["start", "--"], "ghostty": ["-e"], "konsole": ["-e"], "gnome-terminal": ["--"],
    "kgx": ["-e"], "xfce4-terminal": ["-x"], "xterm": ["-e"],
}
TEXT_SUFFIXES = {
    ".txt", ".md", ".markdown", ".rst", ".org", ".csv", ".tsv", ".json",
    ".yaml", ".yml", ".toml", ".ini", ".qml", ".py", ".js", ".jsx",
    ".ts", ".tsx", ".rs", ".go", ".c", ".h", ".cpp", ".css", ".html",
    ".sh", ".nix", ".tex", ".log",
}
SKIP_DIRS = {
    "node_modules", "bower_components", "vendor", "target", "build", "dist", "out",
    "venv", "__pycache__", "__pypackages__", "site-packages", "cmakefiles",
    "coverage", "htmlcov", "obj", "zig-cache", "zig-out", "__macosx",
}
SKIP_FILES = {"thumbs.db", "desktop.ini"}
ORDINALS = {word: number for number, word in enumerate((
    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
    "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth",
    "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth",
), start=1)}
NUMBER_QUERY_WORDS = {"the", "in", "from", "file", "files", "document", "documents",
                      "pdf", "lecture", "lesson", "chapter", "slides"}
RECENT_WORDS = {"last", "latest", "newest", "recent", "recently"}
# Words in "the most recent file I saved" that don't narrow down which files.
RECENT_FILLER = {"the", "a", "an", "my", "most", "in", "from", "i", "file", "thing", "anything", "item",
                 "took", "taken", "made", "saved", "added", "created", "edited", "modified", "changed", "updated"}
# Query words for a kind of file: MIME type prefixes, and other words that may
# start a word in its name or folders. Every query word also matches the start of
# those words itself, so "download" finds ~/Downloads and "pdf" finds report.pdf.
FILE_KINDS = {
    **dict.fromkeys(("image", "photo", "picture", "pic"), (("image/",), ())),
    **dict.fromkeys(("video", "movie", "clip"), (("video/",), ())),
    **dict.fromkeys(("song", "music", "audio"), (("audio/",), ())),
    "recording": (("video/", "audio/"), ()),
    "document": (("application/pdf", "text/plain", "text/markdown", "application/rtf", "application/msword",
                  "application/vnd.oasis.opendocument.", "application/vnd.openxmlformats-officedocument."), ()),
    "archive": (("application/zip", "application/x-7z", "application/x-tar", "application/x-compressed-tar",
                 "application/vnd.rar", "application/x-rar"), ()),
    "screenshot": ((), ("grim", "hyprshot", "flameshot")),
    "downloaded": ((), ("download",)),
}
OUTPUT_LOCK = threading.Lock()


def emit(**message):
    with OUTPUT_LOCK:
        print(json.dumps(message, ensure_ascii=False, allow_nan=False), flush=True)


def packed(vector):
    values = [float(value) for value in vector]
    if not values or not all(math.isfinite(value) for value in values):
        raise ValueError("The local model returned an invalid embedding")
    return array.array("f", values).tobytes()


def abbreviated(path):
    value = str(path)
    home = str(Path.home())
    return "~" + value[len(home):] if value.startswith(home + "/") else value


@lru_cache(maxsize=1)
def document_types():
    """Read installed MIME suffixes once; no subprocess or document I/O on search."""
    home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
    directories = [home, *(Path(p) for p in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(os.pathsep) if p)]
    types = {}
    seen = set()
    for priority, directory in enumerate(directories):
        path = (directory / "mime/globs2").resolve()
        if path in seen:
            continue
        seen.add(path)
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            continue
        for line in lines:
            fields = line.split(":", 3)
            if len(fields) < 3 or not fields[0].isdigit():
                continue
            weight, mime, pattern = int(fields[0]), fields[1], fields[2]
            if not pattern.startswith("*.") or any(c in pattern[1:] for c in "*?[]"):
                continue
            sensitive = len(fields) > 3 and "cs" in fields[3].split(",")
            suffix = pattern[1:] if sensitive else pattern[1:].casefold()
            key = (suffix, sensitive)
            entry = (weight, len(suffix), -priority, mime)
            if key not in types or entry[:3] > types[key][:3]:
                types[key] = entry
    return types


def document_type(path):
    """The MIME type of a file name, or "" if it is unknown."""
    name = Path(path).name
    types = document_types()
    matches = []
    for offset, char in enumerate(name):
        if char == ".":
            suffix = name[offset:]
            for key in ((suffix, True), (suffix.casefold(), False)):
                if key in types:
                    matches.append(types[key])
    return max(matches)[3] if matches else mimetypes.guess_type(name, strict=False)[0] or ""


def document_icon(path):
    mime = document_type(path)
    return mime.replace("/", "-") if mime else "text-x-generic"


def file_text(path):
    """Bounded text extraction. Binary files are searchable by name and path."""
    try:
        if path.suffix.lower() == ".pdf" and shutil.which("pdftotext"):
            result = subprocess.run(
                ["pdftotext", "-f", "1", "-l", "4", str(path), "-"],
                capture_output=True, timeout=4, check=False,
            )
            return result.stdout[:10000].decode("utf-8", errors="replace")
        if path.suffix.lower() in TEXT_SUFFIXES or path.name.lower() in {"readme", "makefile"}:
            with path.open("rb") as stream:
                data = stream.read(10000)
            if b"\0" not in data:
                return data.decode("utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        pass
    return ""


def search_roots():
    custom = os.environ.get("APPLESEARCH_PATHS")
    if custom is not None:
        return [Path(p).expanduser().resolve() for p in custom.split(os.pathsep) if p]
    # Respect translated/moved XDG user directories without evaluating shell code.
    directories = {name: Path.home() / name.title() for name in ("DOCUMENTS", "DOWNLOAD", "DESKTOP", "PICTURES")}
    directories["DOWNLOAD"] = Path.home() / "Downloads"
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "user-dirs.dirs"
    if config.exists():
        for key, value in re.findall(r'^XDG_(\w+)_DIR="([^"\n]+)"', config.read_text(), re.M):
            if key in directories:
                directories[key] = Path(value.replace("$HOME", str(Path.home()))).expanduser()
    # An XDG directory set to $HOME means disabled, not permission to scan all home.
    return list(dict.fromkeys(p.resolve() for p in directories.values() if p != Path.home()))


def exclusion_paths():
    """APPLESEARCH_EXCLUDE_PATHS plus the exclude file, which is re-read on every refresh."""
    paths = os.environ.get("APPLESEARCH_EXCLUDE_PATHS", "").split(os.pathsep)
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "applesearch/exclude"
    try:
        # One folder per line; blank lines and # comments are ignored.
        paths += config.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        pass
    return [Path(p).expanduser().resolve() for p in map(str.strip, paths) if p and not p.startswith("#")]


def excluded_path(path, exclusions):
    return any(path == excluded or path.is_relative_to(excluded) for excluded in exclusions)


def excluded_directory(path, entries, exclusions):
    if path.name.startswith(".") or path.name.casefold() in SKIP_DIRS or path.suffix.casefold() == ".app":
        return True
    if excluded_path(path, exclusions) or "pyvenv.cfg" in entries:
        return True
    # Recognize copied browser profiles and Electron distributions by their files,
    # rather than excluding a user's ordinary notes just because of a folder name.
    firefox_profile = "prefs.js" in entries and bool({"places.sqlite", "compatibility.ini"} & entries)
    chromium_profile = "Preferences" in entries and bool({"History", "Web Data"} & entries)
    electron_bundle = "resources" in entries and (
        "chrome-sandbox" in entries or (path / "resources/app.asar").is_file()
    )
    # Minecraft servers and world saves hold thousands of generated data files.
    # Other software uses server.properties too, so a server also needs its eula.txt.
    minecraft = {"server.properties", "eula.txt"} <= entries or "level.dat" in entries
    return firefox_profile or chromium_profile or electron_bundle or minecraft


def indexable_files(root, exclusions):
    """Ordinary files under root in a stable order, skipping excluded folders."""
    for parent, dirs, files in os.walk(root, followlinks=False):
        if excluded_directory(Path(parent), set(dirs) | set(files), exclusions):
            dirs[:] = []
            continue
        depth = len(Path(parent).relative_to(root).parts)
        dirs[:] = sorted(d for d in dirs if not excluded_directory(Path(parent) / d, set(), exclusions)) if depth < 6 else []
        for filename in sorted(files):
            path = Path(parent) / filename
            if not (filename.startswith(".") or filename.casefold() in SKIP_FILES or path.is_symlink() or not path.is_file()):
                yield path


def fair_share(groups, limit):
    """Split limit evenly between groups, so one huge folder cannot push out the
    others. Whatever a smaller group leaves unused goes to the rest."""
    chosen = []
    for index, group in enumerate(sorted(groups, key=len)):
        chosen += group[:(limit - len(chosen)) // (len(groups) - index)]
    return chosen


def watched_folders(roots, files):
    """The roots and every folder between them and an indexed file."""
    folders = set(roots)
    for path in files:
        for parent in path.parents:
            if parent in folders:
                break
            folders.add(parent)
    return folders


def folders_changed(folders, since_ns):
    """Adding, removing or renaming a file updates its folder's mtime."""
    for folder in folders:
        try:
            if os.stat(folder).st_mtime_ns > since_ns:
                return True
        except OSError:
            continue
    return False


def numbered_title(title):
    match = re.match(r"^0*(\d+)(?=$|[\W_])", title)
    return int(match[1]) if match else None


def folder_words(item):
    if isinstance(item, dict) and "_folders" in item:
        return item["_folders"]
    return set(re.findall(r"\w+", str(Path(item["id"]).parent).casefold())) if item["kind"] == "file" else set()


def prepare_item(row):
    item = dict(row)
    item["_title"] = item["title"].casefold()
    item["_metadata"] = (item["title"] + " " + item["subtitle"]).casefold()
    item["_text"] = (item["title"] + " " + item["subtitle"] + " " + item["body"]).casefold()
    item["_folders"] = frozenset(folder_words(item))
    item["_initials"] = "".join(word[0] for word in re.findall(r"\w+", item["_title"])) if item["kind"] == "app" else ""
    return item


def numbered_candidates(items, query, folder_index=None):
    """Honor a location + sequence number, without interpreting ordinary prose."""
    tokens = re.findall(r"\w+", query)
    numbers = set()
    number_tokens = set()
    for token in tokens:
        if token in ORDINALS:
            numbers.add(ORDINALS[token])
            number_tokens.add(token)
        elif match := re.fullmatch(r"(\d+)(?:st|nd|rd|th)?", token):
            numbers.add(int(match[1]))
            number_tokens.add(token)
    if len(numbers) != 1:
        return items, False
    location = set(tokens) - number_tokens - NUMBER_QUERY_WORDS
    if not location:
        return items, False
    if folder_index is not None:
        if not location <= folder_index.keys():
            return items, False
        ids = set.intersection(*(folder_index[word] for word in location))
        scoped = [item for item in items if item["id"] in ids]
    else:
        paths = [(item, folder_words(item)) for item in items if item["kind"] == "file"]
        if not location <= set().union(*(words for _, words in paths)):
            return items, False
        scoped = [item for item, words in paths if location <= words]
    if not any(numbered_title(item["title"]) is not None for item in scoped):
        return items, False
    number = next(iter(numbers))
    return [item for item in scoped if numbered_title(item["title"]) == number], True


def recency_terms(query):
    """For "last 3 screenshots", the words that describe the files and how many
    to show. None unless the query asks for the newest files."""
    tokens = re.findall(r"[^\W_]+", query)
    if not RECENT_WORDS.intersection(tokens):
        return None
    terms, count = [], LIMIT
    for previous, token in zip([None, *tokens], tokens):
        if previous in RECENT_WORDS and re.fullmatch(r"\d\d?", token) and int(token):
            count = min(int(token), LIMIT)
        elif token not in RECENT_WORDS and token not in RECENT_FILLER:
            # A word matches the start of a file's words, so "screenshots" needs to lose its "s".
            plural = len(token) > 3 and token.endswith("s") and not token.endswith("ss")
            terms.append(token[:-1] if plural else token)
    return terms, count


def describes(item, term):
    """Whether a query word names the file's kind or starts a word in its name or folders."""
    types, aliases = FILE_KINDS.get(term, ((), ()))
    if types:
        if "_type" not in item:
            item["_type"] = document_type(item["id"])
            # Text the indexer reads, like site.ts, is not the video its extension can also mean.
            if item["_type"].startswith(("video/", "audio/", "image/")) and Path(item["id"]).suffix.casefold() in TEXT_SUFFIXES:
                item["_type"] = "text/plain"
        if item["_type"].startswith(types):
            return True
    if "_words" not in item:
        item["_words"] = frozenset(re.findall(r"[^\W_]+", item["_metadata"]))
    return any(word.startswith((term, *aliases)) for word in item["_words"])


def modified_ns(item):
    """Files are fingerprinted as "mtime_ns:size"."""
    stamp = item.get("fingerprint", "").partition(":")[0] if item["kind"] == "file" else ""
    return int(stamp) if stamp.isdigit() else 0


def modified_label(ns):
    moment = datetime.fromtimestamp(ns / 1e9)
    days = (date.today() - moment.date()).days
    if days in (0, 1):
        return ("Today" if days == 0 else "Yesterday") + moment.strftime(", %H:%M")
    return moment.strftime("%b %-d, %H:%M" if moment.year == date.today().year else "%b %-d, %Y")


def newest_files(items, query):
    """Answer "last screenshot", "latest pdf in downloads" or just "recent" with
    the newest matching files, labeled with their time. None for other queries,
    or when no file fits, so the query is searched as usual."""
    parsed = recency_terms(query)
    if parsed is None:
        return None
    terms, count = parsed
    named = []
    if terms:
        # A name containing the whole query, like The Last of Us, stays on top.
        phrase = re.compile(r"(?<![^\W_])" + re.escape(query))
        named = sorted((item for item in items if phrase.search(item["_title"])),
                       key=lambda item: (not item["_title"].startswith(query), item["kind"] != "app", item["_title"]))
    ids = {item["id"] for item in named}
    newest = heapq.nsmallest(count, (item for item in items if item["kind"] == "file" and item["id"] not in ids
                                     and all(describes(item, term) for term in terms)),
                             key=lambda item: (-modified_ns(item), item["_title"]))
    if not newest:
        return None
    newest = [dict(item, subtitle=f'{item["subtitle"]} · {modified_label(modified_ns(item))}') for item in newest]
    return (named + newest)[:LIMIT]


def application_items():
    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
    data_dirs = os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(os.pathsep)
    seen = set()
    desktops = set(os.environ.get("XDG_CURRENT_DESKTOP", "").split(":"))
    for directory in [data_home, *(Path(p) for p in data_dirs if p)]:
        base = directory / "applications"
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.desktop")):
            desktop_id = str(path.relative_to(base)).replace("/", "-")
            if desktop_id in seen:
                continue
            seen.add(desktop_id)
            try:
                app = desktop_entry(path)
                if app.get("Type") != "Application" or app.get("Hidden") == "true" or app.get("NoDisplay") == "true":
                    continue
                if app.get("OnlyShowIn") and not desktops.intersection(app["OnlyShowIn"].split(";")):
                    continue
                if desktops.intersection(app.get("NotShowIn", "").split(";")):
                    continue
                if app.get("TryExec") and not shutil.which(app["TryExec"]):
                    continue
                title = app.get("Name", path.stem)
                body = " ".join(app.get(k, "") for k in ("GenericName", "Comment", "Keywords", "Categories"))
                yield dict(id=str(path), title=title, subtitle="Application", kind="app",
                           icon=app.get("Icon", "application-x-executable"), body=body,
                           fingerprint=hashlib.sha256(path.read_bytes()).hexdigest())
            except (OSError, configparser.Error, KeyError, UnicodeError):
                continue


def desktop_entry(path):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.read(path, encoding="utf-8")
    return parser["Desktop Entry"]


def exec_arguments(entry, path):
    """Expand a desktop entry's Exec line for launching without files or URLs.

    gio is often missing from the session PATH, so apps are launched directly.
    """
    # String escapes apply before the Exec quoting rules.
    escapes = {"s": " ", "n": "\n", "t": "\t", "r": "\r", "\\": "\\"}
    command = re.sub(r"\\([sntr\\])", lambda match: escapes[match[1]], entry.get("Exec", ""))
    codes = {"%": "%", "c": entry.get("Name", ""), "k": str(path)}
    arguments = []
    for argument in shlex.split(command):
        if argument == "%i":
            arguments += ["--icon", entry["Icon"]] if entry.get("Icon") else []
        elif not re.fullmatch(r"%[fFuUdDnNvm]", argument):
            arguments.append(re.sub(r"%(.)", lambda match: codes.get(match[1], ""), argument))
    if not arguments:
        raise ValueError("This application has no command to run")
    return arguments


def terminal_command(arguments):
    names = list(TERMINALS)
    if os.environ.get("TERMINAL"):
        names.insert(0, os.environ["TERMINAL"])
    for name in names:
        executable = shutil.which(name)
        if executable:
            return [executable, *TERMINALS.get(Path(name).name, ["-e"]), *arguments]
    raise ValueError("No terminal emulator found for this application")


def launch(command, directory=None):
    """Start a command detached, with the session's environment rather than ours.

    AppleSearch's environment carries Quickshell's Qt plugin paths, the
    LD_LIBRARY_PATH its Python wheels need, and whatever the shell that started
    it had, which can crash apps on start. A transient systemd user service
    starts from the session environment and keeps the app in its own cgroup.
    """
    if shutil.which("systemd-run"):
        # ExitType=cgroup keeps the unit, and the app, alive after a launcher script exits.
        options = ["--user", "--quiet", "--collect", "--property=ExitType=cgroup"]
        options += [f"--setenv={name}={os.environ[name]}" for name in SESSION_VARIABLES if name in os.environ]
        if directory:
            options.append(f"--working-directory={directory}")
        result = subprocess.run(["systemd-run", *options, "--", *command], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return
        logging.warning("systemd-run failed, starting directly: %s", result.stderr.strip())
    subprocess.Popen(command, cwd=directory, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


class Store:
    def __init__(self, directory):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(directory / "index.sqlite3", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            PRAGMA busy_timeout=5000;
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, kind TEXT, icon TEXT,
                body TEXT, fingerprint TEXT, vector BLOB, vector_key TEXT
            );
            CREATE TABLE IF NOT EXISTS queries (
                query TEXT PRIMARY KEY, vector BLOB, vector_key TEXT, used REAL
            );
        """)
        self.generation = 0
        self.metadata_generation = 0

    def rows(self, sql, parameters=()):
        with self.lock:
            return self.db.execute(sql, parameters).fetchall()

    def upsert(self, item):
        with self.lock:
            old = self.db.execute("SELECT fingerprint FROM items WHERE id=?", (item["id"],)).fetchone()
            if old and old[0] == item["fingerprint"]:
                return
            self.db.execute("""
                INSERT INTO items(id,title,subtitle,kind,icon,body,fingerprint)
                VALUES(:id,:title,:subtitle,:kind,:icon,:body,:fingerprint)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, subtitle=excluded.subtitle,
                    kind=excluded.kind, icon=excluded.icon, body=excluded.body,
                    fingerprint=excluded.fingerprint, vector=NULL, vector_key=NULL
            """, item)
            self.db.commit()
            self.generation += 1
            self.metadata_generation += 1

    def prune(self, seen):
        with self.lock:
            stale = [(r[0],) for r in self.db.execute("SELECT id FROM items") if r[0] not in seen]
            self.db.executemany("DELETE FROM items WHERE id=?", stale)
            self.db.commit()
            if stale:
                self.generation += 1
                self.metadata_generation += 1

    def save_vectors(self, items, vectors):
        with self.lock:
            self.db.executemany(
                "UPDATE items SET vector=?, vector_key=? WHERE id=? AND fingerprint=?",
                [(packed(v), VECTOR_KEY, item["id"], item["fingerprint"]) for item, v in zip(items, vectors)],
            )
            self.db.commit()
            self.generation += 1

    def query_vector(self, query):
        rows = self.rows("SELECT vector FROM queries WHERE query=? AND vector_key=?", (query, VECTOR_KEY))
        return rows[0][0] if rows else None

    def save_query(self, query, vector):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO queries VALUES(?,?,?,?)", (query, packed(vector), VECTOR_KEY, time.time()))
            self.db.execute("DELETE FROM queries WHERE query NOT IN (SELECT query FROM queries ORDER BY used DESC LIMIT 256)")
            self.db.commit()

    def counts(self):
        row = self.rows("SELECT count(*), count(CASE WHEN vector_key=? THEN 1 END) FROM items", (VECTOR_KEY,))[0]
        return row[0], row[1]


class SearchService:
    def __init__(self, store):
        self.store = store
        self.condition = threading.Condition()
        self.current = (0, "")
        self.pending = None
        self.closed = threading.Event()
        self.scan_done = threading.Event()
        self.scan_requested = threading.Event()
        self.phase = "loading"
        self.model = None
        self.np = None
        self.matrix_generation = -1
        self.matrix = None
        self.vector_items = []
        self.search_lock = threading.RLock()
        self.catalog_stamp = None
        self.catalog_items = []
        self.folder_index = {}
        self.result_cache = OrderedDict()
        self.panel_active = False
        self.watched = None

    def set_active(self, active):
        with self.condition:
            self.panel_active = active
            self.condition.notify_all()
        # Refresh now if a file appeared since the last scan, like a screenshot
        # taken a moment ago, rather than within the next two minutes.
        if active and self.watched and folders_changed(*self.watched):
            self.scan_requested.set()

    def catalog(self):
        with self.store.lock:
            external = self.store.db.execute("PRAGMA data_version").fetchone()[0]
            stamp = (self.store.metadata_generation, external)
            vector_stamp = (self.store.generation, external)
            rows = self.store.rows("SELECT id,title,subtitle,kind,icon,body,fingerprint FROM items") if stamp != self.catalog_stamp else None
        if rows is not None:
            self.catalog_items = [prepare_item(row) for row in rows]
            self.folder_index = {}
            for item in self.catalog_items:
                for word in item["_folders"]:
                    self.folder_index.setdefault(word, set()).add(item["id"])
            self.catalog_stamp = stamp
            self.result_cache.clear()
        return vector_stamp

    def status(self, phase, message):
        self.phase = phase
        count, embedded = self.store.counts()
        emit(type="status", phase=phase, message=message, items=count, embedded=embedded)

    def scan(self):
        while not self.closed.is_set():
            seen = set()
            limited = False
            started = time.time_ns()
            try:
                exclusions = exclusion_paths()
                for item in application_items():
                    if excluded_path(Path(item["id"]), exclusions):
                        continue
                    seen.add(item["id"])
                    self.store.upsert(item)
                # One extra file per folder shows whether the limit cut it short.
                roots = search_roots()
                groups = [list(islice(indexable_files(root, exclusions), MAX_ITEMS + 1)) for root in roots]
                files = fair_share(groups, MAX_ITEMS)
                limited = len(files) < sum(map(len, groups))
                for path in files:
                    if self.closed.is_set():
                        return
                    try:
                        stat = path.stat()
                        fingerprint = f"{stat.st_mtime_ns}:{stat.st_size}"
                        seen.add(str(path))
                        old = self.store.rows("SELECT fingerprint FROM items WHERE id=?", (str(path),))
                        if not old or old[0][0] != fingerprint:
                            self.store.upsert(dict(
                                id=str(path), title=path.name, subtitle=abbreviated(path.parent),
                                kind="file", icon="text-x-generic", body=file_text(path), fingerprint=fingerprint,
                            ))
                    except OSError:
                        continue
                self.store.prune(seen)
                # File times come from a coarser clock than time_ns(), so allow a second.
                self.watched = (watched_folders(roots, files), started - 1_000_000_000)
            except Exception:
                logging.exception("Index refresh failed")
            finally:
                self.scan_done.set()
                with self.condition:
                    self.condition.notify_all()
                emit(type="index", items=self.store.counts()[0], limited=limited)
            # Periodic incremental refresh, also triggered by Ctrl+R.
            self.scan_requested.wait(120)
            self.scan_requested.clear()

    @staticmethod
    def lexical_score(item, query, tokens=None, token_set=None):
        if not isinstance(item, dict) or "_title" not in item:
            item = prepare_item(item)
        title = item["_title"]
        tokens = tokens if tokens is not None else query.split()
        token_set = token_set if token_set is not None else set(tokens)
        if title == query:
            return 1.6
        if title.startswith(query):
            return 1.3
        if query in title:
            return 1.1
        if all(token in title for token in tokens):
            return 0.95
        if token_set <= item["_folders"]:
            return 1.2
        if all(token in item["_metadata"] for token in tokens):
            return 0.9
        if item["kind"] == "app":
            if item["_initials"].startswith(query):
                return 0.85
        return 0.35 if all(token in item["_text"] for token in tokens) else 0.0

    def results(self, query, vector_blob=None):
        with self.search_lock:
            return self.ranked_results(query, vector_blob)

    def ranked_results(self, query, vector_blob):
        vector_stamp = self.catalog()
        semantic = vector_blob is not None and self.np is not None
        # The date is part of the key because recent files are labeled Today or Yesterday.
        cache_key = (query, self.catalog_stamp, vector_stamp if semantic else None, vector_blob if semantic else None,
                     date.today())
        if cache_key in self.result_cache:
            self.result_cache.move_to_end(cache_key)
            return [dict(item) for item in self.result_cache[cache_key]]
        ranked = newest_files(self.catalog_items, query)
        if ranked is None:
            ranked = self.relevant_items(query, vector_blob if semantic else None, vector_stamp)
        result =[{field: item[field] for field in ("id", "title", "subtitle", "kind", "icon")} for item in ranked]
        # Derive icons for old cached documents too, without reindexing their content.
        for item in result:
            if item["kind"] == "file":
                item["icon"] = document_icon(item["id"])
        self.result_cache[cache_key] = tuple(dict(item) for item in result)
        if len(self.result_cache) > 128:
            self.result_cache.popitem(last=False)
        return result

    def relevant_items(self, query, vector_blob, vector_stamp):
        items, numbered = numbered_candidates(self.catalog_items, query, self.folder_index)
        tokens = query.split()
        token_set = set(tokens)
        scores = {item["id"]: max(1.25 if numbered else 0, self.lexical_score(item, query, tokens, token_set)) for item in items}
        if vector_blob is not None:
            with self.store.lock:
                if self.matrix_generation != vector_stamp:
                    self.vector_items = self.store.rows("SELECT id,vector FROM items WHERE vector_key=?", (VECTOR_KEY,))
                    self.matrix = self.np.stack([self.np.frombuffer(r["vector"], dtype="float32") for r in self.vector_items]) if self.vector_items else None
                    self.matrix_generation = vector_stamp
                matrix, vector_items = self.matrix, self.vector_items
            if matrix is not None:
                similarities = matrix @ self.np.frombuffer(vector_blob, dtype="float32")
                for item, similarity in zip(vector_items, similarities):
                    similarity = float(similarity)
                    if item["id"] in scores and math.isfinite(similarity) and similarity >= 0.60:
                        key = item["id"]
                        scores[key] = max(scores.get(key, 0), similarity * 0.9) + min(scores.get(key, 0), 0.35) * 0.15
        return heapq.nsmallest(LIMIT, (item for item in items if scores[item["id"]] > 0),
                               key=lambda item: (-scores[item["id"]], item["kind"] != "app", item["_title"]))

    def send_results(self, request_id, query, results, semantic=False, searching=False):
        with self.condition:
            if self.current == (request_id, query):
                emit(type="results", id=request_id, query=query, results=results,
                     semantic=semantic, searching=searching)

    def search(self, request_id, text):
        query = " ".join(text.casefold().split())[:512]
        with self.condition:
            self.current = (request_id, query)
            self.pending = None
        if not query:
            self.send_results(request_id, query, [])
            return
        cached = self.store.query_vector(query)
        results = self.results(query, cached)
        self.send_results(request_id, query, results, semantic=cached is not None and self.np is not None,
                          searching=self.phase != "error" and cached is None)
        with self.condition:
            if self.current == (request_id, query) and self.phase != "error":
                self.pending = (request_id, query)
                self.condition.notify_all()

    def run_model(self):
        try:
            self.status("loading", "Warming up local search…")
            import numpy as np
            self.np = np
            import torch
            from sentence_transformers import SentenceTransformer
            from huggingface_hub import hf_hub_download, snapshot_download
            from huggingface_hub.errors import LocalEntryNotFoundError

            torch.set_num_threads(int(os.environ.get("APPLESEARCH_THREADS", "4")))
            options = dict(device="cpu", config_kwargs={"vision_config": None, "audio_config": None},
                           model_kwargs={"dtype": torch.float32}, trust_remote_code=False)
            required = ["config.json", "config_sentence_transformers.json", "modules.json", "sentence_bert_config.json",
                        "tokenizer.json", "tokenizer_config.json", "processor_config.json", "preprocessor_config.json",
                        "model.safetensors", "1_Pooling/config.json"]
            try:
                snapshot = Path(hf_hub_download(MODEL, "config.json", revision=REVISION, local_files_only=True)).parent
                if not all((snapshot / name).is_file() for name in required):
                    raise FileNotFoundError("Incomplete model cache")
            except (LocalEntryNotFoundError, FileNotFoundError):
                self.status("loading", "Downloading EmbeddingGemma 2 for the first time…")
                snapshot = snapshot_download(MODEL, revision=REVISION,
                                             allow_patterns=required + ["tokenizer.model", "chat_template.jinja"])
            model = SentenceTransformer(str(snapshot), local_files_only=True, **options)
            model.max_seq_length = 384
            self.model = model
            self.status("indexing", "Preparing semantic search…")
            while not self.closed.is_set():
                with self.condition:
                    if self.panel_active and self.pending is None:
                        self.condition.wait(timeout=1)
                        continue
                    pending = self.pending
                    self.pending = None
                if pending:
                    request_id, query = pending
                    blob = self.store.query_vector(query)
                    if blob is None:
                        vector = model.encode(query, prompt_name="SearchQuery", truncate_dim=256,
                                              normalize_embeddings=True, show_progress_bar=False)
                        self.store.save_query(query, vector)
                        blob = packed(vector)
                    self.send_results(request_id, query, self.results(query, blob), semantic=True)
                    continue
                batch = self.store.rows("""
                    SELECT * FROM items WHERE vector_key IS NULL OR vector_key != ?
                    ORDER BY CASE WHEN kind='app' THEN 0 WHEN body != '' THEN 1 ELSE 2 END, id LIMIT 1
                """, (VECTOR_KEY,))
                if batch:
                    if self.phase != "indexing":
                        self.status("indexing", "Updating semantic search…")
                    documents = [f'title: {r["title"]} | text: {r["subtitle"]}\n{r["body"]}' for r in batch]
                    vectors = model.encode(documents, batch_size=1, truncate_dim=256,
                                           normalize_embeddings=True, show_progress_bar=False)
                    self.store.save_vectors(batch, vectors)
                    # Re-rank an active query as its corpus grows, without re-encoding.
                    with self.condition:
                        request_id, query = self.current
                    if query:
                        blob = self.store.query_vector(query)
                        if blob is not None:
                            self.send_results(request_id, query, self.results(query, blob), semantic=True)
                    if self.store.counts()[1] % 40 == 0:
                        self.status("indexing", "Updating semantic search…")
                else:
                    if self.scan_done.is_set() and self.phase != "ready":
                        self.status("ready", "Local search ready")
                    with self.condition:
                        if self.pending is None:
                            self.condition.wait(timeout=1)
        except Exception as error:
            logging.exception("EmbeddingGemma 2 failed")
            self.status("error", "Semantic search unavailable · " + str(error).split("\n")[0][:180])
            with self.condition:
                request_id, query = self.current
            if query:
                self.send_results(request_id, query, self.results(query), searching=False)

    def open(self, item_id, reveal=False):
        item = self.store.rows("SELECT kind FROM items WHERE id=?", (item_id,))
        if not item:
            raise ValueError("This result is no longer indexed")
        path = Path(item_id)
        if not path.exists():
            self.scan_requested.set()
            raise ValueError("This file was moved or deleted")
        if item[0]["kind"] == "app" and not reveal:
            entry = desktop_entry(path)
            command = exec_arguments(entry, path)
            if entry.get("Terminal", "").lower() == "true":
                command = terminal_command(command)
            launch(command, entry.get("Path"))
        else:
            launch(["xdg-open", str(path.parent if reveal else path)])
        emit(type="opened")

    def run(self):
        self.catalog()
        emit(type="ready", items=self.store.counts()[0])
        scanner = threading.Thread(target=self.scan, daemon=True, name="indexer")
        inference = threading.Thread(target=self.run_model, daemon=True, name="embeddings")
        scanner.start()
        inference.start()
        try:
            for line in sys.stdin:
                try:
                    message = json.loads(line)
                    action = message.get("action")
                    if action == "search":
                        self.search(int(message["id"]), str(message.get("query", "")))
                    elif action == "open":
                        self.open(str(message["id"]), bool(message.get("reveal")))
                    elif action == "refresh":
                        self.scan_requested.set()
                    elif action == "active":
                        self.set_active(bool(message.get("value")))
                except Exception as error:
                    logging.exception("Request failed")
                    emit(type="error", message=str(error))
        finally:
            self.closed.set()
            self.scan_requested.set()
            with self.condition:
                self.condition.notify_all()
            # Let an active PyTorch call finish before interpreter teardown.
            inference.join(timeout=10)
            scanner.join(timeout=5)


def main():
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING, format="%(levelname)s: %(message)s")
    cache = Path(os.environ.get("APPLESEARCH_CACHE_DIR", Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "applesearch"))
    SearchService(Store(cache)).run()


if __name__ == "__main__":
    main()
