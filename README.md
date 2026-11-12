# T3 Island

A small macOS app that hangs a black "island" from the top of the screen, over the notch or in the
middle of the menu bar, showing your T3 Code threads and the usage limits of your agent CLIs.

- **Compact:** on the left, faces for threads waiting on you (questions, failures, fresh replies and
  idle unsettled threads), then a divider, then the working threads, up to 3 faces each plus a count.
  On the right, one ring per provider (Claude, Codex) with the quota left in its 5-hour window
  (100% = untouched, 0% = used up); Settings can switch this to the weekly or the lowest window. The number turns amber at 40% left and red at 15%.
- **Expanded:** click the island. It shows a card per provider (session and weekly windows, time to reset),
  then the threads in sections: waiting on you, working (up to 3 working rows are always kept) and snoozed.
  Click a section title to collapse or expand it, as in T3's sidebar; the choice is remembered. Click a thread to open it in T3. Move the mouse away or click elsewhere to close.
- **Footer** of the expanded island: Open T3 Code, Settings and Quit.

## Settings

Changes apply immediately and are saved in UserDefaults (`defaults delete local.t3island settings` resets them).

- **Limits:** which window the collapsed island shows (5-hour, weekly or lowest), quota left or used, the warn (amber) and critical (red) thresholds, and which providers to show.
- **Threads:** show working threads, threads waiting on you, idle threads, and how many faces per group.
- **Behaviour:** open on hover instead of click, and launch at login.

Faces follow how much a thread needs you. Needs you (amber pulse), failed, replied (unread result) and
idle (your turn) are in full colour; working threads are greyed out with a spinning ring, since they need
nothing until they finish. Each thread keeps its own blob shape and colour, derived from its id.

## Build and run

Needs macOS 13+ and Xcode or the Command Line Tools.

```sh
./build-app.sh            # builds build/T3 Island.app
open "build/T3 Island.app"
./build-app.sh --install  # also copies it to ~/Applications
```

To start it at login, run `./build-app.sh --install`, open the installed copy, and turn on
Settings → Launch at login. It registers the copy you turn it on from, so don't use the one in `build/`.

`swift run T3Island --snapshot out/` renders the island states and an avatar gallery to PNGs
using your live data, without opening a window. Add `--demo` to use made-up threads and limits instead,
for screenshots you can share. `swift run T3Island --demo` runs the island itself on that data, with one
thread changing state every 2 s, which is handy for checking the update animations.

## Data sources

The app only reads T3 Code's local state. It makes no network calls and reads no credentials.

| What | Where |
| --- | --- |
| Usage limits | `~/.t3/caches/<provider>.json` → `usageLimits`, which T3 refreshes from the Claude and Codex CLIs |
| Threads, runs, pending questions | `~/.t3/userdata/statev2.sqlite`, opened read-only and polled every 2 s |
| Thread links | `t3code://threads/<environment-id>/<thread-id>` |

Set `T3CODE_HOME` to read a different T3 data directory.

The thread list is T3's inbox: unsettled, unarchived top-level threads, plus any thread that is running
or has an open question. Snoozed threads follow T3's rule: they stay out until the snooze ends, unless a
new question or failure arrives after you snoozed them; the dropdown shows how many are snoozed and when the
next one comes back. The query depends on T3's internal schema, so a T3 update can break it. When that
happens the island shows the SQLite error in its expanded view.

## License

MIT, see [LICENSE](LICENSE).
