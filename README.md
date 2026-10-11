# Video Tab Counter

**English** ｜ [简体中文](README.zh-CN.md)

Chrome tells you how many tabs are open right now, but not **how many videos you finished yesterday, or how long they were**.
This little tool turns that into a single number in the Windows system tray.

![Details panel (today)](docs/screenshot-today.png)

**Illustration only: the numbers in the screenshot are sample data, not anyone's actual usage.**

**Who it's for**: anyone who watches tutorials and technical videos in Chrome and wants to know how many they finished and how long that took.

**Why keep it in the tray**

- **Entirely local**: what you watched and for how long stay on this machine; only looking up video lengths goes online.
- **No admin rights, no runtime, no execution-policy changes**: double-click the launcher and it runs.
- **One number is enough**: the tray icon shows how many video tabs are open, and hovering gives today's and yesterday's counts and lengths.
- It reads the tab strip every 5 seconds and uses 100–150 MB of memory.

Version 1.1 ｜ MIT license (see [LICENSE](LICENSE)) ｜ A personal tool; no promise it fits your setup

---

## What it looks like

- **Icon**: a blue circle showing how many video tabs are open. Up to three digits are drawn directly; anything above shows 999.
  ![Icon](docs/icon.png)
- **Hovering** shows four lines: the title, how many are open now, how many were finished today and their total length,
  and the same for yesterday. When a day has no known durations, that line shows the count only.
  ![Tray icon and hover tooltip](docs/tray-tooltip.png)

- **Right-click menu**:

| Item | What it does |
| --- | --- |
| Details | Pops up a panel from the bottom-right; clicking elsewhere dismisses it |
| Refresh now | Reads again immediately (no popup) |
| Open data folder | Opens the folder the tool lives in |
| Exit | Quits |

A left click on the tray icon toggles the details panel: click to open it, click again to close it.
You can also dismiss it by clicking outside the panel or hitting the × in its top-right corner.
The right-click menu offers the same actions.

### The details panel

It is meant to be read as a picture, not as text:

- Three tabs at the top switch between **Today / Yesterday / Last 7 days**; Today is the default.
- The big number in the middle is the total length of the videos finished in that period. The small line under it
  shows how many, how many have unknown durations, and how many are open right now.
- Then the **finished videos** list: one row each, with the title, a bar drawn in proportion to its length, and the length on the right.
  When the list does not fit, a scrollbar appears on the right; the mouse wheel and dragging it both scroll.
- At the bottom, **Last 7 days** draws one bar per day, its height being that day's total. Only the "Last 7 days" tab
  shows this strip; hovering a bar highlights it and shows the date and length above it.

![Last 7 days](docs/screenshot-week.png)

![Open right now](docs/screenshot-open.png)

## Requirements

- Windows 10 or 11 (PowerShell 5.1 and .NET Framework are built in, so there is no runtime to install)
- Chrome installed, and you actually watch videos in it
- No administrator rights, no change to the PowerShell execution policy
- Counts and durations are computed entirely on your machine; only *looking up video lengths* goes online

## Installation

1. **Unblock the files before running them** — do not skip this.
   - Do not run it straight from the zip viewer; that extracts to a temp folder and every path gets mangled.
     Extract the whole folder to disk first.
   - Files downloaded from the internet carry a "from the internet" mark. Without unblocking, double-clicking
     triggers "Windows protected your PC". Fix: select all files in the folder → right-click → Properties →
     tick *Unblock* at the bottom → OK. Do this for every file; it does not matter which is `.vbs` and which is `.ps1`.
   - If there is no *Unblock* checkbox and you are still blocked: click *More info* in the dialog, then *Run anyway*.
   - Windows 11 hides extensions by default, so you will see `start-counter` instead of `start-counter.vbs`.
     To show them: Explorer → View → Show → File name extensions.

2. Put the whole `video-tab-counter` folder somewhere permanent, for example `D:\tools\video-tab-counter`.
   The path does not matter — spaces and non-ASCII characters are fine. **But it must be writable**: do not put it under
   `Program Files` or anywhere that needs administrator rights, because the tool writes its data and logs inside its own folder.

   Try to settle on a location. Moving the folder later still works, but the autostart shortcut from step 5 breaks
   (the symptom is that no icon appears after a reboot); delete that shortcut and recreate it.

3. Double-click the launcher (`start-counter`). The icon appearing in the tray means it is installed; give it a second or two.

4. No icon, or you cannot find it:
   - Click the little up arrow (∧) at the bottom-right of the taskbar: that is the hidden-icons panel, and it is usually in there.
   - To keep it visible: Settings → Personalization → Taskbar → Other system tray icons, and turn it on.
   - **Note**: Windows remembers tray items per program, and both tools run under PowerShell, so it shows up in that list
     as "Windows PowerShell", not "Video Tab Counter". Recognise it by its look: a blue circle with a number.

