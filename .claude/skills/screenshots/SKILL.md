---
name: screenshots
description: Capture screenshots of the running omacal app on Hyprland — for the README, for reviewing a design change, or to see what a view actually looks like. Use whenever a task asks to take, retake, or update screenshots, or to check a layout visually rather than by reading QML. Covers the Hyprland dispatch syntax that works, how to get unscaled native-resolution captures, keeping personal calendar data out of the frame, and the safety rule for synthetic keystrokes.
---

# Screenshots of omacal

`bin/screenshots` does the whole run: `bin/screenshots` for every view, or
`bin/screenshots month week` for a subset. Read this before changing it —
most of the obvious approaches fail on current Hyprland, and one of them
types into the user's terminal.

## The rules that matter

**Never send a keystroke without checking focus first.** `wtype` types into
whatever window is focused. If the app is not focused, the keys land in the
terminal running the agent — as shell input. Every keystroke in the script
goes through a guard that aborts unless `hyprctl activewindow -j | jq -r
.class` is `omacal`. Keep it that way.

**The window must be visible on the active workspace.** Hyprland does not
render hidden windows, so a window on another workspace captures as whatever
is actually on screen — which is how an early attempt produced a screenshot
of the terminal. Either focus the app first or check that its workspace is
the active one before grabbing.

**Personal data.** A screenshot of a real session exposes event titles and the
account name in the sidebar. Before capturing anything that may be published,
either ask the user to disable their private calendars, or seed a throwaway
account with `bin/demo-data` and show only that. Do not commit screenshots
containing someone's real calendar without asking.

## Hyprland specifics (this is where the time went)

This Hyprland build uses a Lua config, and `hyprctl` behaves accordingly:

- `hyprctl keyword …` → **fails**: "keyword can't work with non-legacy
  parsers. Use eval."
- `hyprctl dispatch focuswindow class:omacal` → **fails**: the shim wraps the
  argument into `hl.dispatch(focuswindow class:omacal)`, which is not Lua.
  Quoting it does not help; `hl.dispatch("…")` wants a dispatcher object.
- What works:

```sh
hyprctl dispatch 'hl.dsp.focus({ window = "class:omacal" })'
hyprctl dispatch 'hl.dsp.window.fullscreen()'      # acts on the FOCUSED window
hyprctl eval 'hl.monitor({ output = "DP-1", mode = "3840x2160@240.01601",
                           position = "0x0", scale = 3 })'
```

`hl.dsp.window.fullscreen()` toggles whatever currently has focus — focus the
app *and* verify it before calling, or you will fullscreen the user's
terminal. `hyprctl eval` returns "ok" for everything and never prints values,
so it is useless for inspection; read state from `hyprctl monitors -j`,
`hyprctl clients -j` and `hyprctl activewindow -j` instead.

## Getting a sharp image

`grim` writes the output's physical pixels for the region it is given, and
regions are in logical coordinates. On a 3840x2160 monitor at scale 2 the
whole screen is 1920x1080 logical, so `grim -g "0,0 1920x1080"` yields
2560x1440 or so once fullscreen chrome is involved — and scaling it down
afterwards throws away detail.

Instead raise the display scale for the capture and grab **unscaled**:

| display scale | logical size | `grim -g "0,0 <logical>"` output |
|---|---|---|
| 2 | 1920x1080 | 2560x1440 (mixed, upscaled feel) |
| 3 | 1280x720  | **3840x2160 native** |

Do not pass `-s` — it resamples. Always restore the original scale in an
`EXIT` trap, and re-read it from `hyprctl monitors -j` first rather than
assuming; one run left the user's display at scale 3 because the restore
raced the script's exit.

Note the app lays out at the *logical* size, so at scale 3 it renders a
1280x720 interface at 3x. That is sharp but shows less content; if a shot
needs more content on screen, use scale 2 and accept 2560x1440.

## Timing and content

- Give the app ~8 s after launch: calendars connect and events land
  asynchronously, and a screenshot taken too early shows an empty grid.
- ~1.5 s after a view switch, so the layout settles.
- Day and week open on the working day (07:00 at the earliest), so captures
  taken late at night still show a busy grid.
- For the event popover use **Return** (creates at 09:00 on the focused day)
  rather than `Ctrl+N` (creates at the next hour, which at 2 am anchors the
  popover to an empty small-hours slot).

## Checking the result

Read the PNG back and look at it — that is how the year view's wasted
vertical space, the popover pointing at nothing, and the night-time grid were
all caught. A screenshot that was never looked at is not evidence.
