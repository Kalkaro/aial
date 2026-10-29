#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$project_dir"

# Sets terminal to $TERMINAL or the first of these installed, with the
# arguments that go before the command it runs.
find_terminal() {
    local name executable
    for name in ${TERMINAL:+"$TERMINAL"} xdg-terminal-exec kitty foot alacritty wezterm ghostty \
            konsole gnome-terminal kgx xfce4-terminal xterm; do
        executable="$(command -v -- "$name")" || continue
        case "${name##*/}" in
            xdg-terminal-exec|kitty|foot) terminal=("$executable") ;;
            wezterm) terminal=("$executable" start --) ;;
            gnome-terminal) terminal=("$executable" --) ;;
            xfce4-terminal) terminal=("$executable" -x) ;;
            *) terminal=("$executable" -e) ;;
        esac
        return
    done
    printf 'No terminal emulator found for this application\n' >&2
    exit 1
}

# The panel starts apps with --run [--terminal] [--directory DIR] -- COMMAND...
# A transient systemd user service starts each from the session's environment
# rather than Quickshell's, whose Qt plugin paths, and whatever the shell that
# started it had, can crash apps on start. It also keeps the app in its own cgroup.
start_app() {
    local directory="" name terminal=() options=()
    while (( $# )) && [[ "$1" != -- ]]; do
        case "$1" in
            --terminal) find_terminal ;;
            --directory) directory="$2"; shift ;;
        esac
        shift
    done
    if (( $# < 2 )); then
        printf 'This application has no command to run\n' >&2
        exit 1
    fi
    shift
    set -- "${terminal[@]}" "$@"
    if command -v systemd-run >/dev/null; then
        # ExitType=cgroup keeps the unit, and the app, alive after a launcher script exits.
        options=(--user --quiet --collect --property=ExitType=cgroup)
        # Tie the app to this session's display even if the compositor never
        # exported these to the systemd user manager.
        for name in WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP \
                HYPRLAND_INSTANCE_SIGNATURE SWAYSOCK; do
            [[ -z "${!name+set}" ]] || options+=("--setenv=$name=${!name}")
        done
        [[ -z "$directory" ]] || options+=("--working-directory=$directory")
        systemd-run "${options[@]}" -- "$@" </dev/null && exit 0
        printf 'systemd-run failed, starting directly\n' >&2
    fi
    cd -- "${directory:-$HOME}"
    exec setsid -f "$@" </dev/null >/dev/null 2>&1
}

case "${1:-}" in
    --run) shift; start_app "$@" ;;
esac

namespace=applesearch
action=toggle
while (( $# )); do
    case "$1" in
        -n|--namespace)
            if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
                printf '%s requires a namespace, e.g. -n 123\n' "$1" >&2
                exit 2
            fi
            namespace="$2"
            shift
            ;;
        --namespace=*) namespace="${1#*=}" ;;
        --hidden) action=hide ;;
        --stop) action=quit ;;
        --help|-h)
            printf '%s\n' 'Usage: ./launch.sh [-n NAMESPACE] [--hidden | --stop]' \
                '       COMMAND | ./launch.sh [-n NAMESPACE]' \
                '  default          Show Spotlight; toggle it if already running.' \
                '  piped lines      Pick one, dmenu style; print it, or exit 1 if cancelled.' \
                '  -n, --namespace  Wayland namespace and instance name (default: applesearch).' \
                '  --hidden         Start in the background without showing the panel.' \
                '  --stop           Stop the selected namespace.'
            exit 0
            ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
if [[ -z "$namespace" ]]; then
    printf 'Namespace must not be empty.\n' >&2
    exit 2
fi
# Piped lines turn the panel into a picker that prints the chosen one, e.g.
#   cliphist list | ./launch.sh | cliphist decode | wl-copy
if [[ "$action" == toggle && ( -p /dev/stdin || -f /dev/stdin ) ]]; then
    action=menu
fi
export APPLESEARCH_NAMESPACE="$namespace"
export APPLESEARCH_SOURCE_DIR="$project_dir"

qs_bin="$(command -v qs || command -v quickshell || true)"
if [[ -z "$qs_bin" ]]; then
    printf 'Install Quickshell 0.3+ first: https://quickshell.org\n' >&2
    exit 1
fi

# One resident instance per display and namespace, shared by both launchers.
instance_dir="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/applesearch"
display_tag="${WAYLAND_DISPLAY:-${DISPLAY:-default}}"
display_tag="${display_tag//[^a-zA-Z0-9_.-]/_}"
mkdir -p -m 700 "$instance_dir"
instance_tag="$display_tag"
config_dir="$project_dir"
if [[ "$namespace" != applesearch ]]; then
    # Hash the name so arbitrary namespace strings cannot collide or form paths.
    namespace_hash="$(printf '%s' "$namespace" | sha256sum)"
    instance_tag+="-${namespace_hash%% *}"
    config_dir="$instance_dir/config-$instance_tag"
fi
instance_file="$instance_dir/instance-$instance_tag"

