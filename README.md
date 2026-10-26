# AppleSearch

A small Spotlight-style launcher for Quickshell 0.3+ on Wayland. One search box,
an animated result list, and local **Google EmbeddingGemma 2** semantic search.
No API keys or inference server.

The UI bundles Geist Sans for the search box, result names, and paths; no system
font installation or runtime font download is needed. See [font provenance and license](fonts/README.md).

The panel uses the liquid-glass refraction shader adapted from
[MacShell](https://github.com/0-ss/MacShell/tree/6b4d31b1911f3cb4590658de157d1070f6665b3a),
with a curved rim, blurred backdrop, and subtle chromatic refraction.
The imported rendering code was reviewed as text before compilation or execution;
see [the source review](docs/glass-review.md).

```sh
./launch.sh
```

Requires `quickshell` (`qs`), `uv`, `xdg-open`, `flock`
(util-linux), GNU coreutils, and Qt Shader Tools (`qsb`) for liquid glass. Install
`pdftotext` (Poppler) to search PDF contents. On first launch, Python dependencies
and the pinned model checkpoint (~1.5 GB) are downloaded in the background.
The search box opens immediately. After setup, inference and search work offline.

### Stylix colors

AppleSearch reads `$XDG_CONFIG_HOME/stylix/palette.json` (default
`~/.config/stylix/palette.json`) at runtime for both local and Nix launches.
`base00` supplies the glass tint and fallback background; text uses `base05`,
secondary text uses `base04`, row selection uses `base02`, and accents use `base0D`.
Light and dark palettes are detected from `base00`.

Palette changes update the UI without restarting the model. The palette is also
refreshed when opening the panel and every two seconds while it is visible to
handle Nix-managed symlink replacements. Invalid colors retain their previous
values; a default Base16 palette is used when Stylix is unavailable.
To use a different palette file:

```sh
APPLESEARCH_PALETTE="$HOME/.config/my-colors.json" ./launch.sh
```

### Nix

```sh
nix run .
```

Or enter the development environment and use the local launcher:

```sh
nix-shell
./launch.sh
```

`nix-shell --run './launch.sh'` and `nix develop -c ./launch.sh` work too.
The shell also provides an `applesearch` command for the packaged app.

Nix compiles the reviewed glass shader during the build. Local launches compile
it asynchronously once and cache it under `~/.cache/applesearch/shaders/`, keyed
by its source hash; the search box appears immediately. Without `qsb` or a cached
shader, the panel uses a translucent fallback. No precompiled binaries from
MacShell are used.

The backdrop reads the local wallpaper from hyprpaper, swww, or awww and captures
visible windows on the active workspace, including arriving and departing workspaces. One frame per
window is cached for resize animations; only windows intersecting the panel stream
at a target of 60 fps while it is visible, with window positions refreshed
at about 30 fps. Failed window exports reconnect automatically; captures are released
and geometry polling pauses when the panel hides. An explicit local wallpaper path is also
supported:

```sh
APPLESEARCH_WALLPAPER="$HOME/Pictures/wallpaper.jpg" ./launch.sh
```

Workspace transitions retain both departing and arriving windows. Their motion
mirrors Hyprland's configured slide/fade style, direction, duration, and Bézier
curve, including interrupted switches and special workspaces. Animation settings
come from fixed, read-only `hyprctl` queries. This follows IPC events and configured
timing; it does not receive the compositor's exact per-frame or gesture offsets.

The backdrop follows Hyprland's maximized/fullscreen stacking and visibility:
covered windows are excluded, while floating windows permitted above fullscreen
remain visible. Restoring a window brings the underlying windows back into the capture.
Maximize and restore interpolate the captured window's rectangle using the configured
`windowsMove` duration and Bézier curve, with the fullscreen visibility fade and
interrupted transitions tracked separately. Geometry metadata is retained while
hidden so opening midway through a transition continues its remaining motion.
The last valid window texture survives capture-stream resets during resizing;
these frame caches are released when the panel hides.
As with workspace transitions, timing follows IPC and animation settings rather
than compositor-provided frame positions.

The outer window and backdrop texture keep a fixed size while the card expands
downward. The rounded input region follows the card, letting clicks through the
unused area. Pending queries retain the previous results and result area height
until new matches arrive or the query finishes without matches; clearing the
query collapses it. Refraction stays at the edges without shifting the backdrop
as the card grows.

Searching and indexing run quietly, without progress labels or a temporary empty
results area. A query with no previous results keeps the search box collapsed
until matches arrive or the completed search has no results. Errors remain visible.

Documents use file-type icons from your current system icon theme, just like
applications (PDFs, office documents, images, archives, and source files). Unknown
types fall back to the theme's generic document icon. Existing cached results pick
up their icons without rebuilding the search index.

Nix supplies Quickshell, Python, uv, GLib, Poppler, xdg-utils, and the native
libraries required by the CPU wheels. It pins Nixpkgs in `flake.lock`; both shell
entry points use that pin. The first launch still installs the locked Python
packages and downloads the model. With `nix run`, the Python environment lives
under `$XDG_CACHE_HOME/applesearch/venv-*` (default `~/.cache/applesearch/venv-*`),
so the Nix store stays read-only. Model weights and the search index are shared
with the local launcher. The flake defines x86-64 and ARM64 Linux outputs.

```sh
nix run . -- --hidden
nix run . -- --stop
```

Run `./launch.sh` again to toggle the existing panel. Escape or an outside click
(on Hyprland) hides it while keeping the model warm. Use `./launch.sh --stop` to
quit and release its memory; `./launch.sh --hidden` starts it without opening.
The checkout and Nix launchers share one resident instance per display and namespace, so
switching between them reuses the loaded model. `--stop` from either launcher
stops that instance. Launching changed source restarts it with the updated code.

Set a custom Wayland layer namespace with `-n` or `--namespace`:

```sh
./launch.sh -n 123
nix run . -- -n 123
./launch.sh --namespace 123 --hidden
./launch.sh -n 123 --stop
```

The default is `applesearch`. Each name has an independent panel and loaded model;
toggle, `--hidden`, and `--stop` affect only the selected namespace. Model weights
and the on-disk search cache are shared. Use the namespace in compositor layer
rules to target that panel.

| Key | Action |
| --- | --- |
| ↑ / ↓ | Select a result |
| Enter | Launch application / open file |
| Ctrl+Enter | Open its containing folder |
| Escape | Hide |
| Ctrl+R | Refresh the index |

Applications and files start through `systemd-run --user` when it is available,
with the session's environment rather than AppleSearch's, in their own unit;
their output goes to the user journal. Terminal applications open in `$TERMINAL`,
`xdg-terminal-exec`, or the first installed of kitty, foot, Alacritty, WezTerm,
Ghostty, Konsole, GNOME Terminal, Console, Xfce Terminal, or xterm.

For a Hyprland shortcut, add your absolute project path to your config:

```ini
bind = SUPER, SPACE, exec, /path/to/applesearch/launch.sh
exec-once = /path/to/applesearch/launch.sh --hidden
```

## Search and cache

Applications come from XDG application directories. Files come from your XDG
Documents, Downloads, Desktop, and Pictures folders. Names and paths are indexed
for all ordinary files; text/code and the first four pages of PDFs also contribute
content. Images and other binary formats currently use their names and paths.

The local index and up to 256 query embeddings live in
`~/.cache/applesearch/index.sqlite3` (or `$XDG_CACHE_HOME/applesearch`). Model weights
use the standard Hugging Face cache. Reopening the panel reuses the running
process; restarting reads the existing SQLite index immediately and warms the
model on a separate thread. Keyword matches appear first, then semantic matches.
Exact names retain priority. Files and queries are never sent to a service.
Prepared search metadata and the last 128 ranked queries stay in memory; index
changes invalidate the relevant caches. The input debounce is 25 ms. Background
document embeddings pause while the panel is open so queries get the model to
themselves, then resume when it hides. Background work uses one-document batches
to reduce the wait for an in-flight batch when opening the panel.
Folder names and explicit sequence numbers also take priority: `second asd`,
`2nd asd`, and `2 asd` select the file prefixed `02` inside an `ASD` folder,
even before its embedding is ready. Unrelated semantic matches are omitted
when a folder and file number identify a specific document.

Asking for the newest files lists them by modification time, newest first, with
the time after the folder: `last screenshot`, `latest pdf in downloads`,
`last 3 photos`, or just `recent`. Photo/image, video, song/music, document, and
archive match files of that type anywhere; other words match the start of a word
in a file's name or folders, so `download` covers `~/Downloads` and `screenshot`
covers a Screenshots folder and grim or hyprshot file names. A name containing
the whole query, like The Last of Us, stays on top. When no file fits the
words, the query is searched as usual.

Indexing runs incrementally in the background and checks for changes every two
minutes. Opening the panel also refreshes right away if a file was added,
removed, or renamed in an indexed folder, so a screenshot taken a moment ago
is already there. Unchanged files retain their vectors. The text-only model uses float32
on CPU and normalized 256-dimensional embeddings. Background batches yield to
new queries. Initial indexing can take a while on a large collection.

Optional environment settings, applied when starting a new instance:

```sh
APPLESEARCH_PATHS="$HOME/Notes:$HOME/Documents" ./launch.sh
APPLESEARCH_THREADS=2 ./launch.sh --hidden
APPLESEARCH_EXCLUDE_PATHS="$HOME/Documents/Archive:$HOME/Downloads/installers" ./launch.sh
```

`APPLESEARCH_PATHS` is a colon-separated list of folders (empty means apps only).
`APPLESEARCH_CACHE_DIR` overrides the index location. `APPLESEARCH_MAX_ITEMS`
defaults to 10,000 files, split evenly between the folders so a large one cannot
push out the others; a folder that needs fewer leaves the rest to the others.
Traversal stops after six directory levels and skips
hidden paths, symlinks, dependency folders, and build outputs.
Copied Firefox/Chromium profiles, Python environments, extracted Electron
or `.app` bundles, and Minecraft servers and worlds are also excluded.

To exclude other folders, list them one per line in
`$XDG_CONFIG_HOME/applesearch/exclude` (default `~/.config/applesearch/exclude`).
Lines starting with `#` are comments. The file is re-read on every refresh, so
edits apply within two minutes, or immediately with Ctrl+R:

```sh
# ~/.config/applesearch/exclude
~/Documents/Archive
~/Downloads/installers
```

`APPLESEARCH_EXCLUDE_PATHS` adds more, separated by colons. Both take absolute or
`~`-prefixed directory paths; each excludes its descendants.
Exclusions apply to the whole index, including filename matches. A refresh removes
previously cached entries in excluded folders while preserving other embeddings.

## Development

```sh
./launch.sh --setup
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python tests/integration.py  # real model, offline cache/restart check
qs log -p . --no-color -t 50
qs ipc -p . call spotlight state
qs ipc -p . call spotlight search 'something to read'
```

QML reloads automatically when edited in the default namespace. For custom
namespaces, rerun the launcher to apply edits. Restart the instance after changing
`backend.py` or environment settings. To update dependencies after changing
`pyproject.toml`, run `uv lock` followed by `./launch.sh --setup`.

Model reference: [EmbeddingGemma 2 model card](https://ai.google.dev/gemma/docs/embeddinggemma/model_card_2).