5. To start it automatically at logon, pick either way:

   **Way A**: right-click the launcher → Send to → Desktop (create shortcut); press `Win + R`, type `shell:startup`,
   press Enter, and paste the shortcut into that Startup folder.

   **Way B**: in the Startup folder, right-click → New → Shortcut, and use this as the location
   (replace the path with yours; keep the quotes, especially if the path has spaces):

   ```
   wscript.exe "D:\tools\video-tab-counter\start-counter.vbs"
   ```

### Desktop icon

A shortcut to a script shows the generic Windows script icon by default, and all three tools look identical.
To make it match the tray dot: right-click the shortcut → Properties → Change Icon → pick `icon.ico` in this folder.

## Usage

- Leave it alone; it reads Chrome's tab strip every 5 seconds.
- For details, right-click the icon and choose *Details*.
- Only one instance runs at a time: double-clicking again makes the extra one exit by itself.
- It uses roughly 100–150 MB of memory.

## Under the hood

- **Live data comes from UI Automation**, reading Chrome's tab strip directly. It does not touch Chrome's session files
  (the readable one is a snapshot from startup, and the live one is locked while Chrome runs).
  A full read of the tab strip measures 46–64 ms, which is why the poll interval is 5 seconds.
- **Video lengths come from the official YouTube Data API v3** (`videos.list`): up to 50 video IDs per request,
  the first request takes 2–3 seconds to connect and the rest take a bit over 100 ms and return about 8 KB.
  A length, once fetched, is cached forever and never re-fetched.
- **State is written to a temp file and then swapped in**; if it cannot be read, the remains are kept, a line goes into the log,
  and the previous backup is restored — it is never treated as a first run.
- The tray icon and the details panel are drawn at runtime, with no image assets; it sits at roughly 100–150 MB of memory.

## What counts as "finished" (where the number comes from)

- A video counts as finished when it *used to be* in the tab strip and is *no longer* there: either you closed the tab,
  or the playlist moved on to the next item.
- It has to have been **seen for at least 10 seconds** to count once. Opening it, realising it was a misclick and closing it
  immediately does not count.
- It scans the tab strip every 5 seconds, so "how long it was seen" is measured at that granularity:
  10 seconds means at least two scans.
- Which day it counts towards is the moment it **left the tab strip**, not when it was opened.
- The same video watched twice counts once; the title decides that. Re-watching within one day does not double count,
  and in "Last 7 days" watching it again on another day does not either; its length is counted once too.
  If YouTube changed the title in between, it will look like two videos — a known rough edge.
- "Open right now" is the number of video tabs currently open.
- "Today" switches at your machine's midnight.
- The total is one sentence: for the videos finished that day, add up how long each video is.
  It records the video's own length; it has nothing to do with how long you stayed on the page, and that data is not available anyway.
- Do not confuse the two numbers: "open right now" counts current tabs, while "finished today"/"finished yesterday" are the ones
  that left the tab strip. Only the latter are added into the total length. Seen videos are cached locally with their lengths,
  but that is only a cache and never counted on its own.
- Only YouTube currently provides durations. Videos on other sites still count towards the quantity, but have no length:
  the panel marks them "unknown length" and leaves them out of the total. Once a length is fetched it is filled in automatically.

## What you will see after a fresh install

Today and yesterday start from zero, so both are 0 at first. "Finished yesterday" only gets a number on the second day.
That is not a bug.

Without an API key, the tooltip simply omits the "X hours Y minutes" part and shows the count only.

## Reset

Right-click → Exit, delete `state.json`, start again, and counting restarts from zero.
The duration cache `durations.json` can stay; there is no need to fetch it again.

## Optional: video durations (needs internet)

It works without this; you just get no durations or totals. Being offline only drops a few videos from the total —
the counts keep working.

1. Open the Google Cloud console and create a project.
2. On the left, "APIs & Services" → "Library", search for YouTube Data API v3, click Enable.
3. "APIs & Services" → "Credentials" → "Create credentials" → "API key".
4. It is worth restricting the key: choose "Restrict key", tick only YouTube Data API v3, and save.
5. Save it as a key file — this is the step where things most often go wrong:
   - Open Notepad, paste the string starting with `AIza`. No quotes, no extra blank lines.
   - When saving, set "Save as type" to *All files* and the file name to `yt-api-key.txt`.
     If you leave it as "Text Documents", Windows silently appends .txt and the tool will not find it.
   - Put the file in the `video-tab-counter` folder, next to `counter.ps1`.

To check it worked: wait five to ten minutes, then right-click → *Details* and see whether lengths appear.

The tool only sends the video IDs and your key to YouTube. It sends nothing else about your machine.
One request covers up to 50 videos, which is far more than personal use needs.

## Troubleshooting

**The icon is gone**
Click the ∧ arrow on the taskbar to check the hidden-icons panel; then check Settings → Personalization → Taskbar →
Other system tray icons (it appears there as Windows PowerShell).

