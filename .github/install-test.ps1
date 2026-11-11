# INSTALL-TEST.md on a fresh Windows user (CI only; never on a PC with a real Estimator): Setup with its pages
# (Enter for Finish, which opens Estimator), a job saved to the default folder, uninstall, the job and settings kept,
# then a silent reinstall that opens the same job.
param([Parameter(Mandatory)][string]$Setup)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'Programs\Estimator'
$data = Join-Path $env:LOCALAPPDATA 'Estimator'
$jobs = Join-Path $env:USERPROFILE 'Estimator Projects'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Estimator'
$links = @((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Takeoff Pal.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Takeoff Pal.lnk'))
$results = [Collections.Generic.List[object]]::new()
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $results.Add([pscustomobject]@{ Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Check = $name; Detail = $detail })
    Write-Host ("{0} {1} {2}" -f $results[-1].Result, $name, $detail)
}
function Running { @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith("$root\versions\", 'OrdinalIgnoreCase') }) }
function Version { @(Get-ChildItem (Join-Path $root 'versions') -Directory -EA SilentlyContinue | Where-Object Name -match '^[0-9a-f]{40}$') }
function Wait([scriptblock]$until, [int]$seconds) {
    $end = (Get-Date).AddSeconds($seconds)
    while (-not (& $until) -and (Get-Date) -lt $end) { Start-Sleep 1 }
    [bool](& $until)
}
# The installed app started without a browser; returns its origin, token and process.
function Start-Estimator {
    $v = (Version)[0].FullName
    $file = Join-Path $env:RUNNER_TEMP "session-$([guid]::NewGuid().ToString('N')).json"
    $p = Start-Process (Join-Path $v 'runtime\python.exe') -ArgumentList '-B', '-I', '-S', "`"$v\app\launch.pyc`"", '--no-browser',
        '--port', '0', '--session-file', "`"$file`"", '--new-window' -WorkingDirectory $v -WindowStyle Hidden -PassThru
    if (-not (Wait { Test-Path $file } 120)) { throw 'Estimator did not start in 120 s' }
    Start-Sleep 1
    $s = Get-Content $file -Raw | ConvertFrom-Json
    $app = @{ Origin = $s.origin; Token = $s.token; Process = $p }
    if (-not (Wait { try { (Api $app GET '/api/v1/startup').status -eq 'ready' } catch { $false } } 120)) { throw 'Estimator never became ready' }
    # T-323: the beta build holds everything behind the Beta Agreement; accept it the way the screen does, then wait
    # for the license check that follows Agree (offline grace here).
    $consent = $null; try { $consent = Api $app GET '/api/v1/consent' } catch {}
    if ($consent -and -not $consent.accepted) {
        $null = Api $app POST '/api/v1/consent' @{ choice = 'accepted'; shown_text_sha256 = ('0' * 64) }
        if (-not (Wait { try { (Api $app GET '/api/v1/license').allowed } catch { $false } } 60)) { throw 'license not allowed after Agree' }
    }
    $app
}
function Api($app, [string]$method, [string]$path, $body = $null) {
    $call = @{ Method = $method; Uri = "$($app.Origin)$path"; Headers = @{ 'x-estimator-session' = $app.Token }; ContentType = 'application/json' }
    if ($null -ne $body) { $call.Body = $body | ConvertTo-Json }
    Invoke-RestMethod @call
}
function Stop-Estimator($app) {
    try { $null = Api $app POST '/api/v1/session/close' @{} } catch {}
    if (-not (Wait { $app.Process.HasExited } 30)) { & taskkill /T /F /PID $app.Process.Id | Out-Null }
}
function Uninstall {
    $entry = Get-ItemProperty $key -EA SilentlyContinue
    if (-not $entry) { return $false }
    $null = Start-Process $entry.UninstallString.Trim('"') -ArgumentList '/S' -Wait -PassThru
    Wait { -not (Test-Path $key) } 90  # It hands over to a copy of itself in TEMP.
}
function Snapshot($file) { $i = Get-Item -LiteralPath $file; "$($i.Name) $($i.Length) bytes $($i.LastWriteTimeUtc.ToString('o')) $((Get-FileHash -LiteralPath $file).Hash)" }

$bytes = (Get-Item $Setup).Length
$head = [IO.File]::ReadAllBytes($Setup)[0..1]
Check 'downloaded Setup is one Windows program' ($head[0] -eq 0x4D -and $head[1] -eq 0x5A) "$bytes bytes, SHA-256 $((Get-FileHash $Setup).Hash)"
Check 'fresh user: no Estimator, no job folder, no settings' (-not (Test-Path $root) -and -not (Test-Path $key) -and -not (Test-Path $jobs) -and -not (Test-Path $data))

# Steps 2-4: Setup with its pages. Finish (Open Estimator ticked) opens Estimator.
$p = Start-Process $Setup -PassThru
$shell = New-Object -ComObject WScript.Shell
for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) {
    Start-Sleep 3
    if ($shell.AppActivate('Takeoff Pal Setup')) { Start-Sleep -Milliseconds 300; $shell.SendKeys('{ENTER}') }
}
Check 'Setup with its pages finishes' ($p.HasExited -and $p.ExitCode -eq 0) "exit $($p.ExitCode)"
Check 'one version installed' ((Version).Count -eq 1) ((Version).Name -join ',')
Check 'Desktop and Start menu shortcuts' ((Test-Path $links[0]) -and (Test-Path $links[1]))
$entry = Get-ItemProperty $key -EA SilentlyContinue
Check 'Installed apps lists Estimator with its version' ($entry -and $entry.DisplayName -eq 'Takeoff Pal' -and $entry.DisplayVersion) "$($entry.DisplayVersion)"
Check 'Finish opens Estimator' (Wait { (Running).Count -gt 0 } 90) (((Running) | ForEach-Object Name | Sort-Object -Unique) -join ',')
$window = Wait { @(Get-Process | Where-Object { $_.MainWindowTitle -like '*Takeoff Pal*' -and $_.MainWindowTitle -notlike '*Setup*' }).Count -gt 0 } 90
Check 'its window opens' $window ((Get-Process | Where-Object { $_.MainWindowTitle -like '*Takeoff Pal*' } | ForEach-Object { "$($_.Name): $($_.MainWindowTitle)" }) -join '; ')
Get-Process | Where-Object { $_.MainWindowTitle -like '*Takeoff Pal*' } | ForEach-Object { $null = $_.CloseMainWindow() }
Running | Stop-Process -Force
Check 'Estimator closed' (Wait { (Running).Count -eq 0 } 30)
# A fresh install opens locked until a license key is pasted. The test opens it by the app's own offline rule: a key
# with a good check inside the 14-day grace, and the license server unreachable from this runner.
Add-Content "$env:SystemRoot\System32\drivers\etc\hosts" "`n127.0.0.1 takeoffpal.com`n127.0.0.1 takeoffpal-beta.vercel.app"
Clear-DnsClientCache
$null = New-Item -ItemType Directory -Force (Join-Path $data 'settings')
@{ key = 'install-test'; last_good = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); version = 1 } | ConvertTo-Json |
    Set-Content (Join-Path $data 'settings\license.json') -Encoding ascii

# Steps 6 and 9: a job saved to the default folder, then uninstall keeps it and the settings.
$job = $null; $id = $null
try {
    $app = Start-Estimator
    $items = Api $app GET '/api/v1/library/items'
    $source = (Api $app GET '/api/v1/session').catalog_source
    $csv = (Get-FileHash (Join-Path (Version)[0].FullName 'app\src\estimator\costing\library.csv')).Hash
    Check 'built-in library connected on a fresh user, no picker' ($items.items.Count -eq 1903 -and $csv -in @('351868e0fc6b3c0eaecb9a4a0521766a31a319b233cd7f89169be38a45332ab0', '55c20bb600019db81548d3197aac7ad302d55ba09c37ea87c4548b13e4208377', '87c9b94a2aa878fe652ce4b5e57ba1a348657fdd21d95967d0709d72fc9bedeb') -and $source.licence_note -eq $items.licence_note -and $source.licence_note -like '*2026 TakeoffPal*') "$($items.items.Count) items, $csv, $($source.licence_note)"
    $id = (Api $app POST '/api/v1/project/create' @{ name = 'Install test' }).project_id
    Stop-Estimator $app
    $job = Join-Path $jobs 'Install test.sqlite'
} catch { Write-Host $_ }
Check 'a job is saved in Estimator Projects' ($job -and (Test-Path $job)) $(if ($job -and (Test-Path $job)) { Snapshot $job })
$before = if ($job -and (Test-Path $job)) { Snapshot $job } else { 'none' }
$settings = @(Get-ChildItem $data -Recurse -File -EA SilentlyContinue).Count
Check 'settings folder exists before uninstall' ($settings -gt 0) "$settings files in $data"
Check 'uninstall removes the Installed apps entry' (Uninstall)
Check 'program folder and shortcuts removed' (-not (Test-Path (Join-Path $root 'versions')) -and -not (Test-Path $links[0]) -and -not (Test-Path $links[1]))
Check 'the job is kept: same name, size, Date modified and contents' ($job -and (Test-Path $job) -and (Snapshot $job) -eq $before) $(if ($job -and (Test-Path $job)) { Snapshot $job })
Check 'settings and library folder is kept' (@(Get-ChildItem $data -Recurse -File -EA SilentlyContinue).Count -ge $settings) $data

# Reinstall, silent, and the same job opens.
$code = (Start-Process $Setup -ArgumentList '/S' -Wait -PassThru).ExitCode
Check 'silent reinstall' ($code -eq 0 -and (Version).Count -eq 1 -and (Test-Path $key)) "exit $code"
$opened = $null
try {
    $app = Start-Estimator
    $opened = (Api $app POST '/api/v1/project/open' @{ path = $job }).project_id
    Stop-Estimator $app
} catch { $opened = "error: $_" }
Check 'the kept job opens after reinstall' ($id -and $opened -eq $id) "saved $id, opened $opened"

$results | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL').Count
if ($failed) { throw "$failed of $($results.Count) checks failed" }
Write-Host "Install test: PASS ($($results.Count) checks)"
