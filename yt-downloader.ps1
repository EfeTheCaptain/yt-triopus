param(
    [string]$Url,
    [ValidateSet('video','audio')][string]$Mode='video',
    [int]$Workers=1,
    [int]$Fragments=8,
    [int]$WorkerIndex=-1,
    [switch]$Migrate,
    [switch]$DebugEnum,
    [switch]$SkipCheckup
)

$ErrorActionPreference='Continue'
$Dir=$PSScriptRoot
$YtDlp=$null
foreach($cand in @(
    (Join-Path $Dir 'yt-dlp.exe'),
    (Join-Path (Split-Path $Dir -Parent) 'yt-dlp.exe')
)){
    if(Test-Path $cand){ $YtDlp=$cand; break }
}
if(-not $YtDlp){
    $cmd = Get-Command yt-dlp.exe -EA SilentlyContinue
    if($cmd){ $YtDlp = $cmd.Source }
}
if(-not $YtDlp){ $YtDlp = Join-Path $Dir 'yt-dlp.exe' }  # fallback for error messages
$Deno="$Dir\deno.exe"
$Bgutil="$Dir\bgutil-pot.exe"
$MasterFailed="$Dir\FAILED.txt"

$CfgFile="$Dir\cookie.txt"
$CookiesProfile = ''
if(Test-Path $CfgFile){
    $line = Get-Content $CfgFile -EA SilentlyContinue | Where-Object { $_ -and $_ -notmatch '^\s*#' } | Select-Object -First 1
    if($line){ $CookiesProfile = $line.Trim() }
}

