param(
    [switch]$Show,
    [switch]$Reset
)

$ErrorActionPreference='Continue'
$CfgFile = Join-Path $PSScriptRoot 'cookie.txt'

function Find-FirefoxProfilePath($appdataSubpath){
    $profilesDir = Join-Path $env:APPDATA "$appdataSubpath\Profiles"
    if(-not (Test-Path $profilesDir)){ return $null }
    $profiles = @(Get-ChildItem $profilesDir -Directory -EA SilentlyContinue)
    if($profiles.Count -eq 0){ return $null }
    if($profiles.Count -eq 1){
        Write-Host "  Auto-detected: $($profiles[0].Name)" -Fore DarkGray
        return $profiles[0].FullName
    }
    Write-Host ""
    Write-Host "  Multiple profiles found (pick the one with the most cookies):" -Fore DarkGray
    for($i=0;$i-lt$profiles.Count;$i++){
        $p = $profiles[$i]
        $cookieFile = Join-Path $p.FullName 'cookies.sqlite'
        $size = if(Test-Path $cookieFile){ "{0:N0} KB" -f ((Get-Item $cookieFile).Length/1KB) } else { 'no cookies.sqlite' }
        Write-Host ("    {0,2}) {1,-45} [{2}]" -f ($i+1), $p.Name, $size)
    }
    Write-Host ""
    $pick = Read-Host "  Choose (1-$($profiles.Count))"
    $idx = 0
    if([int]::TryParse($pick,[ref]$idx) -and $idx -ge 1 -and $idx -le $profiles.Count){
        return $profiles[$idx-1].FullName
    }
    return $null
}

# --- Show mode ---
if($Show){
    if(-not (Test-Path $CfgFile)){ Write-Host "Not configured — run setup.bat"; return }
    $line = Get-Content $CfgFile -EA SilentlyContinue | Where-Object { $_ -and $_ -notmatch '^\s*#' } | Select-Object -First 1
    if(-not $line){ Write-Host "cookie.txt is empty — no cookies configured"; return }
    $line = $line.Trim()
    Write-Host "Current: $line" -Fore Cyan
    if($line -cmatch '^[a-z]+:(.+)$'){
        $p = $matches[1]
        if(Test-Path $p){ Write-Host "  Path exists: yes" -Fore Green }
        else{ Write-Host "  Path exists: NO - run setup.bat to re-pick" -Fore Red }
    }
    return
}

# --- Reset mode ---
if($Reset -and (Test-Path $CfgFile)){ Remove-Item $CfgFile }

# --- Already configured, skip unless -Reset ---
if((Test-Path $CfgFile) -and -not $Reset){
    $line = Get-Content $CfgFile -EA SilentlyContinue | Where-Object { $_ -and $_ -notmatch '^\s*#' } | Select-Object -First 1
    if($line){
        $line = $line.Trim()
        if($line -cmatch '^[a-z]+:(.+)$' -and -not (Test-Path $matches[1])){
            Write-Host "Stored path no longer exists - re-prompting..." -Fore Yellow
        } else {
            Write-Host "Already configured: $line" -Fore Green
            Write-Host "Run 'setup.bat -Reset' or delete cookie.txt to reconfigure." -Fore DarkGray
            return
        }
    }
}

# --- Prompt ---
Write-Host ""
Write-Host "=== Cookie setup ===" -Fore Magenta
Write-Host "Cookies enable age-restricted and account-only videos." -Fore DarkGray
Write-Host "Public videos work without cookies." -Fore DarkGray
Write-Host ""
Write-Host "  1) Firefox"
Write-Host "  2) Waterfox"
Write-Host "  3) LibreWolf"
Write-Host "  4) Chrome     (may be blocked by Windows encryption)"
Write-Host "  5) Edge       (may be blocked by Windows encryption)"
Write-Host "  6) Brave      (may be blocked by Windows encryption)"
Write-Host "  7) Vivaldi    (may be blocked by Windows encryption)"
Write-Host "  8) Opera      (may be blocked by Windows encryption)"
Write-Host "  9) Custom path"
Write-Host " 10) Skip cookies"
Write-Host ""
$choice = Read-Host "Choose (1-10)"

$result = ''
switch($choice){
    '1' { $p=Find-FirefoxProfilePath 'Mozilla\Firefox'; if($p){ $result="firefox:$p" } }
    '2' { $p=Find-FirefoxProfilePath 'Waterfox';        if($p){ $result="firefox:$p" } }
    '3' { $p=Find-FirefoxProfilePath 'LibreWolf';       if($p){ $result="firefox:$p" } }
    '4' { $result='chrome' }
    '5' { $result='edge' }
    '6' { $result='brave' }
    '7' { $result='vivaldi' }
    '8' { $result='opera' }
    '9' {
        Write-Host "  Examples:" -Fore DarkGray
        Write-Host "    firefox:C:\Users\You\AppData\Roaming\Mozilla\Firefox\Profiles\xxxxx" -Fore DarkGray
        Write-Host "    chrome" -Fore DarkGray
        $result = (Read-Host "  Enter").Trim()
    }
    '10' { $result='' }
    default { Write-Host "  Invalid choice." -Fore Yellow; return }
}

try {
    [IO.File]::WriteAllText($CfgFile, $result, (New-Object Text.UTF8Encoding $false))
    if($result){ Write-Host ""; Write-Host "Saved: $result" -Fore Green }
    else{ Write-Host ""; Write-Host "Saved empty - no cookies will be used." -Fore Yellow }
} catch {
    Write-Host "Failed to write cookie.txt: $_" -Fore Red
}