**The numbers never move**
That is expected while Chrome is closed; it resumes when Chrome comes back. If Chrome is running and it still does not move:
right-click → *Refresh now*. If that fails, look at the logs below.

**The icon stopped appearing at logon although it used to work**
Most likely the folder was moved and the autostart shortcut broke. Delete it and recreate it.

**Double-clicking the launcher does nothing**
Do step 1 (unblocking) first, then check whether antivirus blocked the `.vbs`.
You can also run it by hand: open PowerShell from the Start menu, paste the line below and press Enter, and see whether
anything red appears (the execution policy has to be passed explicitly; right-clicking → "Run with PowerShell" gets blocked by policy):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\tools\video-tab-counter\counter.ps1" -Once
```

**Every video shows "unknown length"**
Check whether `yt-api-key.txt` became `yt-api-key.txt.txt`; confirm the file contains nothing but that one string;
then look at `duration-fetch.log`.

**The numbers look clearly wrong**
Delete `state.json` and start counting again.

## Reading the logs

`counter.log` and `duration-fetch.log` sit in the tool folder; double-clicking opens them in Notepad.
They are small (tens of KB at most) and are recreated if you delete them.

In normal operation `counter.log` is empty or has a few lines. If it contains something like `skipped a round`,
it means Chrome's tab strip could not be read on those passes and changes during them were missed — keep the log so it can be looked at.
If the log is empty and something is still wrong, work through the troubleshooting section above.

## Uninstalling completely

1. Right-click the tray icon → Exit.
   Do not skip this. Deleting the folder while it runs technically works, but the process keeps going in the background,
   fails to find its files every few seconds, and you would have to kill it from Task Manager anyway.
2. Confirm it is really gone: press `Ctrl+Shift+Esc` for Task Manager, switch to the *Details* tab, right-click a column header →
   Select columns → tick *Command line*, find `powershell.exe`, and check whether `counter.ps1` still appears in a command line.
   If the folder is already deleted but the process is still there: end that `powershell.exe` in Task Manager, or reboot.
3. Delete the whole `video-tab-counter` folder. Your watch history and duration cache live inside it and go with it.
4. Delete the Startup shortcut if you created one. `Win + R`, type `shell:startup`, press Enter.
5. If you toggled it in "Other system tray icons", a record stays there (it records the PowerShell program, not this tool).
   No need to clean it up; it does nothing.
6. If you configured a YouTube key, consider deleting or disabling it in Google Cloud. Uninstalling this tool does not touch it.

Nothing else on the system was changed: no services, no installer, and the only registry trace is the tray toggle from step 5.

## Updating

This folder is everything; there is no auto-update. If you keep a newer version: right-click the tray icon → Exit,
overwrite the whole folder with the new version, and double-click the launcher again.
Keep `state.json` and `durations.json` and no history or cached length is lost.

The version number is under the title of this README, and in the comment at the top of `counter.ps1`
(open it in Notepad — double-clicking a `.ps1` runs it).

## Known rough edges

- Only one Chrome window is counted. With several Chrome windows open, only the tabs of the main window are seen.
- A plain list or channel page opened after Chrome started can be taken for a video tab, so "open right now" may be one too high;
  when such a tab is closed, "finished today" may also gain one.
- If YouTube changes a video's title, it is treated as two videos.
- Closing all of Chrome (quitting the browser, not closing a tab) does not turn the open tabs into "finished";
  the tool protects against that and keeps its state until Chrome comes back.

## The other two tools in this set

- [Screen-On Time](https://github.com/NutshellLee/screen-time-counter) — how long your screen was on today
- [LLM Token Counter (DSH)](https://github.com/NutshellLee/dsh-token-counter) — how many tokens this machine's DSH used today

## Version history

- **1.1** (2026-10-12) — the tray click is now a toggle: click to open, click again to close. Fixed title cleaning: the status text Chrome appends to tab names (audio playing, high memory usage) is now stripped repeatedly, and 10 dirty keys from the past were repaired at startup.
- **1.0** (2026-10-12) — first release: the tray icon shows how many video tabs are open; the details panel lists the finished videos and their lengths for today / yesterday / the last 7 days; the right-click menu has refresh, open folder and exit.

## What each file is

| File | What it is |
| --- | --- |
| `counter.ps1` | The main program |
| `start-counter.vbs` | Launcher — double-click this one |
| `fetch-durations.ps1` | The helper that fetches lengths; the tool starts it on demand |
| `README.md` / `README.zh-CN.md` | This document, in English and Chinese |
| `AGENTS.md` | Notes for AI or developers changing the code; safe to ignore as a user |
| `NOTES.md` | How it was built and what went wrong along the way, if you like the why |
| `LICENSE` | License |
| `state.json` / `durations.json` / `*.log` | Created at runtime; safe to delete |

To change the code, read [AGENTS.md](AGENTS.md). To see **how** these numbers are pulled out of Chrome and which
dead ends were hit on the way, read [NOTES.md](NOTES.md).