# cliphist lists a copied image as "ID<TAB>[[ binary data 2 MiB png 1920x1080 ]]".
# The menu shows those in its first 100 lines, all it lists, as thumbnails,
# decoded here into its images folder, each in a file named by its ID.
decode_images() {
    local line pattern=$'^([0-9]+)\t\\[\\[ binary data [^\t]* [0-9]+x[0-9]+ \\]\\]$'
    mkdir "$menu_dir/images"
    command -v cliphist >/dev/null || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ $pattern ]] || continue
        # An entry deleted since it was listed keeps the image icon.
        cliphist decode "${BASH_REMATCH[1]}" > "$menu_dir/images/${BASH_REMATCH[1]}" 2>/dev/null ||
            rm -f -- "$menu_dir/images/${BASH_REMATCH[1]}"
    done < <(head -n 100 -- "$menu_dir/lines")
}

if [[ "$action" == menu ]]; then
    # The lines wait here, readable only by this user, until the menu answers.
    menu_dir="$(mktemp -d "$instance_dir/menu.XXXXXX")"
    trap 'rm -rf -- "$menu_dir"' EXIT
    # Bash skips the EXIT trap when a signal ends it.
    trap 'exit 1' HUP INT TERM
    cat > "$menu_dir/lines"
    # As with dmenu, no lines means nothing was picked.
    [[ -s "$menu_dir/lines" ]] || exit 1
    decode_images
fi
exec 9>"$instance_dir/launch-$instance_tag.lock"
flock -x 9
source_hash="$(sha256sum shell.qml Config.qml Spring.qml Theme.qml rofi-search.js launch.sh fonts/Geist.ttf fonts/OFL.txt | sha256sum)"
source_hash="${source_hash%% *}"

# Runs the action in an instance, through the qs ipc command given.
request() {
    if [[ "$action" == menu ]]; then
        # The menu replies with its process ID, watched while it is open.
        menu_pid="$("$@" call spotlight showMenu "$menu_dir/lines" "$menu_dir/result" "$menu_dir/images" 2>/dev/null)" &&
            [[ "$menu_pid" =~ ^[0-9]+$ ]]
    else
        "$@" call spotlight "$action" >/dev/null 2>&1
    fi
}

# Exits once the action is done; a menu first waits for its line and prints it.
finish() {
    [[ "$action" == menu ]] || exit 0
    # Let other launches through while the menu is open.
    exec 9>&-
    while [[ ! -s "$menu_dir/result" ]]; do
        # An instance that stopped can no longer answer.
        kill -0 "$menu_pid" 2>/dev/null || exit 1
        sleep 0.02
    done
    mapfile -t result < "$menu_dir/result"
    [[ "${result[0]:-}" == selected ]] || exit 1
    printf '%s\n' "${result[1]:-}"
    exit 0
}

if [[ -f "$instance_file" ]]; then
    mapfile -t instance < "$instance_file"
    if [[ "${instance[0]:-}" =~ ^[0-9]+$ && -x "${instance[1]:-}" ]]; then
        if [[ "${instance[2]:-}" == "$source_hash" || "$action" == quit ]]; then
            if request "${instance[1]}" ipc --pid "${instance[0]}"; then
                [[ "$action" != quit ]] || rm -f "$instance_file"
                finish
            fi
        elif "${instance[1]}" ipc --pid "${instance[0]}" call spotlight quit >/dev/null 2>&1; then
            for _ in {1..10}; do
                kill -0 "${instance[0]}" 2>/dev/null || break
                sleep 0.03
            done
        fi
    fi
    rm -f "$instance_file"
fi

record_instance() {
    local instance_pid
    instance_pid="$("$qs_bin" ipc -p "$config_dir" call spotlight processId)"
    if [[ "$instance_pid" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$instance_pid" "$qs_bin" "$source_hash" > "$instance_file.tmp"
        mv -f "$instance_file.tmp" "$instance_file"
    fi
}

if request "$qs_bin" ipc -p "$config_dir"; then
    [[ "$action" == quit ]] || record_instance
    finish
fi
[[ "$action" != quit ]] || exit 0
if [[ "$action" == hide || "$action" == menu ]]; then
    export APPLESEARCH_HIDDEN=1
fi
if [[ "$config_dir" != "$project_dir" ]]; then
    # Quickshell deduplicates by config path; each namespace needs its own QML.
    # Apps still start through the original project's launch.sh.
    mkdir -p -m 700 "$config_dir"
    mkdir -p "$config_dir/fonts"
    for font_file in Geist.ttf OFL.txt; do
        cp "$project_dir/fonts/$font_file" "$config_dir/fonts/$font_file.tmp"
        mv -f "$config_dir/fonts/$font_file.tmp" "$config_dir/fonts/$font_file"
    done
    for qml_file in Config.qml Theme.qml Spring.qml rofi-search.js shell.qml; do
        cp "$project_dir/$qml_file" "$config_dir/$qml_file.tmp"
        mv -f "$config_dir/$qml_file.tmp" "$config_dir/$qml_file"
    done
fi
# Do not pass the launch lock to the resident daemon. Its startup log goes to
# stderr, as stdout carries a menu's chosen line.
"$qs_bin" -n -p "$config_dir" -d 9>&- >&2
record_instance
if [[ "$action" == menu ]] && ! request "$qs_bin" ipc -p "$config_dir"; then
    printf 'aial started, but its menu did not open\n' >&2
    exit 1
fi
finish
