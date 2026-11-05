# Architecture notes (yt-triopus)

Why the non-obvious design decisions exist. Each entry below is backed by
`yt-downloader.ps1`. Nothing here is a feature list; see `README.md` for that.

## Downloads folder: %USERPROFILE%\Downloads is a lie

`%USERPROFILE%\Downloads` is a literal string. If Downloads has been redirected
to another drive via Explorer -> Properties -> Location (common and supported),
that string points to a folder that doesn't exist and nothing gets written.

The real path is known to the shell, so the script queries it:

    (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path

This works regardless of redirection. Do not replace it with
`%USERPROFILE%\Downloads` -- it silently loses the redirect.

## Enumeration-first, not top-level download

A single yt-dlp call on a channel URL is one operation. If 45 of 130 videos
fail inside it, the failure surface is a single line of output, and you have
no per-video URL to retry.

The script enumerates first (`--flat-playlist`), then downloads each video by
URL. Failures now produce per-video entries in `FAILED.txt` with real watch
URLs you can retry individually.

Cost: roughly 1-2s of yt-dlp startup per video. For 130 videos, 2-4 minutes
of added overhead. Worth it for the correctness.

`--flat-playlist` stays in enumeration. Removing it makes yt-dlp re-extract
metadata for every video during enumeration -- roughly 30x slower (minutes of
silence for a 130-video channel) with no increase in the count. It does not
fix "Found fewer than expected."

## [id] in the filename

Two functions:

Uniqueness. Two videos with the same sanitized title map to one filename under
`%(title)s.%(ext)s`. `--no-overwrites` skips the second, but yt-dlp records
both as downloaded -- a silent gap, archive larger than folder, nothing in the
log. Adding `[id]` makes every filename unique.

Invertibility. A filename like `Title [dQw4w9WgXcQ].mp4` can be mapped back to
its video ID. `Title.mp4` cannot.

Without `[id]` in the name, disk-based verification is impossible. The disk
scan (`Get-OnDiskIds`) matches `\[([A-Za-z0-9_-]{11})\]$` against each
basename.

## Why no --download-archive

Earlier versions used yt-dlp's `--download-archive downloaded.txt` to skip
already-downloaded videos. It recorded "yt-dlp claims success", not "file
exists". Delete a file, its ID stays in the archive, and it never
re-downloads.

Disk scan replaced it. The disk is the source of truth. Deleting a file is the
reset command. `downloaded.txt` is legacy and ignored by the current script.

## Three age-gate blockers

Age-gated YouTube content is protected by three independent layers. All three
must be satisfied to download, and every one produces the same console error:

    ERROR: [youtube] XXXXX: Sign in to confirm your age.

1. Authentication. A session from an account that has passed YouTube's age
   verification. Fix: valid cookies (`--cookies-from-browser <profile>` for
   Firefox-family, or `--cookies cookies.txt` for manual export).
2. Proof-of-Origin (PO) token. Cookies alone do not satisfy this layer.
   Fix: bgutil-pot server running plus the bgutil yt-dlp plugin loaded.
3. JavaScript challenge. yt-dlp must solve a JS signature challenge before
   the age-gate page is even visible. Fix: a JS runtime available to yt-dlp
   (`--js-runtimes deno:<path>` by default; node/bun also work).

Fixing one leaves the other two in place, so the error does not change. Confirm
all three simultaneously. See `WHEN-BROKEN.txt` Section I.

`--remote-components ejs:github` fetches solver scripts from GitHub; it is not
a standalone replacement for a JS runtime.

## bgutil launched with -WindowStyle Hidden + redirects

`bgutil-pot.exe` is a Rust binary. On Windows its logging runtime writes to a
console handle during startup. When that handle is a hidden console with no
redirected output, the writes fail and bgutil can hang before reaching the
port-bind call -- the process stays alive but never listens.

The fix is to give bgutil real file handles. The script launches it with
`-WindowStyle Hidden` and `-RedirectStandardOutput bgutil.log
-RedirectStandardError bgutil.log.err`. The window is invisible, but stdout and
stderr are real files bgutil can write to normally.

Do not remove the `-RedirectStandardOutput` / `-RedirectStandardError` flags.
Hidden alone can leave bgutil stuck before bind. Hidden with redirects works
reliably. See `WHEN-BROKEN.txt` Section L.

## Worker-scoped --ignore-errors vs master verification-from-disk

`--ignore-errors` tells yt-dlp "log failures but exit 0 anyway."

In the worker path that is what you want -- a worker keeps processing its chunk
when one video fails instead of crashing the run.

In the master the same flag would mask failures (`$LASTEXITCODE` always 0). The
master does not use exit codes at all -- it verifies from disk. A failed
download produces no file, so it shows up as missing. This split is deliberate:
workers tolerate per-video failure; the master never trusts a process exit code.

## Case-sensitive -cmatch for ID parsing (Turkish locale)

PowerShell's `-match` is case-insensitive by default. Under Turkish culture
(tr-TR), `[A-Za-z]` fails to match capital `I`, because Turkish lowercases
`I` to dotless `i` (U+0131). Any video ID containing capital `I` is silently
dropped.

All regexes that parse YouTube video IDs use `-cmatch` / `-cnotmatch` instead.
Safe in every locale; no downside elsewhere. Five sites in the script:
`Get-OnDiskIds`, the `.txt` branch URL regex, the enumeration foreach, the
`-DebugEnum` block, and the worker `ERROR:` parser.

## What must never change

Carried over from hard-won debugging; do not regress these:

- `--flat-playlist` stays in enumeration.
- ID regex must use `-cmatch` / `-cnotmatch`.
- bgutil launched with `-WindowStyle Hidden` AND `-RedirectStandardOutput` /
  `-RedirectStandardError`.
- Enumeration prints only `--print "%(id)s"` (no title; empty titles ate IDs).
- `yt-dlp.exe` searched in three places: script folder, parent folder, PATH.
- `cookie.txt` format: `firefox:<path>` OR bare browser name OR empty string.
- `setup.bat -Reset` forces re-prompt; `-Show` prints current config.
- `run.bat` refuses to start if `cookie.txt` is missing.
- Do not use `--cookies-from-browser` with Chromium browsers on Windows
  (App-Bound Encryption, hard wall).
- Do not trust `downloaded.txt` (legacy, ignored by current script).
