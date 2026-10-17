#!/bin/sh
# Run MAME on mycore against the shadow romset, headless and deterministic.
#
# Always pass -seconds_to_run: a Lua script that ends the run with
# machine:exit() has proved unreliable, while -seconds_to_run plus an
# add_machine_stop_notifier that writes the results is repeatable to the frame.
#
# Nothing here may touch the display.  `-video none` stops MAME rendering to a
# window but does NOT stop it creating one, and MAME's own defaults are
# fullscreen (window 0, maximize 1) -- which on macOS makes the desktop jump
# to another Space every time a probe runs, several times a minute.  Three
# measures, because they fail independently: SDL_VIDEODRIVER=dummy keeps SDL
# from opening the display at all (it is read before MAME parses anything),
# -videodriver dummy says the same through MAME, and -window -nomaximize
# means that if a window is created regardless it is a small one that steals
# no Space.  Verified: snapshots come out byte-identical to a normal run.
root=$(cd "$(dirname "$0")/.." && pwd)
SDL_VIDEODRIVER=dummy \
exec mame mycore -rompath "$root/.mame/roms" \
    -video none -videodriver dummy -window -nomaximize \
    -sound none -nothrottle -skip_gameinfo \
    -cfg_directory "$root/.mame/cfg" -nvram_directory "$root/.mame/nvram" \
    "$@"
