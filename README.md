# yt-triopus

Three arms, one goal: pull everything, verify it landed, never lose a file.

A Windows-only PowerShell 5.1 wrapper around `yt-dlp`. Downloads YouTube
channels and playlists with three parallel workers, tracks state by scanning
the disk (never trusts an archive file), and verifies after every run that
every requested ID actually landed. Built for people burned by wrappers that
say "done" while silently dropping videos.

For triage when something looks wrong, see `WHEN-BROKEN.txt` in the same
folder.

## Why this app

There are dozens of `yt-dlp` wrappers. Most download one video at a time,
trust an archive file that drifts out of sync with the disk, and stop working
the moment an age-gate or bot check appears. This one was built around three
things they don't do.

### 1. THREE WORKERS PULL SIMULTANEOUSLY

Most wrappers, even good ones, feed videos to yt-dlp one at a time. Wall-clock
time for a 130-video channel is the sum of every video's download time. Three
workers means three videos are downloading in parallel -- total time is roughly
`total / 3`, as long as the network isn't the bottleneck (three 4K streams
saturate most home connections before the CPU does). The progress display shows
each worker
separately, so you can see all three streams moving at once:

    [14:32:21 +00:15] Worker1: 2/44 Worker2: 1/44 Worker3: 2/44 | Total 5/132 @ 105,2 MB/s

Each worker is an independent process with its own yt-dlp child, its own
`-N` fragment parallelism inside each video, and its own slice of the
channel. When one stalls on a throttled URL, the other two keep downloading.
It has never been clear why this is rare in YouTube downloaders -- it's the
single biggest speed win available, and it costs nothing but one more
`Start-Process`.

### 2. REACHES ANYTHING YT-DLP CAN REACH

`yt-dlp` (per its own README) supports over 1,800 sites -- YouTube, Vimeo,
Twitch, Twitter, SoundCloud, and most of the browser-viewable web. This
wrapper inherits all of it. Any
content you can watch in a browser (no DRM, no paywall you haven't got cookies
for), `yt-triopus` can download.

The age-restricted content tooling -- bgutil PO tokens, deno JS challenge
solver, cookie extraction -- is tuned for YouTube, because that's where the
strongest anti-download defenses are. On other sites most of that machinery is
inert and yt-dlp just works. The three-worker parallelism applies everywhere.

### 3. NO SILENT LOSSES

The most common complaint about other wrappers is some variant of: "I told
it to download 130 videos, it said 130 succeeded, but my folder has 110."

Most wrappers use yt-dlp's `--download-archive` to track what's been
downloaded. That archive records what yt-dlp claimed succeeded, not what's
actually on disk. The two drift apart silently:

- Delete a file, its ID stays in the archive forever. It never re-downloads.
- Two videos with the same sanitized title map to one filename. The second is
  skipped by `--no-overwrites`, but yt-dlp records both as downloaded.
- yt-dlp says "success" and exits 0 even when the merge failed and no final
  file exists.

What this app does instead:

- Every filename ends with `[11-char-video-id]`. Two videos with the same
  title can't collide. Any file on disk can be mapped back to its ID.
- The disk is the source of truth. Every run scans the output folder and diffs
  it against yt-dlp's enumeration. Delete a file -- next run fetches it. No
  archive file, no stale state.
- Verification after every run. Workers claim success; the master rescans the
  disk and confirms every requested ID actually landed. Failures go into
  `FAILED.txt` with the yt-dlp error message.

The result: `Verified on disk: 132/132` means 132 files are literally in your
folder. Not 132 IDs in a text file. Not 132 "success" messages. 132 files.

State is tracked by scanning the disk for files ending in `[11-char-id]`, not
by an archive file. Delete a file, next run fetches it. See
`ARCHITECTURE.md` for why.

## Quick start

