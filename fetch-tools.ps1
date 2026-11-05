# ============================================================
# BEWARE
# ============================================================
# The download URLs below are snapshots. Upstream projects move,
# rename, or delete their release assets over time. If any
# download in this script 404s:
#
#   1. Open REQUIREMENTS.txt — it links the current release pages.
#   2. Download manually from those pages.
#   3. Place the file in the right folder (see layout in REQUIREMENTS).
#
# This script is a convenience, not a guarantee. It works today.
# It may not work next month. That is the nature of third-party
# release URLs.
# ============================================================

$ErrorActionPreference='Stop'
$Dir = $PSScriptRoot

$tools = @(
    @{
        Name = 'yt-dlp.exe'
        Url  = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
    },
    @{
        Name = 'deno.exe'
        Url  = 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip'
        Unzip = $true
        UnzipExe = 'deno.exe'
    },
    @{
        Name = 'ffmpeg.exe'
        Url  = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
        Unzip = $true
        UnzipExe = 'ffmpeg.exe'
    },
    @{
        Name = 'bgutil-pot.exe'
        Url  = 'https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/latest/download/bgutil-pot-windows-x86_64.exe'
    }
)

foreach($t in $tools){
    $dest = Join-Path $Dir $t.Name
    if(Test-Path $dest){ Write-Host "Already present: $($t.Name)" -Fore Green; continue }
    Write-Host "Downloading $($t.Name) ..." -Fore Cyan
    try {
        if($t.Unzip){
            $zip = Join-Path $env:TEMP "$($t.Name).zip"
            Invoke-WebRequest -Uri $t.Url -OutFile $zip -UseBasicParsing
            $tmp = Join-Path $env:TEMP "unzip-$($t.Name)"
            Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $found = Get-ChildItem $tmp -Recurse -Filter $t.UnzipExe | Select-Object -First 1
            if($found){ Copy-Item $found.FullName $dest -Force }
            Remove-Item $tmp,$zip -Recurse -Force -EA SilentlyContinue
        } else {
            Invoke-WebRequest -Uri $t.Url -OutFile $dest -UseBasicParsing
        }
        Write-Host "  ok: $($t.Name)" -Fore Green
    } catch {
        Write-Host "  FAILED: $($t.Name) -- $($_.Exception.Message)" -Fore Red
    }
}

# bgutil plugin (small, could also be committed to the repo)
$pluginDir = Join-Path $Dir 'yt-dlp-plugins\bgutil-ytdlp-pot-provider\yt_dlp_plugins\extractor'
if(-not (Test-Path $pluginDir)){
    Write-Host "Downloading bgutil plugin ..." -Fore Cyan
    $zip = Join-Path $env:TEMP 'bgutil-plugin.zip'
    Invoke-WebRequest -Uri 'https://github.com/Brainicism/bgutil-ytdlp-pot-provider/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing
    $tmp = Join-Path $env:TEMP 'bgutil-plugin'
    Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem $tmp -Recurse -Directory -Filter 'yt_dlp_plugins' | Select-Object -First 1
    if($src){
        New-Item -ItemType Directory (Split-Path $pluginDir -Parent) -Force | Out-Null
        Copy-Item $src.FullName (Split-Path $pluginDir -Parent) -Recurse -Force
    }
    Remove-Item $tmp,$zip -Recurse -Force -EA SilentlyContinue
}

Write-Host ""
Write-Host "Done. Run setup.bat next." -Fore Green