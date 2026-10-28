<p align="center">
  <img src="screenshot.png" alt="The launcher with the query “fi” and four results" width="720">
</p>

# aial

A small Spotlight-style app launcher for [Quickshell](https://quickshell.org) 0.3+
on Wayland: one search box and an animated result list. Apps are matched and
ordered exactly like in [wave-launcher](https://github.com/Kalkaro/wave-launcher),
whose port of rofi's drun search it uses unchanged.

## Run

```sh
nix run github:Kalkaro/aial
```

Without Nix, clone the repository and run `./launch.sh`. It needs `quickshell`
(`qs`), `flock` and `setsid` (util-linux), and GNU coreutils. Nix supplies all of
them and pins Nixpkgs in `flake.lock`, for x86-64 and ARM64 Linux.

`nix-shell` or `nix develop` enter a shell with the same tools and an
`aial` command for the packaged app.

## Use

Run the launcher again to toggle the panel. Escape or an outside click (on
Hyprland) hides it. Results update as you type; clearing the query collapses the
card. Icons come from your current icon theme.

| Key | Action |
| --- | --- |
| ↑ / ↓ | Select a result |
| Enter | Launch the application |
| Escape | Hide |

```sh
./launch.sh --hidden   # start without opening
./launch.sh --stop     # quit
```

Both work the same through `nix run . --`. The checkout and Nix launchers share
one resident instance per display and namespace, and launching changed source
restarts it with the updated code.

For a Hyprland shortcut, use your absolute project path:

```ini
bind = SUPER, SPACE, exec, /path/to/aial/launch.sh
exec-once = /path/to/aial/launch.sh --hidden
```

Applications start through `systemd-run --user` when it is available, with the
session's environment rather than the launcher's, in their own unit; their
output goes to the user journal. Terminal applications open in `$TERMINAL`,
`xdg-terminal-exec`, or the first installed of kitty, foot, Alacritty, WezTerm,
Ghostty, Konsole, GNOME Terminal, Console, Xfce Terminal, or xterm.

### Namespaces

`-n` or `--namespace` sets the Wayland layer namespace, default `applesearch`:

```sh
./launch.sh -n 123
./launch.sh --namespace 123 --hidden
./launch.sh -n 123 --stop
```

Each name has an independent panel; toggle, `--hidden`, and `--stop` affect only
the selected namespace. The launch history is shared. Use the namespace in
compositor layer rules to target that panel.

## Search

Apps come from the desktop entries Quickshell finds in your XDG data
directories, except hidden and `NoDisplay` ones. They are searched by
wave-launcher's `rofi-search.js`, copied byte for byte, with wave-launcher's
default settings: rofi's drun defaults, plus its name-first order and
keyboard-layout matching.

- Every word typed must appear, ignoring case, in an app's name, generic name,
  Exec line, categories, or keywords. A word starting with `-` excludes the
  apps it matches. Words typed in the Russian keyboard layout also match the
  English letters on the same keys, so `ашкуащч` finds Firefox.
- Apps matching every word by name come first, then those that need the
  generic name, keywords, categories, and lastly the Exec line. Within each
  group, recently launched apps come first, most recent first, then the rest
  alphabetically.

Each launch is recorded in rofi's drun history format in
`$XDG_CACHE_HOME/applesearch.druncache` (default `~/.cache/applesearch.druncache`),
which keeps the last 25 apps. Seven results fit at a time; the arrow keys and
the mouse wheel scroll through the rest.

## Clipboard history

Lines piped into the launcher turn the panel into a dmenu-style picker, like
`rofi -dmenu -display-columns 2`. With [cliphist](https://github.com/sentriz/cliphist),
that makes a clipboard history:

```ini
bind = SUPER, V, exec, cliphist list | /path/to/aial/launch.sh | cliphist decode | wl-copy
```

The picker has no search field. It lists the lines in their order, so
cliphist's stay newest first, with the first one selected. The arrow keys and
the mouse wheel move through them. Enter or a click prints the chosen line;
Escape, or hiding the panel any other way, prints nothing and exits with
status 1. A line shows the text after its first tab, so cliphist's
`id<TAB>preview` lines show just the preview. Seven rows fit at a time, and the
first 100 lines are listed.

Copied images show as thumbnails: before the menu opens, `launch.sh` runs
`cliphist decode` on each image among those lines. An image in a format Qt
can't read, such as TIFF, keeps a plain image icon.

`launch.sh` hands the lines and images to the panel in a folder only you can
read, under `$XDG_RUNTIME_DIR/applesearch`, and deletes it when the menu closes.

## Colors

The launcher reads `$XDG_CONFIG_HOME/stylix/palette.json` (default
`~/.config/stylix/palette.json`) at runtime. `base00` is the panel background, at
80% opacity; text uses `base05`, secondary text uses `base04`, row selection
uses `base02`, and accents use `base0D`. Light and dark palettes are detected
from `base00`.

Palette changes update the UI without a restart. The palette is also refreshed
when opening the panel and every two seconds while it is visible, to handle
Nix-managed symlink replacements. Invalid colors keep their previous values; a
default Base16 palette is used when Stylix is unavailable. To use a different
palette file:

```sh
APPLESEARCH_PALETTE="$HOME/.config/my-colors.json" ./launch.sh
```

## Development

```sh
node --test tests/test_rofi_search.js
python3 -m unittest discover -s tests -v
qs log -p . --no-color -t 50
qs ipc -p . call spotlight state
qs ipc -p . call spotlight search firefox
```

QML reloads automatically when edited in the default namespace. For custom
namespaces, rerun the launcher to apply edits.

`rofi-search.js` and `tests/test_rofi_search.js` are copies of wave-launcher's;
update them there and copy them over rather than editing them here.

## License

[MIT](LICENSE). The search logic is ported from
[Rofi](https://github.com/davatorium/rofi) (MIT, see
[licenses/rofi-MIT.txt](licenses/rofi-MIT.txt)). The bundled Geist Sans is under
the SIL Open Font License; see [fonts/README.md](fonts/README.md).