try{$dl=(New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path}catch{$dl="$env:USERPROFILE\Downloads"}
$OutDir=Join-Path $dl 'YouTube'
$Tmpl="$OutDir\%(uploader)s\%(title)s [%(id)s].%(ext)s"
if(-not(Test-Path $OutDir)){New-Item -ItemType Directory $OutDir -Force|Out-Null}

$BaseArgs=@(
    '--plugin-dirs', (Join-Path $Dir 'yt-dlp-plugins'),
    '--js-runtimes',"deno:$Deno",
    '--retries','5','--retry-sleep','10',
    '--sleep-requests','1','--sleep-interval','1',
    '--throttled-rate','100K',
    '-N',$Fragments,
    '--embed-thumbnail','--embed-metadata',
    '--newline','--progress',
    '-o',$Tmpl
)
if($CookiesProfile){ $BaseArgs = @('--cookies-from-browser',$CookiesProfile) + $BaseArgs }
if($Mode-eq'audio'){$Fmt=@('-f','ba/b','-x','--audio-format','mp3')}else{$Fmt=@('-f','bv*+ba/b','--merge-output-format','mp4')}

function Write-Utf8NoBom($Path,$Lines){
    [IO.File]::WriteAllLines($Path,[string[]]$Lines,(New-Object Text.UTF8Encoding $false))
}

function Get-OnDiskIds {
    $ids=@{}
    Get-ChildItem $OutDir -Recurse -File -EA SilentlyContinue |
        Where-Object { $_.Extension -in '.mp4','.mp3' -and $_.Length -gt 0 } |
        ForEach-Object { if($_.BaseName -cmatch '\[([A-Za-z0-9_-]{11})\]$'){ $ids[$matches[1]]=$true } }
    $ids
}

function Test-Environment {
    $issues=@(); $warnings=@(); $oks=@()

    # 1. Binaries
    foreach($b in @(
        @{N='yt-dlp.exe';     P=$YtDlp},
        @{N='deno.exe';       P=$Deno},
        @{N='bgutil-pot.exe'; P=$Bgutil}
    )){
        if(Test-Path $b.P){
            $label = $b.N
            if($b.N -eq 'yt-dlp.exe' -and $b.P -ne (Join-Path $Dir 'yt-dlp.exe')){
                $label = "$($b.N) ($(if($b.P -like "$(Split-Path $Dir -Parent)*"){'parent'}else{'PATH'}))"
            }
            $oks += $label
        } else {
            $issues += "missing $($b.N) at $($b.P)"
        }
    }

    # 2. ffmpeg (script folder OR PATH)
    $ffLocal = Join-Path $Dir 'ffmpeg.exe'
    $ffPath  = (Get-Command ffmpeg -EA SilentlyContinue).Source
    if(Test-Path $ffLocal){ $oks += 'ffmpeg (local)' }
    elseif($ffPath){ $oks += 'ffmpeg (PATH)' }
    else{ $warnings += 'ffmpeg not found — video+audio merging will fail' }

    # 3. Plugin folder
    $pluginDir = Join-Path $Dir 'yt-dlp-plugins\bgutil-ytdlp-pot-provider\yt_dlp_plugins'
    if(-not (Test-Path $pluginDir)){
        $issues += "plugin folder missing: $pluginDir"
        if(Test-Path (Join-Path $Dir 'yt-dlp-plugins\extractor')){
            $issues += "  (found yt-dlp-plugins\extractor\ — needs bgutil-ytdlp-pot-provider\yt_dlp_plugins\ wrapper)"
        }
        if(Test-Path (Join-Path $Dir 'yt-dlp-plugins\yt_dlp_plugins')){
            $issues += "  (found yt-dlp-plugins\yt_dlp_plugins\ — needs bgutil-ytdlp-pot-provider\ wrapper)"
        }
    } else {
        $py = @(Get-ChildItem $pluginDir -Recurse -Filter '*.py' -EA SilentlyContinue)
        if($py.Count -gt 0){ $oks += "plugin folder ($($py.Count) .py files)" }
        else{ $issues += "no .py files under $pluginDir" }
    }

    # 4. Cookie profile
    if(-not $CookiesProfile){
        $warnings += "no cookies configured (delete cookie.txt to re-prompt)"
    } elseif($CookiesProfile -cmatch '^[a-z]+:'){
        $p = $CookiesProfile -replace '^[a-z]+:',''
        if(Test-Path $p){ $oks += "cookies ($($CookiesProfile.Split(':')[0]))" }
        else{ $warnings += "cookie path missing: $p" }
    } else {
        $oks += "cookies ($CookiesProfile)"
    }

    # 5. bgutil + plugin verification via yt-dlp's own view (authoritative)
    if((Test-Path $pluginDir) -and (Test-Path $YtDlp)){
        $job = Start-Job -ScriptBlock {
            param($yt, $deno, $plugins, $url)
            & $yt -v --simulate --no-warnings --js-runtimes "deno:$deno" --plugin-dirs $plugins $url 2>&1 | Out-String
        } -ArgumentList $YtDlp, $Deno, (Join-Path $Dir 'yt-dlp-plugins'), "https://youtu.be/MflFVJ6TRII"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $done = $false
        while($sw.Elapsed.TotalSeconds -lt 15){
            if(Get-Job -Id $job.Id -EA SilentlyContinue | Where-Object { $_.State -ne 'Running' }){
                $done = $true
                break
            }
            $remaining = [Math]::Ceiling(15 - $sw.Elapsed.TotalSeconds)
            Write-Host ("`r  ... verifying plugin ({0}s remaining)  " -f $remaining) -NoNewline -Fore DarkGray
            Start-Sleep -Milliseconds 500
        }
        Write-Host "`r                                                  `r" -NoNewline

        if($done){
            $co = Receive-Job $job
            Remove-Job $job -Force -EA SilentlyContinue

            if($co -match 'PO Token Providers:[^\r\n]*bgutil:http' -and $co -notmatch 'bgutil:http.*unavailable'){
                $oks += 'bgutil (PO token via HTTP)'
            } else {
                $warnings += 'bgutil:http not seen by yt-dlp - age-restricted may fail'
            }
            $jsc = ($co -split "`n" | Where-Object { $_ -match 'JS Challenge Providers' } | Select-Object -First 1)
            if($jsc -and $jsc -notmatch 'deno \(unavailable\)'){
                $oks += 'JS runtime (deno)'
            } else {
                $warnings += 'deno not seen by yt-dlp - age-gate may fail'
            }
        } else {
            Stop-Job $job -EA SilentlyContinue
            Remove-Job $job -Force -EA SilentlyContinue
            $warnings += 'plugin verification timed out (15s) - bgutil may be slow'
        }
    }

    # Report
    Write-Host "=== Checkup ===" -Fore Magenta
    foreach($o in $oks){ Write-Host "  + $o" -Fore Green }
    foreach($w in $warnings){ Write-Host "  ! $w" -Fore Yellow }
    foreach($i in $issues){ Write-Host "  X $i" -Fore Red }
    Write-Host ""

    return ($issues.Count -eq 0)
}

function Download-One($VideoUrl,$Title){
    $a=$BaseArgs+$Fmt+@('--continue','--no-overwrites')
    if($VideoUrl-match'watch\?v=|youtu\.be/'){$a+='--no-playlist'}
    $a+=$VideoUrl
    Write-Host ">> $Title" -Fore Cyan
    $out=& $YtDlp @a 2>&1
    $out|ForEach-Object{Write-Host $_}
    if($LASTEXITCODE-ne0){
        $r=($out|Select-String 'ERROR:'|Select-Object -Last 1).Line
        if(-not $r){$r="exit code $LASTEXITCODE"}
        Write-Host "FAIL $Title" -Fore Red
        "$Title | $VideoUrl | $r"|Add-Content $MasterFailed
        return
    }
    Write-Host "OK   $Title" -Fore Green
}

function Migrate-OldFiles {
    param([string]$ChannelUrl)
    $migArgs=@(
        '--cookies-from-browser',$CookiesProfile,
        '--js-runtimes',"deno:$Deno",
        '--get-filename','--no-warnings','--no-playlist',
        '-o','%(uploader)s\%(title)s.%(ext)s'
    )
    Write-Host "Enumerating $ChannelUrl ..." -Fore Cyan
    $raw=& $YtDlp @BaseArgs --flat-playlist --playlist-end 100000 --print "%(id)s" $ChannelUrl 2>$null
    $ids=@($raw|Where-Object{$_-cmatch'^[A-Za-z0-9_-]{11}$'})
    Write-Host "Found $($ids.Count) IDs. Migrating..." -Fore Cyan
    $renamed=0;$skipped=0;$notfound=0;$i=0
    foreach($id in $ids){
        $i++
        if(($i % 25) -eq 0){Write-Host "  $i / $($ids.Count)  renamed=$renamed  nf=$notfound" -Fore DarkGray}
        $u="https://www.youtube.com/watch?v=$id"
        $predicted=& $YtDlp @migArgs $u 2>$null
        if(-not $predicted){$skipped++;continue}
        if($predicted -is [array]){$predicted=$predicted[0]}
        $predicted=$predicted.Trim()
        $stemDir =Split-Path $predicted -Parent
        $stemName=[IO.Path]::GetFileNameWithoutExtension((Split-Path $predicted -Leaf))
        $found=$null
        foreach($tryExt in '.mp4','.mkv','.webm','.mp3','.m4a','.opus','.ogg'){
            $cand=Join-Path $OutDir (Join-Path $stemDir "$stemName$tryExt")
            if(Test-Path -LiteralPath $cand){$found=$cand;break}
        }
        if(-not $found){$notfound++;continue}
        $parent =Split-Path $found -Parent
        $leaf   =Split-Path $found -Leaf
        $ext    =[IO.Path]::GetExtension($leaf)
        $base   =[IO.Path]::GetFileNameWithoutExtension($leaf)
        $newLeaf="$base [$id]$ext"
        $newPath=Join-Path $parent $newLeaf
        if((Test-Path -LiteralPath $newPath) -or ($leaf -eq $newLeaf)){$skipped++;continue}
        Rename-Item -LiteralPath $found -NewName $newLeaf
        $renamed++
    }
    Write-Host "Renamed: $renamed   skipped: $skipped   not found: $notfound" -Fore Green
}

if($WorkerIndex -ge 0){
    $log="$Dir\worker$WorkerIndex.log"
    $err="$Dir\worker$WorkerIndex.err"
    Remove-Item $log,$err -EA SilentlyContinue
    $a=$BaseArgs+$Fmt+@(
        '--batch-file',$Url,
        '--continue','--no-overwrites','--ignore-errors','--no-playlist'
    )
    ("{0:HH:mm:ss.fff} START pid=$PID" -f (Get-Date))|Add-Content $log
    & $YtDlp @a 2>&1 | ForEach-Object{
        $s="$($_)"
        ("{0:HH:mm:ss.fff} {1}" -f (Get-Date),$s)|Add-Content $log
        if($s -cmatch '^ERROR: \[youtube\] ([A-Za-z0-9_-]{11}): (.*)$'){
            "$($matches[1])|$($matches[2])"|Add-Content $err
        }
        Write-Host $s
    }
    ("{0:HH:mm:ss.fff} END" -f (Get-Date))|Add-Content $log
    exit $LASTEXITCODE
}

function Invoke-Batch($TargetUrl){
    if($TargetUrl-match'\.txt$'){
        if(-not(Test-Path $TargetUrl)){Write-Host "Not found: $TargetUrl" -Fore Red;return}
        $list=@()
        Get-Content $TargetUrl|Where-Object{$_-match'\S'}|ForEach-Object{
            $line=$_.Trim()
            if($line-cmatch'watch\?v=([A-Za-z0-9_-]{11})'){
                $list+=[pscustomobject]@{Id=$matches[1];Title=$line}
            }
        }
    }
    elseif($TargetUrl-match'watch\?v=|youtu\.be/'){ Download-One $TargetUrl '[single]'; return }
    else{
        Write-Host "Enumerating: $TargetUrl" -Fore Cyan
        $list=@()
        $enumArgs=@('--cookies-from-browser',$CookiesProfile,'--js-runtimes',"deno:$Deno")
        $raw=& $YtDlp @enumArgs --flat-playlist --playlist-end 10000 --print "%(id)s" $TargetUrl 2>&1
        foreach($l in $raw){
            if($l-is[string]-and$l-cmatch'^([A-Za-z0-9_-]{11})$'){
                $list+=[pscustomobject]@{Id=$matches[1];Title=$matches[1]}
            }
        }
        # === DEBUG START (toggle with -DebugEnum) ===
        if($DebugEnum){
            $rejected=@($raw|Where-Object{$_-is[string]-and$_-cnotmatch'^([A-Za-z0-9_-]{11})$'})
            Write-Host "DEBUG raw=$($raw.Count) matched=$($list.Count) rejected=$($rejected.Count)" -Fore Yellow
            if($rejected.Count -gt 0){ $r0=$rejected[0]; $b=[System.Text.Encoding]::UTF8.GetBytes($r0); Write-Host "DIRECT: type=$($r0.GetType().FullName) len=$($r0.Length) match=$($r0 -cmatch '^([A-Za-z0-9_-]{11})$') bytes=$([System.BitConverter]::ToString($b))" -Fore Yellow }
            Write-Host "DEBUG first 30 rejected lines:" -Fore Yellow
            $rejected|Select-Object -First 30|ForEach-Object{Write-Host ("  [{0}] {1}" -f $_.Length,$_) -Fore DarkYellow}
            if($rejected.Count -gt 0){
                Write-Host "DEBUG hex of rejected[0]:" -Fore Yellow
                $rejected[0].ToCharArray()|ForEach-Object{Write-Host ('  {0:X4}  {1}' -f [int]$_,$_) -Fore Red}
            }
        }
        # === DEBUG END ===
    }

    if($list.Count -eq 0){
        Write-Host "Enumeration returned 0 videos - check cookies/bgutil (run with -DebugEnum)." -Fore Red
        return
    }

    $allList=$list
    $onDisk=Get-OnDiskIds
    $list=@($list|Where-Object{-not $onDisk.ContainsKey($_.Id)})
    Write-Host "Channel: $($allList.Count)  On disk: $($allList.Count-$list.Count)  To fetch: $($list.Count)" -Fore Cyan
    if($list.Count-eq0){Write-Host "Nothing new to download." -Fore Green;return}

    $n=[Math]::Min($Workers,[Math]::Max(1,$list.Count))
    Write-Host "Splitting $($list.Count) into $n workers x $Fragments fragments." -Fore Cyan

    $chunks=@{};for($i=0;$i-lt$n;$i++){$chunks[$i]=@()}
    for($i=0;$i-lt$list.Count;$i++){$chunks[$i%$n]+=$list[$i]}

    $chunkFiles=@()
    for($i=0;$i-lt$n;$i++){
        $cf="$Dir\chunk_$i.txt"
        $mf="$Dir\chunk_${i}_map.txt"
        Write-Utf8NoBom $cf ($chunks[$i]|ForEach-Object{"https://www.youtube.com/watch?v=$($_.Id)"})
        Write-Utf8NoBom $mf ($chunks[$i]|ForEach-Object{"$($_.Id)|$($_.Title)"})
        $chunkFiles+=$cf
    }

    $scriptPath=$PSCommandPath
    $procs=@()
    $script:workerProcs=@()
    for($i=0;$i-lt$n;$i++){
        Write-Host ("  W{0}: {1} files" -f $i, $chunks[$i].Count) -Fore DarkGray
        $wa=@('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"",
              '-Url',"`"$($chunkFiles[$i])`"",'-Mode',$Mode,'-Fragments',$Fragments,'-WorkerIndex',$i)
        $p=Start-Process powershell -ArgumentList $wa -PassThru -WindowStyle Hidden
        $procs+=$p
        $script:workerProcs+=$p
    }
    $script:workerProcs=$procs
    
    # === live progress polling (workers are hidden) ===
    Write-Host "Legend: done/total  now/avg/max MiB/s per worker" -Fore DarkGray
    $pollStart=Get-Date
    while($true){
        $allExited=$true
        foreach($p in $procs){ $p.Refresh(); if(-not $p.HasExited){ $allExited=$false; break } }
        if($allExited){ break }

        $onDiskNow=Get-OnDiskIds
        $parts=@(); $sumDone=0; $sumTotal=0; $sumAvg=0
        for($i=0;$i-lt$n;$i++){
            $total=$chunks[$i].Count
            $done=0
            foreach($v in $chunks[$i]){ if($onDiskNow.ContainsKey($v.Id)){ $done++ } }
            $speeds=@()
            $logFile="$Dir\worker$i.log"
            if(Test-Path $logFile){
                foreach($line in (Get-Content $logFile -Tail 40 -EA SilentlyContinue)){
                    if($line -cmatch '\[download\]\s+[\d.]+%\s+of.*?at\s+([\d.]+)(\w+)/s'){
                        $spd=[double]$matches[1]
                        switch($matches[2]){
                            'KiB'{$spd/=1024}
                            'GiB'{$spd*=1024}
                            'KB' {$spd*=1000/1048576}
                            'GB' {$spd*=1024}
                            'B'  {$spd/=1048576}
                        }
                        $speeds+=$spd
                    }
                }
            }
            $avg=if($speeds.Count-gt0){[math]::Round(($speeds|Measure-Object -Average).Average,1)}else{0}
            $max=if($speeds.Count-gt0){[math]::Round(($speeds|Measure-Object -Maximum).Maximum,1)}else{0}
            if($procs[$i].HasExited){
                $parts+=("Worker{0}: {1}/{2} DONE" -f ($i+1),$done,$total)
            } else {
                $parts+=("Worker{0}: {1}/{2}" -f ($i+1),$done,$total)
            }
            $sumDone+=$done; $sumTotal+=$total; $sumAvg+=$avg
        }
        $elapsed=(Get-Date)-$pollStart
        $elapsedStr=if($elapsed.TotalHours-ge1){"{0:hh\:mm\:ss}"-f $elapsed}else{"{0:mm\:ss}"-f $elapsed}
        Write-Host ("[{0:HH:mm:ss} +{1}] {2} | Total {3}/{4} @ {5:0.0} MB/s" -f (Get-Date),$elapsedStr,($parts -join '  '),$sumDone,$sumTotal,$sumAvg) -Fore DarkGray
        Start-Sleep -Seconds 5
    }

    $onDiskAfter=Get-OnDiskIds
    $ok=0;$fail=0
    for($i=0;$i-lt$n;$i++){
        $mf="$Dir\chunk_${i}_map.txt"
        $errFile="$Dir\worker$i.err"
        $reasons=@{}
        if(Test-Path $errFile){
            Get-Content $errFile|ForEach-Object{
                $p=$_ -split '\|',2
                if($p.Count-eq2){$reasons[$p[0]]=$p[1]}
            }
        }
        if(Test-Path $mf){
            Get-Content $mf|ForEach-Object{
                $p=$_ -split '\|',2
                if($onDiskAfter.ContainsKey($p[0])){
                    $ok++
                }else{
                    $fail++
                    $title=if($p.Count-gt1){$p[1]}else{'[unknown]'}
                    $why=if($reasons.ContainsKey($p[0])){$reasons[$p[0]]}else{'not on disk, no error captured'}
                    "$title | https://www.youtube.com/watch?v=$($p[0]) | $why"|Add-Content $MasterFailed
                }
            }
        }
    }

    $missing=@($allList|Where-Object{-not $onDiskAfter.ContainsKey($_.Id)})
    Write-Host ""
    Write-Host "  This run - OK: $ok  Failed: $fail" -Fore $(if($fail-gt0){'Yellow'}else{'Green'})
    Write-Host "  Verified on disk: $($allList.Count-$missing.Count)/$($allList.Count)" -Fore $(if($missing.Count){'Yellow'}else{'Green'})
    if($missing.Count-gt0){Write-Host "  Details: $MasterFailed" -Fore Yellow}
    $chunkFiles|Remove-Item -EA SilentlyContinue
    Get-ChildItem "$Dir\chunk_*_map.txt"|Remove-Item -EA SilentlyContinue
    Get-ChildItem "$Dir\worker*.err","$Dir\worker*.log"|Remove-Item -EA SilentlyContinue
}

$bgStarted=$false;$bgProc=$null
try {
    Write-Host "=== YouTube Downloader ===" -Fore Magenta
    Write-Host "(to stop: press Ctrl+C, do not close with the X button — X leaves bgutil-pot running)" -Fore DarkGray
    if(Get-Process bgutil-pot -EA SilentlyContinue){
        Write-Host "PO-token provider already running (using it)." -Fore Green
    } else {
        $bgLog = Join-Path $Dir 'bgutil.log'
        Remove-Item $bgLog,"$bgLog.err" -EA SilentlyContinue
        $bgProc = Start-Process $Bgutil -ArgumentList 'server','--port','4416' -WindowStyle Hidden -PassThru -RedirectStandardOutput $bgLog -RedirectStandardError "$bgLog.err"
        $bgStarted = $true
        Start-Sleep 3
        Write-Host "bgutil-pot started (PID $($bgProc.Id))." -Fore Green
    }

    if(-not $SkipCheckup){
        if(-not (Test-Environment)){
            Write-Host "Fix the items marked X above before downloading." -Fore Red
            Write-Host "See WHEN-BROKEN.txt for what each one means." -Fore Red
            return
        }
    }

    if($Url){
        $Url=$Url.Trim().Trim('"').Trim("'")
        if(-not $PSBoundParameters.ContainsKey('Mode') -and $Url-match'watch\?v=|youtu\.be/'){
            Write-Host "1) Video  2) Audio"
            if((Read-Host "Choose") -eq '2'){$Mode='audio'}
        }
        Invoke-Batch $Url
        return
    }

    while($true){
        Write-Host ""
        Write-Host "Enter: URL / .txt path / q to quit" -Fore DarkGray
        $u=Read-Host "URL"
        if(-not $u -or $u -match '^\s*[qQ]\s*$'){break}
        $u=$u.Trim().Trim('"').Trim("'")
        if($u-match'watch\?v=|youtu\.be/'){
            Write-Host "1) Video  2) Audio" -Fore DarkGray
            if((Read-Host "Choose") -eq '2'){$Mode='audio'}else{$Mode='video'}
        }
        Invoke-Batch $u
    }
}
finally {
    if($script:workerProcs){
        foreach($wp in $script:workerProcs){
            if($wp -and -not $wp.HasExited){
                & taskkill /T /F /PID $wp.Id 2>&1 | Out-Null
            }
        }
        $script:workerProcs=$null
    }
    $bgNow = Get-Process bgutil-pot -EA SilentlyContinue
    if($bgNow){
        $bgNow | Stop-Process -Force -EA SilentlyContinue
    }
}