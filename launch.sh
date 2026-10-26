#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$project_dir"
venv_dir="${UV_PROJECT_ENVIRONMENT:-$project_dir/.venv}"

setup() {
    if ! command -v uv >/dev/null 2>&1; then
        printf 'AppleSearch needs uv: https://docs.astral.sh/uv/getting-started/installation/\n' >&2
        exit 1
    fi
    uv sync --frozen >&2
}

# QML starts this asynchronously: even first-time dependency setup never blocks
# the window from appearing. Subsequent starts go straight to the cached venv.
case "${1:-}" in
    --shader)
        if [[ -n "${APPLESEARCH_GLASS_SHADER:-}" && -f "$APPLESEARCH_GLASS_SHADER" ]]; then
            printf '%s\n' "$APPLESEARCH_GLASS_SHADER"
            exit 0
        fi
        shader_hash="$(sha256sum "$project_dir/liquidglass.frag")"
        shader_cache="${XDG_CACHE_HOME:-$HOME/.cache}/applesearch/shaders/${shader_hash%% *}"
        shader_output="$shader_cache/liquidglass.frag.qsb"
        if [[ -s "$shader_output" ]]; then
            printf '%s\n' "$shader_output"
            exit 0
        fi
        qsb_bin=""
        for candidate in qsb qsb6 qsb-qt6 /usr/lib/qt6/bin/qsb /usr/lib64/qt6/bin/qsb /usr/lib/qt/bin/qsb; do
            if command -v "$candidate" >/dev/null 2>&1; then
                qsb_bin="$(command -v "$candidate")"
                break
            fi
        done
        if [[ -z "$qsb_bin" ]]; then
            printf 'Liquid glass needs Qt Shader Tools (qsb); nix run . supplies it. Using the translucent fallback.\n' >&2
            exit 1
        fi
        mkdir -p -m 700 "$shader_cache"
        exec 9>"$shader_cache/compile.lock"
        flock -x 9
        if [[ ! -s "$shader_output" ]]; then
            shader_temp="$(mktemp "$shader_cache/liquidglass.XXXXXX.qsb")"
            trap 'rm -f -- "$shader_temp"' EXIT
            "$qsb_bin" --qt6 -o "$shader_temp" "$project_dir/liquidglass.frag" >&2
            mv -f "$shader_temp" "$shader_output"
        fi
        printf '%s\n' "$shader_output"
        exit 0
        ;;
    --backend)
        if [[ ! -x "$venv_dir/bin/python" || ! -f "$venv_dir/.applesearch-ready" ]]; then
            setup
            touch "$venv_dir/.applesearch-ready"
        fi
        export HF_HUB_DISABLE_TELEMETRY=1 TOKENIZERS_PARALLELISM=false
        export OMP_NUM_THREADS="${APPLESEARCH_THREADS:-4}"
        export OPENBLAS_NUM_THREADS="${APPLESEARCH_THREADS:-4}"
        # NixOS's nix-ld libraries are also needed by dlopen() in Python wheels.
        if [[ -d /run/current-system/sw/share/nix-ld/lib ]]; then
            export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/run/current-system/sw/share/nix-ld/lib"
        fi
        exec "$venv_dir/bin/python" -u "$project_dir/backend.py"
        ;;
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
        --setup) action=setup ;;
        --help|-h)
            printf '%s\n' 'Usage: ./launch.sh [-n NAMESPACE] [--hidden | --stop | --setup]' \
                '  default          Show Spotlight; toggle it if already running.' \
                '  -n, --namespace  Wayland namespace and instance name (default: applesearch).' \
                '  --hidden         Start in the background without showing the panel.' \
                '  --stop           Stop the selected namespace and its local model.' \
                '  --setup          Install the locked Python dependencies.'
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
if [[ "$action" == setup ]]; then
    setup
    touch "$venv_dir/.applesearch-ready"
    exit 0
fi
export APPLESEARCH_NAMESPACE="$namespace"
export APPLESEARCH_SOURCE_DIR="$project_dir"

qs_bin="$(command -v qs || command -v quickshell || true)"
if [[ -z "$qs_bin" ]]; then
    printf 'Install Quickshell 0.3+ first: https://quickshell.org\n' >&2
    exit 1
fi

# One resident model per display and namespace, shared by both launchers.
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
exec 9>"$instance_dir/launch-$instance_tag.lock"
flock -x 9
source_hash="$(sha256sum backend.py shell.qml LiquidGlass.qml WorkspaceMotion.qml WindowMotion.qml Spring.qml Theme.qml liquidglass.frag launch.sh pyproject.toml uv.lock fonts/Geist.ttf fonts/OFL.txt | sha256sum)"
source_hash="${source_hash%% *}"

if [[ -f "$instance_file" ]]; then
    mapfile -t instance < "$instance_file"
    if [[ "${instance[0]:-}" =~ ^[0-9]+$ && -x "${instance[1]:-}" ]]; then
        if [[ "${instance[2]:-}" == "$source_hash" || "$action" == quit ]]; then
            if "${instance[1]}" ipc --pid "${instance[0]}" call spotlight "$action" >/dev/null 2>&1; then
                [[ "$action" != quit ]] || rm -f "$instance_file"
                exit 0
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

if "$qs_bin" ipc -p "$config_dir" call spotlight "$action" >/dev/null 2>&1; then
    [[ "$action" == quit ]] || record_instance
    exit 0
fi
[[ "$action" != quit ]] || exit 0
if [[ "$action" == hide ]]; then
    export APPLESEARCH_HIDDEN=1
fi
if [[ "$config_dir" != "$project_dir" ]]; then
    # Quickshell deduplicates by config path; each namespace needs its own QML.
    # Backend code and dependencies still come from the original project.
    mkdir -p -m 700 "$config_dir"
    mkdir -p "$config_dir/fonts"
    for font_file in Geist.ttf OFL.txt; do
        cp "$project_dir/fonts/$font_file" "$config_dir/fonts/$font_file.tmp"
        mv -f "$config_dir/fonts/$font_file.tmp" "$config_dir/fonts/$font_file"
    done
    for qml_file in Theme.qml WorkspaceMotion.qml WindowMotion.qml Spring.qml LiquidGlass.qml shell.qml; do
        cp "$project_dir/$qml_file" "$config_dir/$qml_file.tmp"
        mv -f "$config_dir/$qml_file.tmp" "$config_dir/$qml_file"
    done
fi
# Do not pass the launch lock to the resident daemon.
"$qs_bin" -n -p "$config_dir" -d 9>&-
record_instance
