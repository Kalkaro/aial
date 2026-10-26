# Liquid glass source review

Source: [0-ss/MacShell](https://github.com/0-ss/MacShell/tree/6b4d31b1911f3cb4590658de157d1070f6665b3a),
commit `6b4d31b1911f3cb4590658de157d1070f6665b3a`, inspected on 2026-10-15.
The upstream shader's SHA-256 is
`565180ab97c7df5fc04c388ab5735a07b6852a8adc64b0f22457c9750d27bc12`.

The repository tree and UTF-8 source files were fetched into a temporary review
directory as data. No MacShell QML, scripts, installers, or build commands were
executed. The tree contained QML, JavaScript emoji data, GLSL, SVG, and a README;
no executable binaries, submodules, or symlinks were present.

The complete `liquidglass.frag` shader and the `LGlass` rendering component in
`MacBar.qml` were inspected before use. The shader samples an input texture and
performs bounded blur, refraction, color grading, and edge/shadow calculations.
Its only sampling loop is bounded to 24 iterations. It has no host command,
filesystem, networking, or dynamic code-loading interface. No suspicious behavior
was found in this imported rendering surface. This is a static review of that
surface, not a certification of every feature in the upstream shell.

AppleSearch retains the shader with source attribution and implements its own
small QML adapter for the backdrop and uniforms. The broader shell's clipboard
history, IP-based weather lookup, notification service, session controls, settings
commands, and arbitrary command launch helpers are not imported.

Shader compilation uses the installed Qt `qsb` compiler or a Nix build from the
reviewed shader source. Compiled output is cached by source hash. Upstream binary
shader bundles are not downloaded or executed. Wallpaper discovery uses fixed,
read-only daemon queries; image and shader URLs accept local absolute paths only.
Window captures are GPU textures in memory, with no screenshot files or network
uploads. Capture and geometry timers stop when the panel is hidden.

After that review, verification covered shader compilation, two concurrent cold
cache requests, warm cache reuse without a compiler, and the missing-compiler
fallback. `nix build . --no-link` passed. Both local Quickshell 0.3.0 and packaged
Quickshell 0.3.2 rendered the shader without runtime warnings in a separate test
namespace. Visual checks covered live windows, collapsed and expanded search,
an exact application match, hiding the panel, and namespace reuse between the
local and packaged launchers. The test instance was stopped afterward.

The resize regression was then reproduced with deterministic, delayed search
responses: the old panel used 14 different native window sizes and shrank
from 585 to 170 pixels while a new query was pending. The updated UI retained one
native window size and position, held the visible height while waiting, and
collapsed only after a completed empty result or a cleared query. The backdrop
texture now keeps its extent during card animation, and center magnification is
disabled so resizing does not move its sampled background.

The shader's original fixed gray tint was subsequently replaced by a color
uniform populated from Stylix `base00`. The palette is read as local JSON; only
six-digit hexadecimal Base16 values are accepted, with no evaluation or command
execution. This shader change adds no new sampling loops or external interfaces.

A later live-update check reproduced a stopped window export: capture requests
continued, but the recording context was gone and the new window never appeared
in the glass. The adapter now requests frames only after initial content is ready,
rebinds failed exports with a bounded retry timer, releases sources when hidden,
and polls window geometry at roughly 30 Hz. A controlled local window switching
between red, blue, and green updated the idle glass correctly after the fix,
including after resizing that window. The shader and its sampling loop are unchanged.

Workspace animation is reconstructed by `WorkspaceMotion.qml` because toplevel
exports omit Hyprland's workspace render offset. It reads the animation tree,
enabled flag, workspace gap, and wraparound flag with one fixed `hyprctl --batch`
query. Responses are parsed as JSON; no response text becomes executable code.
The adapter keeps outgoing windows through the transition, applies configured
slide/fade transforms, and stops its animation timer while hidden. This mirrors
configured timing, rather than reading private compositor animation state.

Runtime checks covered regular and rapid switches, switching back, opening after
a hidden workspace change, and opening/closing a special workspace. Additional
frame samples compared the color behind the glass with the same moving window
outside the glass during both directions of the configured slide animation.
