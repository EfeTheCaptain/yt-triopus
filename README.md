# yt-triopus

Three arms, one goal: pull everything, verify it landed, never lose a file.

A `yt-dlp` wrapper that downloads in parallel, tracks state from disk instead
of a fragile archive, and verifies every file actually exists. Built for
people who have been burned by wrappers that say "done" while silently
dropping videos.

For triage when something looks wrong, see `WHEN-BROKEN.txt` in the same
folder.

## Contents

- [Why this app](#why this app)
- [Features](#features)
- [Folder layout](#folder-layout)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Startup checkup](#startup-checkup)
- [Output layout](#output-layout)
- [How it works](#how-it-works)
- [Reading the progress display](#reading-the-progress-display)
- [Why the architecture looks like this](#why-the-architecture-looks-like-this)
- [Cookies: extraction methods and their limits](#cookies-extraction-methods-and-their-limits)
- [Age-restricted content: the three blockers](#age-restricted-content-the-three-blockers)
- [PO token provider (bgutil) setup](#po-token-provider-bgutil-setup)
- [Debug mode](#debug-mode)
- [Migration mode](#migration-mode)
- [Files created in the script folder](#files-created-in-the-script-folder)
- [Diagnostic commands](#diagnostic-commands)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Editing the script safely](#editing-the-script-safely)

---


## Why this app

There are dozens of `yt-dlp` wrappers. Most of them download one video at a
time, trust an archive file that can silently drift out of sync with the disk,
and stop working the moment an age-gate or bot check appears.

This one was built around three things they don't do.

### 1. Three workers pull simultaneously

Most wrappers, even good ones, feed videos to yt-dlp one at a time. Wall-clock
time for a 130-video channel is the sum of every video's download time. Three
workers means three videos are downloading in parallel — total time is roughly
`total / 3`, network permitting. The progress display shows each worker
separately, so you can see all three streams moving at once:
[14:32:21 +00:15] Worker1: 2/44 Worker2: 1/44 Worker3: 2/44 | Total 5/132 @ 105,2 MB/s

Each worker is an independent process with its own yt-dlp child, its own
`-N` fragment parallelism inside each video, and its own slice of the
channel. When one stalls on a throttled URL, the other two keep downloading.
It has never been clear why this is rare in YouTube downloaders — it's the
single biggest speed win available, and it costs nothing but one more
`Start-Process`.

### 2. Reaches anything yt-dlp can reach

`yt-dlp` supports 1,800+ sites — YouTube, Vimeo, Twitch, Twitter, SoundCloud,
the entire `.onion` of extractors, and most of the browser-viewable web. This
wrapper inherits all of it. Any content you can watch in a browser (no DRM,
no paywall you haven't got cookies for), `yt-triopus` can download.

The age-restricted content tooling — bgutil PO tokens, deno JS challenge
solver, cookie extraction — is specifically tuned for YouTube, because that's
where the strongest anti-download defenses are. On other sites, most of that
machinery is inert and yt-dlp just works. The three-worker parallelism applies
everywhere.

### 3. No silent losses

The most common complaint about other wrappers is some variant of: *"I told
it to download 130 videos, it said 130 succeeded, but my folder has 110."*

Most wrappers use yt-dlp's `--download-archive` to track what's been
downloaded. That archive records **what yt-dlp claimed succeeded**, not what's
actually on disk. The two drift apart silently:

- Delete a file, its ID stays in the archive forever. It never re-downloads.
- Two videos with the same sanitized title map to one filename. The second is
  skipped by `--no-overwrites`, but yt-dlp records both as downloaded. Archive
  grows; folder does not.
- yt-dlp says "success" and exits 0 even when the merge failed and no final
  file exists. The archive doesn't know the difference.

What this app does instead:

- **Every filename ends with `[11-char-video-id]`.** Two videos with the same
  title can't collide. Any file on disk can be mapped back to its ID.
- **The disk is the source of truth.** Every run scans the output folder and
  diffs it against yt-dlp's enumeration. Delete a file — next run fetches it.
  No archive file, no stale state.
- **Verification after every run.** Workers claim success; the master
  rescans the disk and confirms every requested ID actually landed. Failures
  go into `FAILED.txt` with the yt-dlp error message, not into "downloaded"
  with no file.

The result: `Verified on disk: 132/132` means 132 files are literally in your
folder. Not 132 video IDs in a text file. Not 132 "success" messages from
yt-dlp. 132 files.

### What it doesn't do

- **Not a GUI.** Command-line, script-friendly, no buttons.
- **Not cross-platform.** Windows-only, because the parts that matter (Shell
  COM Downloads lookup, `taskkill /T` process-tree kill, Waterfox cookie
  paths) are Windows-shaped.
- **Not magic.** Age-restricted content still needs a properly age-verified
  Google account behind the cookies. Three independent yt-dlp blockers must
  all be satisfied — cookies, PO token, JS challenge solver — each documented
  in `WHEN-BROKEN.txt`. If the underlying account isn't age-verified, no
  wrapper fixes it.
- **Not a re-implementation of yt-dlp.** All download logic, format selection,
  cookie handling, and site compatibility come from yt-dlp. This wrapper only
  handles: parallel orchestration, disk state, verification, and the diagnostic
  surface that tells you what's wrong when something breaks.

**If you want a dead-simple single-video downloader, use one of the many
existing ones.** If you've ever wondered *"why does my wrapper think it has
130 videos when I can count 110?"* — this is the answer.

## Features

- **Parallel workers** - splits a channel or playlist across N `yt-dlp` processes, each downloading its own slice.
- **Disk-based resume** - every filename ends with `[11-char-video-id]`, so the script can tell which videos you already have by scanning the output folder. Deleting a file is enough to make the next run re-download it.
- **Post-run verification** - after workers exit, the master process rescans the disk and confirms every requested ID actually landed. Anything missing is written to `FAILED.txt` with the error message yt-dlp produced.
- **Startup checkup** - one-time environment check on each launch. Catches missing binaries, broken plugin folder structure, wrong cookie path. All checks are advisory - the run proceeds even with warnings, because not all content needs all features.
- **Live progress** - workers run hidden; the main console polls every 5 seconds and shows per-worker progress and aggregate speed.
- **Quality is yt-dlp's best** - video mode uses `bv*+ba/b`, audio mode uses `ba/b` transcoded to MP3.
- **Browser cookies** - pulls cookies from a Firefox-family profile so age-restricted, subscriber-only, or logged-in content works.
- **PO token provider** - starts `bgutil-pot` (a local PO token server) so YouTube's bot protection does not throttle enumeration or downloads.
- **Case-sensitive ID matching** - required on Turkish-locale systems; see [Troubleshooting](#troubleshooting).

---
## Folder layout

The script expects (and works with) this layout:

  <anywhere>\
  +-- yt-dlp.exe                    <- shared, may live in a common tools dir
  +-- ffmpeg.exe                    <- optional, alongside yt-dlp.exe
  +-- yt-downloader\                <- everything else, app-specific
      +-- yt-downloader.ps1
      +-- run.bat
      +-- setup.bat
      +-- cookies.ps1
      +-- README.md					(this file)
      +-- WHEN-BROKEN.txt
      +-- REQUIREMENTS.txt          
      +-- deno.exe
      +-- bgutil-pot.exe
      +-- yt-dlp-plugins\
      |   +-- bgutil-ytdlp-pot-provider\
      |       +-- yt_dlp_plugins\
      |           +-- extractor\
      |               +-- getpot_bgutil.py
      |               +-- getpot_bgutil_cli.py
      |               +-- getpot_bgutil_http.py
      +-- cookie.txt                (created by setup.bat)
      
      **The script searches for `yt-dlp.exe` in three places, in order:**

1. Its own folder (`yt-downloader\yt-dlp.exe`)
2. The parent folder (`yt-dlp.exe` — where it sits in the layout above)
3. `PATH`

So the layout above works, and so does "everything in one folder" (drop all binaries into `yt-downloader\`) or "`yt-dlp.exe` is somewhere on `PATH`". Only `yt-dlp.exe` is flexible — everything else (`deno.exe`, `bgutil-pot.exe`, `yt-dlp-plugins\`, `cookie.txt`) must be inside `yt-downloader\`, alongside the `.ps1` and `.bat` files.

Why the split? `yt-dlp.exe` is a general-purpose tool you may share across projects, and it self-updates (`yt-dlp -U`) — keeping it in a common location means one copy to update, not one per app. Everything in `yt-downloader\` is specific to this downloader and can be moved as a unit.

---
## Requirements

- **Windows 10 or 11** with the built-in Windows PowerShell 5.1. No PowerShell 7 required.
- **Binaries** placed next to the script:
  - `yt-dlp.exe`
  - `deno.exe` - provides a local JS challenge solver for YouTube.
  - `bgutil-pot.exe` - provides PO tokens. Recommended; without it, age-restricted content fails but normal content works.
  - `ffmpeg.exe` - optional; if not present in the folder, the script uses whichever is on `PATH`. Required for video+audio merging.
- **The bgutil yt-dlp plugin** - extracted under `yt-dlp-plugins\bgutil-ytdlp-pot-provider\yt_dlp_plugins\`. See [PO token provider setup](#po-token-provider-bgutil-setup).
- **A Firefox-family browser profile** with a YouTube login, for age-restricted or members-only content.
- **Disk space** - 4K video adds up fast; budget several GB per hundred videos.

---

## Installation

1. Create a folder for the script, e.g. `C:\Tools\yt-downloader\`.
2. Place `yt-downloader.ps1`, `run.bat`, `yt-dlp.exe`, `deno.exe`, `bgutil-pot.exe` into it. Add `ffmpeg.exe` if you want it self-contained (or leave it out and rely on `PATH`).
3. Extract the bgutil plugin under `yt-dlp-plugins\bgutil-ytdlp-pot-provider\yt_dlp_plugins\`. Verify with the [diagnostic command](#diagnostic-commands) below.
4. Run `setup.bat` once to configure cookies. It prompts for a browser and saves the choice to `cookie.txt`.
5. **Before editing any `.ps1` file:** save it as UTF-8 with BOM (Notepad3: File → Encoding → "UTF-8 with Signature"). Windows PowerShell 5.1 reads `.ps1` files as ANSI unless they carry a BOM; without one, any non-ASCII character (em dash, curly quote, arrow) corrupts and the script won't parse. See [Script won't parse](#script-wont-parse---unexpected-token-errors) if you've already hit this.
6. Double-click `run.bat` to start downloading.


No installation, no PATH changes, no admin rights. The script uses `$PSScriptRoot` to find its own folder, so it works from anywhere.

---

## Configuration

Cookie profile is set by `setup.bat` and saved to `cookie.txt`. To
change it: run `setup.bat -Reset`, or delete `cookie.txt` and run
`setup.bat` again.

## Usage
### Interactive mode
Double-click run.bat. It prompts for a URL. Accepts a channel URL, playlist URL, single video URL, or .txt file of URLs (one per line). Type q to quit.

### URL on the command line
```bat
run.bat "https://www.youtube.com/@ChannelName/videos"
```
Quote URLs that contain &. Playlist URLs like ...?list=UU...&index=1 get chopped by cmd's argument parser at the & unless wrapped in double quotes.

### The run.bat launcher
run.bat is a thin shim:

```bat
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0yt-downloader.ps1" -Workers 3 -Fragments 4 %*
echo.
echo Exit code: %ERRORLEVEL%
pause
```
Anything after the batch filename is forwarded to the .ps1. Default -Workers 3 -Fragments 4 is baked in; override by passing those flags again.

Earlier versions of this project used yt-downloader.bat. Both names work identically - the .bat filename is your choice. Whichever you pick, keep it consistent with what the docs say.

### PowerShell directly
```powershell
.\yt-downloader.ps1 -Url "https://www.youtube.com/@ChannelName/videos" -Workers 4 -Fragments 8
```
### Parameters
| Parameter | Type | Default | Meaning |
| --- | --- | --- | --- |
| -Url | string | (prompt) | Channel, playlist, video URL, or path to a .txt file of URLs. |
| -Mode | video \| audio | video | video = bv*+ba/b, merged to .mp4. audio = ba/b, transcoded to .mp3. |
| -Workers | int | 1 | Number of parallel yt-dlp processes. |
| -Fragments | int | 8 | Passed to yt-dlp as -N. Parallel fragment downloads within one video. |
| -WorkerIndex | int | -1 | Internal. Set by the master. Do not pass manually. |
| -Migrate | switch | off | One-time rename pass for files from the old %(title)s.%(ext)s template. |
| -DebugEnum | switch | off | Prints enumeration internals. See Debug mode. |
| -SkipCheckup | switch | off | Skip the startup environment check. Only useful after one clean checkup confirmed everything works. |
### Common invocations
Download an entire channel at best quality, 4 workers:

```bat
run.bat "https://www.youtube.com/@ChannelName/videos" -Workers 4
```
Download a channel's audio only:

```bat
run.bat "https://www.youtube.com/@ChannelName/videos" -Mode audio
```
Re-run the same command later - only new uploads and anything you deleted from the folder get fetched.

Download a single video:

```bat
run.bat "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```
Batch file with a list of URLs:

```bat
run.bat "C:\Users\You\list.txt"
```

## Startup checkup
Every non-worker run performs a short environment check before downloading:
=== Checkup ===

yt-dlp.exe

deno.exe

bgutil-pot.exe

ffmpeg (PATH)

plugin folder (3 .py files)

cookies (firefox)

bgutil (PO token via HTTP)

JS runtime (deno)

Three result levels:

- **`+` (green)** - check passed.
- **`!` (yellow)** - warning; the run continues but the feature may not work. Common: ffmpeg not found (merging fails), cookies not configured or path missing (age-restricted content fails), bgutil or deno not visible to yt-dlp (age-restricted content fails).
- **`X` (red)** - hard failure; the script exits without downloading. Common: `yt-dlp.exe` missing, plugin folder missing or wrong structure.

The `cookies` line reflects what `setup.bat` saved to `cookie.txt`:

- `cookies (firefox)` - Firefox-family path configured and exists
- `cookies (chrome)` - bare browser name (Chrome, Edge, Brave, etc.)
- `no cookies configured` - cookie.txt is empty (age-restricted fails, public works)
- `cookie path missing: <path>` - saved path no longer exists, re-run `setup.bat -Reset`

The `bgutil` and `JS runtime` checks come from yt-dlp's own verbose output (`-v --simulate`), not from a TCP probe. If yt-dlp reports bgutil as available, bgutil **is** available, regardless of what a port scan might say. This is deliberate: the only consumer of bgutil is yt-dlp, so yt-dlp's view is authoritative.

The plugin verification step makes one YouTube request and takes 2-3 seconds. That is the only slow check. Total checkup time is typically under 4 seconds.

To skip the entire checkup:
run.bat "URL" -SkipCheckup

Use only after one clean checkup run confirmed everything works. If something breaks later, temporarily remove the flag from `run.bat` to re-check.


## Output layout
```text
<Downloads>\YouTube\
└── <Uploader Name>\
    ├── Video Title One [dQw4w9WgXcQ].mp4
    ├── Video Title Two [9bZkp7q19f0].mp4
    └── ...
```
The 11-character [id] at the end of every filename is load-bearing. It is the only thing the script trusts when deciding what is already downloaded. Never strip it. If you move files out of the folder, that's fine - but if you copy them back without the [id] suffix, the script will not recognize them and will re-download.

Audio mode writes .mp3 files with the same naming.

## How it works
A single run goes through five stages.

### 1. Enumerate
The script asks yt-dlp for the ID and title of every video:

```text
yt-dlp --cookies-from-browser <profile> --js-runtimes deno:<path> --flat-playlist --print "%(id)s" <url>
```
If the URL is a single video, it skips this and jumps to stage 3. If .txt, reads IDs out of the file.

Do not remove --flat-playlist from this line. Without it, yt-dlp re-extracts metadata for every video individually during enumeration - roughly 30x slower (minutes of silence for a 130-video channel) with no increase in the count. It does not fix "Found fewer than expected"; see Troubleshooting for that.

### 2. Diff against disk
Get-OnDiskIds scans the output folder for .mp4 and .mp3 files and extracts the [id] from each filename. Anything already on disk is removed from the fetch list.

```text
Channel: 132  On disk: 109  To fetch: 23
```
Channel - how many IDs yt-dlp returned.

On disk - how many of those already had a matching file.

To fetch - what is actually about to download.

If To fetch is 0 the script exits without downloading.

### 3. Split and spawn
The fetch list is divided round-robin into -Workers chunks. Each worker is a separate hidden PowerShell process running the script with -WorkerIndex N -Url chunk_N.txt.

### 4. Wait and poll
The master waits on all workers while polling the disk every 5 seconds. See Reading the progress display.

### 5. Verify
After every worker exits, the master rescans the disk one more time. For every ID that was supposed to download, it checks whether a file with that ID now exists.

If yes - counted as OK.

If no - written to FAILED.txt with a reason extracted from workerN.err, straight from yt-dlp's stderr.

```text
  This run - OK: 23  Failed: 0
  Verified on disk: 132/132
```
Both numbers are derived from disk state. yt-dlp's own "download complete" messages are ignored - only presence on disk counts.

## Reading the progress display
Workers run hidden. The main window prints a status line every 5 seconds:

```text
[04:46:28 +03:13] Worker1: 3/39  Worker2: 3/38  Worker3: 3/38 | Total 9/115 @ 168,5 MB/s
[04:51:12 +08:02] Worker1: 39/39 DONE  Worker2: 28/38  Worker3: 30/38 | Total 97/115 @ 142,1 MB/s
[04:46:28 +03:13] - wall clock time and elapsed since workers started.
```

Worker1: 3/39 - worker 1 has 3 of its 39 assigned files finished and confirmed on disk. Partial files are not counted. Worker numbers are 1-based in the display.

DONE instead of a fraction - that worker exited.

Total 9/115 @ 168,5 MB/s - 9 done out of 115; the @ value is the sum of each worker's recent average speed, i.e. roughly how fast the whole pipeline is going.

The decimal separator follows your locale - 168,5 on Turkish and many European systems, 168.5 on English systems. This is correct behavior; changing it would fight the OS.

A worker that shows 0/44 while others advance is stuck. See WHEN-BROKEN.txt Section D.

The polling interval is hardcoded at 5 seconds. Change Start-Sleep -Seconds 5 inside Invoke-Batch to adjust.

## Why the architecture looks like this
Several design decisions look unusual until you know the failure modes they prevent.

### Downloads folder: %USERPROFILE%\Downloads is a lie
%USERPROFILE%\Downloads is a string that expands literally. If Downloads has been redirected to another drive via Explorer → Properties → Location (common and supported), that string points to a folder that doesn't exist and nothing gets written there.

The real path is known to the shell, so the script queries it:

```powershell
(New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
```
This works regardless of redirection. Never replace it with %USERPROFILE%\Downloads - it silently loses the redirect.

### Enumeration-first, not top-level download
A single yt-dlp call on a channel URL is one operation. If 45 of 130 videos fail inside it, the failure surface is a single line of output. You cannot retry only the failures because you have no per-video URL for them.

The script enumerates first (--flat-playlist), then downloads each video by URL. Failures now produce per-video entries in FAILED.txt with real watch URLs you can retry individually.

Cost: ~1-2s of yt-dlp startup per video. For 130 videos, 2-4 minutes of added overhead. Worth it for the correctness.

### Why downloaded.txt is gone
Earlier versions used yt-dlp's --download-archive downloaded.txt to skip already-downloaded videos. It recorded "yt-dlp claims success" - not "file exists." Delete a file, its ID stays in the archive, and it never re-downloads.

Disk scan replaced it. The disk is the source of truth. Deleting a file is the reset command.

### Why [id] in the filename
Two functions:

Uniqueness. Two videos with the same sanitized title map to one filename under %(title)s.%(ext)s. --no-overwrites skips the second, but yt-dlp records both as downloaded. The result is a silent gap - archive larger than folder, nothing in the log. Adding [id] makes every filename unique.

Invertibility. A filename like Title [dQw4w9WgXcQ].mp4 can be mapped back to its video ID. Title.mp4 cannot.

Without [id] in the name, disk-based verification is impossible.

### Why --ignore-errors is only in the worker path
--ignore-errors tells yt-dlp "log failures but exit 0 anyway." In the worker path, that's what you want - a worker should keep processing its chunk when one video fails, not crash the run.

In the master, the same flag would mask failures: $LASTEXITCODE would always be 0. The master doesn't use exit codes at all - it verifies from disk. A failed download produces no file, so it shows up as missing.

###  Why bgutil is launched with `-WindowStyle Hidden` and redirected output
`bgutil-pot.exe` is written in Rust. On Windows, its logging runtime writes to a console handle during startup. When that handle is a hidden console with **no redirected output**, the writes fail and bgutil can hang before reaching the port-bind call. The process stays alive but never actually listens, so yt-dlp can't
talk to it. The fix is to give bgutil real file handles to write to. The script launches bgutil with `-WindowStyle Hidden` **and** `-RedirectStandardOutput bgutil.log -RedirectStandardError bgutil.log.err`. The window is invisible, but stdout and stderr are real files that bgutil can write to normally. bgutil starts cleanly, binds the port, and the logs sit in the script folder for diagnosis if anything goes wrong later.

**Do not remove the `-RedirectStandardOutput` / `-RedirectStandardError` flags.** Hidden alone can leave bgutil stuck before bind. Hidden **with** redirects works reliably. See `WHEN-BROKEN.txt` Section L.

## Cookies: extraction methods and their limits
The script pulls cookies via yt-dlp's --cookies-from-browser flag against a Firefox-family profile. That works on:

- Firefox

- Waterfox

- Librewolf

- Any other Firefox-derived browser (via the firefox: alias)

It does not work on modern Chromium browsers (Chrome, Edge, Brave, Chromium, Opera, Vivaldi). On Windows, these use App-Bound Encryption on their cookie database. The decryption key is bound to the browser's own process, and no external process - including yt-dlp - can decrypt the cookies.

Symptom with Chromium browsers:

```text
ERROR: Could not copy Chrome cookie database
```
or

```text
ERROR: Failed to decrypt with DPAPI
```
Neither error is a bug; both mean the same thing: browser extraction cannot read modern Chromium cookies on Windows.

### Fallback for Chromium browsers: cookies.txt
Export cookies from the browser as a Netscape-format cookies.txt (via a browser extension such as "Get cookies.txt LOCALLY"), then pass the file path to yt-dlp with --cookies cookies.txt instead of --cookies-from-browser. This bypasses encryption entirely - the export runs inside the browser, so it has the decryption key.

Tradeoff: manual. Must be re-exported whenever the session refreshes (typically every few weeks to a few months).

### Choosing a method
| Browser family | Recommended method |
| --- | --- |
| Firefox, Waterfox, Librewolf | --cookies-from-browser firefox:<path> (current default) |
| Chrome, Edge, Brave, Chromium, Opera, Vivaldi | cookies.txt file, manual export |
If you switch the script to cookies.txt, edit $BaseArgs to use '--cookies', '<path-to-cookies.txt>' in place of '--cookies-from-browser', $CookiesProfile.

## Age-restricted content: the three blockers
Age-gated YouTube content is protected by three independent layers. All three must be satisfied to download. Every one of them produces the same console error:

```text
ERROR: [youtube] XXXXX: Sign in to confirm your age.
```
Because they look identical, this is the single most confusing issue in yt-dlp troubleshooting. Knowing there are three layers is the difference between "it just doesn't work" and a five-minute fix.

### Blocker 1: Authentication
Requirement: a session from an account that has passed YouTube's age verification.

Fix: valid cookies. Either --cookies-from-browser <firefox-profile> (Firefox-family) or --cookies cookies.txt (manual export).

Check: run the cookie verification command in Diagnostic commands. It should print the uploader of a known video.

### Blocker 2: Proof-of-Origin (PO) token
Requirement: a PO token proving the request comes from a real browser session. Cookies alone do not satisfy this layer.

Fix: the bgutil-pot server must be running, and the bgutil yt-dlp plugin must be loaded. The script starts the server automatically; the plugin is a one-time installation (see PO token provider setup).

Check: the plugin check in Diagnostic commands should show bgutil:http as (external) without (unavailable).

### Blocker 3: JavaScript challenge
Requirement: yt-dlp must solve a JavaScript signature challenge before the age-gate page is even visible. Without a JS challenge solver, the age-gate stage never runs, so auth + PO tokens are irrelevant.

Fix: one of the following must be available to yt-dlp:

--js-runtimes deno:<path> (current default - uses the local deno.exe)

--js-runtimes node:<path> (if Node.js is installed)

--js-runtimes bun:<path> (if Bun is installed)

--remote-components ejs:github (fetches a solver from GitHub on demand, cached after first fetch)

The current script uses deno. Any of the four works.

Check: the plugin check in Diagnostic commands should show at least one JS Challenge Provider not marked (unavailable).

### Why this is hard to diagnose
All three failures surface as Sign in to confirm your age. Fixing one leaves the other two in place, so the error doesn't change. Confirm all three simultaneously before assuming a fourth cause exists:

Step 2 of WHEN-BROKEN.txt (cookies working?)

Step 1 of WHEN-BROKEN.txt (bgutil running AND plugin loaded?)

JSC provider visible in the plugin check?

If all three are green and the video still won't download, the account behind the cookies has not passed YouTube's age verification. Test the same URL manually in the browser whose cookies you use. If the browser also blocks it, no script can help.

## PO token provider (bgutil) setup
bgutil-pot is a local HTTP server that yt-dlp queries for PO tokens. Two pieces must be in place:

The server binary - bgutil-pot.exe, started by the script.

The yt-dlp plugin - Python files that teach yt-dlp how to talk to the server.

The server is started automatically. The plugin is a one-time install. Two traps:

### Trap 1: Plugin folder structure
The plugin files must sit at:

```powershell
yt-dlp-plugins\bgutil-ytdlp-pot-provider\yt_dlp_plugins\
```
Note yt_dlp_plugins - underscores, not hyphens. yt-dlp looks for this exact folder name. Extracting a release zip that produces bgutil-ytdlp-pot-provider-main\yt_dlp_plugins\ (double-nested with a -main suffix) will not work, and neither will having the .py files one level too high (e.g. yt-dlp-plugins\extractor\).

If the checkup reports "plugin folder missing" and hints at one of those two patterns, the fix is:

```powershell
New-Item -ItemType Directory .\yt-dlp-plugins\bgutil-ytdlp-pot-provider\yt_dlp_plugins -Force | Out-Null
Move-Item .\yt-dlp-plugins\extractor .\yt-dlp-plugins\bgutil-ytdlp-pot-provider\yt_dlp_plugins\extractor
```
### Trap 2: Executable name
The release ships bgutil-pot-windows-x86_64.exe. Rename it to bgutil-pot.exe. The script expects this exact name.

### Verify
Run the plugin check command in Diagnostic commands. Healthy output shows:

```text
[debug] [youtube] [pot] PO Token Providers: bgutil:http-0.8.1 (external)
```
If you see PO Token Providers: none or bgutil:http-0.8.1 (external, unavailable), the plugin didn't load - check the folder structure above.

## Debug mode
If enumeration is behaving strangely - "Found 130" one run and "Found 110" the next on the same URL - enable debug output:

```bat
run.bat "https://www.youtube.com/@ChannelURL/videos" -DebugEnum
```
Prints:

```text
DEBUG raw=132 matched=132 rejected=0
```
raw - lines yt-dlp printed.

matched - lines that passed the ID regex.

rejected - lines that didn't.

If raw is much higher than matched, the regex is dropping valid entries. The debug block also dumps the first 30 rejected lines with lengths and the hex bytes of the first one.

The debug block is wrapped in # === DEBUG START === / # === DEBUG END === markers and gated by if($DebugEnum){ ... }. No-op unless you pass the switch.

## Migration mode
You do not need this unless you have files downloaded by a previous version of this script.

Older versions used %(uploader)s\%(title)s.%(ext)s - no [id]. Those files are invisible to the disk scan and would be re-downloaded. -Migrate renames them in place:

```bat
run.bat "https://www.youtube.com/@ChannelName/videos" -Migrate
```
For each video on the channel:

Asks yt-dlp what filename it would use under the old template.

Looks for that file on disk (trying .mp4, .mkv, .webm, .mp3, .m4a, .opus, .ogg).

If found, renames to Title [id].ext in place.

Costs ~2-3 seconds per video (each requires a --get-filename call), so a 130-video channel takes 7-10 minutes. Not a download - just metadata fetching and a filesystem rename.

Summary line:

```text
Renamed: 128   skipped: 2   not found: 0
```
Renamed - moved to [id] naming.

skipped - already had [id], or was a title collision. Collisions reflect the bug this migration fixes: two videos with identical sanitized titles shared one file, so one was never actually on disk. That one downloads fresh on the next run.

not found - the video's title changed on YouTube since download; old-path guess missed. Those re-download normally too.

To skip migration: accept the one-time re-download, or move the old folder aside and let the script rebuild it.

## Files created in the script folder
| File | Lifetime | Purpose |
| --- | --- | --- |
| chunk_N.txt | Deleted after each run | Per-worker list of video URLs. |
| chunk_N_map.txt | Deleted after each run | Per-worker ID-to-title map used for verification. |
| workerN.log | Deleted after each run | Full yt-dlp output for that worker. |
| workerN.err | Deleted after each run | Extracted ERROR: lines, used for FAILED.txt reasons. |
| bgutil.log, bgutil.log.err | Persistent | bgutil's own stdout and stderr, for diagnosing startup failures. |
| FAILED.txt | Persistent, appended | One line per failed video: title \| url \| reason. |
| downloaded.txt | Legacy, ignored | From older versions. Not read or written. Safe to delete. |
| bgutil_ytdlp_pot_provider-windows-x86_64.dll | Unused, safe to delete | Leftover from a different bgutil build; not loaded by yt-dlp. |
FAILED.txt appends across runs. Clear it manually if you want a clean slate:

```powershell
Remove-Item .\FAILED.txt
```
A video that succeeded in a later run but is still listed from an earlier failure is expected - the file is a log, not a live status. Trust the Verified on disk: N/M line.

### Reset all state
Safe, idempotent, no data that isn't re-derivable:

```powershell
Remove-Item "$env:USERPROFILE\Downloads\YouTube" -Recurse -Force -EA SilentlyContinue
Remove-Item .\FAILED.txt -EA SilentlyContinue
Remove-Item .\chunk_*.txt -EA SilentlyContinue
Remove-Item .\worker*.log, .\worker*.err -EA SilentlyContinue
Remove-Item .\bgutil.log, .\bgutil.log.err -EA SilentlyContinue
Remove-Item .\downloaded.txt -EA SilentlyContinue
This deletes every downloaded file, failure log, temp chunk, worker log, bgutil log, and legacy archive. Does not touch the script, .bat, binaries, plugins, or anything outside the script folder and Downloads\YouTube.
```

## Diagnostic commands

Run these from a PowerShell window in the script folder.

### yt-dlp version
```powershell
.\yt-dlp.exe --version
```
Should be 2025.05.22 or newer for bgutil compatibility.

### Cookie extraction working
```powershell
.\yt-dlp.exe --cookies-from-browser "firefox:C:\Users\YOURNAME\AppData\Roaming\Waterfox\Profiles\PROFILE_ID" --print "%(uploader)s" "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```
Expected: Rick Astley. Anything else means cookies aren't being read.

### Plugin loading (PO token + JS challenge)
```powershell
.\yt-dlp.exe -v --simulate --no-warnings "https://youtu.be/2h2eQClFnWc" 2>&1 | Select-String "PO Token|JS Challenge"
```
Healthy output:

```text
[debug] [youtube] [pot] PO Token Providers: bgutil:http-0.8.1 (external)
[debug] [youtube] [jsc] JS Challenge Providers: bun (unavailable), deno, node (unavailable), quickjs (unavailable)
```
If PO Token Providers: none → plugin not loaded. See PO token provider setup.

If JS Challenge Providers all show (unavailable) → deno.exe not found. Check --js-runtimes deno:<path> in $BaseArgs.

This is the authoritative check for bgutil + JSC availability. It is what the startup checkup uses internally. A TCP port scan or Get-Process check is not authoritative because it can only tell you that a process is running, not whether yt-dlp can talk to it.

### Manual download bypassing the script
```powershell
.\yt-dlp.exe -v --cookies-from-browser "firefox:..." --js-runtimes "deno:$PWD\deno.exe" -o "test_%(title)s.%(ext)s" "https://youtu.be/2h2eQClFnWc"
```
If this fails, the script will also fail. Fix this command first - do not edit the script.

## Troubleshooting
For a step-by-step triage card, see WHEN-BROKEN.txt. Below are the most common issues with reference detail.

### "Found 110 videos" but the channel has 133
One of three things.

1. The /videos tab does not list Shorts or live streams. YouTube separates them: /videos, /shorts, /streams. If your count came from the channel home page, run against each tab:

```bat
run.bat "https://www.youtube.com/@ChannelName/videos"
run.bat "https://www.youtube.com/@ChannelName/shorts"
run.bat "https://www.youtube.com/@ChannelName/streams"
```
Same output folder; disk scan makes each run only fetch what the previous didn't.

2. A Turkish locale is breaking the ID regex. If Windows locale is tr-TR, PowerShell's -match is case-insensitive in a Turkish-specific way: capital I lowercases to ı (dotless), so [A-Za-z] fails to match capital I. Any video ID containing I is silently dropped.

Symptom: some IDs pass, some fail, and every rejected ID contains a capital I. Run -DebugEnum to confirm. Fix: use -cmatch / -cnotmatch instead of -match / -notmatch in every regex that parses video IDs (five places in the script). Current versions already use the case-sensitive operators - this only affects older copies or local edits.

3. yt-dlp is out of date. Update it:

```powershell
.\yt-dlp.exe -U
```
### "Found N videos. On disk: N. To fetch: 0." but files are missing
The disk scan only recognizes filenames ending with [11-char-id]. If you renamed, moved, or copied files without the [id] suffix, they are invisible. Rename to include the ID, or delete and re-download.

### Downloads stall, or workers freeze at 0%
Cookies expired. Open the browser, sign in, close completely, retry.

bgutil-pot not running. Check bgutil.log in the script folder.

Transient bot check. Kill the run, restart. Disk scan skips what finished.

### "Verified on disk" short of expected count
Every missing ID is in FAILED.txt with a reason. Common:

"Video unavailable" - deleted, private, region-blocked. Cannot download.

"Requires payment" - members-only; cookies lack access.

"Sign in to confirm you're not a bot" - refresh cookies, ensure bgutil running, retry.

"HTTP 403 Forbidden" - usually transient; retry.

### Only 360p downloaded, but channel has 4K
The script requests bv*+ba/b (yt-dlp's "best"). If files on disk are low-res, they were downloaded by an earlier run - resolution isn't in the filename, so the disk scan doesn't know. Delete them and re-download.

Confirm the channel really has 4K:

```powershell
.\yt-dlp.exe -F "https://www.youtube.com/watch?v=VIDEO_ID"
```
### Age-restricted video won't download
See Age-restricted content: the three blockers. All three must be satisfied.

### .bat exits immediately with an error
Open a PowerShell window in the script folder and run the .ps1 directly:

```powershell
.\yt-downloader.ps1
```
That shows the full error. Common causes: missing binary (yt-dlp.exe or deno.exe not in the folder), or execution policy if you bypass the .bat.

### Script won't parse - "Unexpected token" errors
The .ps1 file is saved as UTF-8 without BOM and contains non-ASCII characters (em dashes, curly quotes, box-drawing characters). Windows PowerShell 5.1 reads .ps1 files as ANSI unless they have a UTF-8 BOM, so any byte above 127 gets corrupted and breaks the parse.

Two fixes:

Save as UTF-8 with BOM. In Notepad3: File → Encoding → "UTF-8 with Signature". In Notepad: File → Save As → Encoding → "UTF-8 with BOM".

Or stick to ASCII. Replace any non-ASCII character in the script with its ASCII equivalent (- instead of —, -> instead of →, " instead of " or ", ' instead of ' or ').

Option 2 is more portable - the script works regardless of which editor saved it next.

## Known limitations
Windows-only. Uses Start-Process -WindowStyle Minimized, the Shell.Application COM object, and the firefox: cookie prefix as a Waterfox path. A Linux or macOS port would need adjustments.

.mp4 and .mp3 only in the disk scan. Get-OnDiskIds recognizes .mp4 and .mp3. With --merge-output-format mp4 almost every video lands as .mp4, but edge cases (no separate audio stream, so yt-dlp produces a single .webm) aren't counted and re-download each run. To widen:

```powershell
Where-Object { $_.Extension -in '.mp4','.mkv','.webm','.mp3','.m4a','.opus' -and $_.Length -gt 0 }
```
Intermediates like Title [id].f137.mp4 are still excluded because the ID must be last in the basename.

Cookies profile is a hardcoded path. If the browser profile folder changes (update, reset, new user), the script fails silently - cookies aren't loaded, and age-restricted videos disappear from enumeration. Update $CookiesProfile when that happens. See Configuration.

Chromium browsers cannot be read via browser extraction. DPAPI/App-Bound Encryption blocks external cookie access. Use cookies.txt instead if the browser is Chrome/Edge/Brave/Chromium/Opera/Vivaldi. See Cookies: extraction methods and their limits.

- **bgutil must be launched with `-RedirectStandardOutput` / `-RedirectStandardError`.** A hidden console with no redirected output can leave bgutil stuck before it binds port 4416. See [Why the architecture looks like this](#why-the-architecture-looks-like-this).

Migration only handles the old default template. Custom -o templates from older versions cannot be migrated. Re-download those.

No resume across worker restarts. A worker crash mid-video leaves a partial .part file. The next run resumes it (--continue), but the file isn't usable until complete.

Age-restricted content depends on a properly age-verified account. The three-blocker framework is documented based on how yt-dlp behaves, but if the account behind the cookies is not age-verified with Google, no amount of script configuration fixes it. Test with a known-gated video before assuming the pipeline works.

Enumeration order determines worker assignment. Round-robin across the enumerated list. Small channels see balanced workers; large channels with many removed videos may see imbalance because removed entries still count toward the split.

## Editing the script safely
Two rules that prevent most self-inflicted breakage.

**First, save the file as UTF-8 with BOM before editing.** Windows PowerShell 5.1 assumes ANSI for `.ps1` files unless they have a UTF-8 BOM. A file saved as plain UTF-8 that contains even one em dash, curly quote, or arrow will fail to parse with confusing "Missing closing '}'" errors on unrelated lines. In Notepad3: File → Encoding → "UTF-8 with Signature". In Notepad: File → Save As → Encoding → "UTF-8 with BOM". In VS Code: bottom-right encoding → "Save with Encoding" → "UTF-8 with BOM". Do this once per file and the problem never comes back.

1. Regex that parses video IDs must use -cmatch / -cnotmatch
-match in PowerShell is case-insensitive by default. Under Turkish culture (tr-TR), that means [A-Za-z] fails to match capital I - because Turkish lowercases I to ı (dotless) instead of i.

Symptom: some video IDs silently disappear from enumeration, and every rejected ID contains a capital I.

Five places in the current script use -cmatch/-cnotmatch on purpose:

Get-OnDiskIds - filename regex

Invoke-Batch, .txt branch - URL regex

Invoke-Batch, enumeration foreach - ID regex

Invoke-Batch, -DebugEnum block - ID regex

Worker branch, ERROR: parser

Any new regex added elsewhere that parses YouTube video IDs must follow the same rule.

2. .ps1 file must be ASCII or UTF-8-with-BOM
See Script won't parse in Troubleshooting. Simplest rule: don't put non-ASCII characters in the script. If you must, save as UTF-8 with Signature in Notepad3.

Built around yt-dlp. All download logic, format selection, cookie handling, and site compatibility come from yt-dlp; this script only orchestrates parallel runs, tracks disk state, and reports progress.