1. Create a folder, e.g. `C:\Tools\yt-downloader\`.
2. Place `yt-downloader.ps1`, `run.bat`, `setup.bat`, `cookies.ps1`, and the
   binaries (`yt-dlp.exe`, `deno.exe`, `bgutil-pot.exe`, optional
   `ffmpeg.exe`) into it. Or run `fetch-tools.ps1` to download the binaries.
3. Extract the bgutil plugin under
   `yt-dlp-plugins\bgutil-ytdlp-pot-provider\yt_dlp_plugins\` (see
   `REQUIREMENTS.txt`).
4. Run `setup.bat` once to configure cookies.
5. Double-click `run.bat`, paste a URL, press Enter.

No installation, no PATH changes, no admin rights. The script uses
`$PSScriptRoot` to find its own folder, so it works from anywhere.

## Requirements

- Windows 10 or 11 with the built-in Windows PowerShell 5.1 (no PowerShell 7).
- `yt-dlp.exe` (searched in script folder, parent folder, then PATH).
- `deno.exe` next to the script (JS challenge solver).
- `bgutil-pot.exe` next to the script (PO tokens; recommended).
- `ffmpeg.exe` optional; if absent, the script uses whatever is on PATH.
  Required for video+audio merging.
- The bgutil yt-dlp plugin under `yt-dlp-plugins\...` (see `REQUIREMENTS.txt`).
- A Firefox-family browser profile with a YouTube login, for age-restricted or
  members-only content.
- Disk space -- 4K video adds up fast.

## Folder layout

    <anywhere>\
    +-- yt-dlp.exe                    <- shared, may live in a common tools dir
    +-- ffmpeg.exe                    <- optional, alongside yt-dlp.exe
    +-- yt-downloader\                <- everything else, app-specific
        +-- yt-downloader.ps1
        +-- run.bat
        +-- setup.bat
        +-- cookies.ps1
        +-- README.md
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

Only `yt-dlp.exe` is flexible in location. Everything else must sit inside
`yt-downloader\`, next to the `.ps1` and `.bat` files.

## Usage

Parameters:

| Parameter | Type | Default | Meaning |
| --- | --- | --- | --- |
| `-Url` | string | (prompt) | Channel, playlist, video URL, or path to a `.txt` file of URLs. |
| `-Mode` | video \| audio | video | `video` = bv*+ba/b merged to `.mp4`. `audio` = ba/b transcoded to `.mp3`. |
| `-Workers` | int | 1 | Number of parallel yt-dlp processes. |
| `-Fragments` | int | 8 | Passed to yt-dlp as `-N`. |
| `-WorkerIndex` | int | -1 | Internal. Set by the master. Do not pass manually. |
| `-Migrate` | switch | off | One-time rename pass for files from the old `%(title)s.%(ext)s` template. |
| `-DebugEnum` | switch | off | Prints enumeration internals. |
| `-SkipCheckup` | switch | off | Skip the startup environment check. |

`run.bat` bakes in `-Workers 3 -Fragments 4`; override by passing the flags
again. `run.bat` refuses to start if `cookie.txt` is missing.

Examples:

Download a channel at best quality, 4 workers:

    run.bat "https://www.youtube.com/@ChannelName/videos" -Workers 4

Audio only:

    run.bat "https://www.youtube.com/@ChannelName/videos" -Mode audio

Single video or a batch file of URLs:

    run.bat "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    run.bat "C:\Users\You\list.txt"

Quote URLs containing `&`. Re-running the same command later fetches only new
uploads and anything you deleted from the folder.

## How it works

A single run goes through five stages.

1. Enumerate. Ask yt-dlp for the ID of every video (`--flat-playlist --print "%(id)s"`). A single video skips this; a `.txt` file supplies IDs directly.
2. Diff against disk. Scan the output folder for `[id]` in filenames; drop anything already on disk. Print `Channel: N  On disk: M  To fetch: K`. If `K` is 0, exit.
3. Split and spawn. Divide the fetch list round-robin across `-Workers` hidden PowerShell processes.
4. Wait and poll. Master waits on workers, polling the disk every 5 seconds for per-worker progress.
5. Verify. Rescan the disk. Every requested ID must now exist; missing ones go to `FAILED.txt` with the yt-dlp error. Print `Verified on disk: N/M`.

Do not remove `--flat-playlist` from enumeration. Removing it makes enumeration
silent for minutes and does not increase the count.

## Documentation map

- `WHEN-BROKEN.txt` -- step-by-step triage card. Open first when something
  looks wrong.
- `REQUIREMENTS.txt` -- external binaries, SHA256 hashes, license notes, folder
  layout.
- `ARCHITECTURE.md` -- why the non-obvious design decisions exist.
- `LICENSE` -- GPLv3.

## Known limitations

- Windows-only.
- Disk scan recognizes `.mp4` and `.mp3` only. Rare `.webm`/`.mkv` outputs
  are re-downloaded each run. See `ARCHITECTURE.md` / `WHEN-BROKEN.txt` to widen.
- Cookie profile is a single hardcoded path in `$CookiesProfile`; update it if
  the browser profile folder changes.
- Chromium browsers (Chrome, Edge, Brave, ...) cannot be read via browser
  extraction on Windows (App-Bound Encryption). Use a `cookies.txt` export.
- `bgutil-pot` must be launched with `-WindowStyle Hidden` plus
  `-RedirectStandardOutput`/`-RedirectStandardError`. Hidden alone can hang.
- Migration (`-Migrate`) only handles the old default template.
- No resume across worker restarts; a crash leaves a partial `.part` file that
  `--continue` resumes next run.
- Age-restricted content needs a properly age-verified Google account behind
  the cookies. The script cannot fix an unverified account.
- Enumeration order determines worker assignment; large channels with many
  already-downloaded videos may see imbalance.
- Quality is not encoded in the filename, so a stale low-res file is not
  re-fetched automatically.

## License

GPLv3. See `LICENSE`.
