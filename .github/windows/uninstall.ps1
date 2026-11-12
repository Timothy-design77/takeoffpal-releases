# "Uninstall Estimator.exe" runs this. It removes what Setup and the installer created and nothing else: each
# version's manifest files, the version pointer files, its own setup files and the two shortcuts that start Estimator.
# It never goes through a link or junction, and anything else in the folder is left where it is. Each version folder
# is renamed first, so a file in use stops the uninstall before anything is deleted.
# Exit 0 = removed; 4 = a file is in use (nothing removed); 5 = some of Estimator's own files remain (the uninstaller and
# its Apps & Features entry stay, so it can run again).
param([Parameter(Mandatory)][string]$Root)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$ordinary = @{}

function Test-Ordinary([string]$Path) {
    # True when $Path exists and neither it nor any folder above it is a link or junction.
    if ($ordinary.ContainsKey($Path)) { return $true }
    try { $attributes = [IO.File]::GetAttributes($Path) } catch { return $false }
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    $parent = [IO.Path]::GetDirectoryName($Path)
    if ($parent -and !(Test-Ordinary $parent)) { return $false }
    if ($attributes -band [IO.FileAttributes]::Directory) { $ordinary[$Path] = $true }
    return $true
}

$failed = 0
function Remove-File([string]$Path) {
    if (!(Test-Ordinary $Path) -or ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::Directory)) { return }
    try { [IO.File]::SetAttributes($Path, 'Normal'); [IO.File]::Delete($Path) }
    catch { $script:failed++; Write-Warning "Could not remove $Path : $_" }
}

function Remove-EmptyFolder([string]$Path) {
    # Only an ordinary folder with nothing left in it; anything someone else put there stays.
    if ((Test-Ordinary $Path) -and !(Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)) {
        try { [IO.Directory]::Delete($Path, $false) } catch { $script:failed++; Write-Warning "Could not remove $Path : $_" }
    }
}

if (!(Test-Path -LiteralPath $Root)) { exit 0 }
if (!(Test-Ordinary $Root)) { Write-Warning "Not removed: $Root is reached through a link or junction."; exit 5 }

# 1. Rename every installed version (and failed staging) out of the way, or none: a file in use stops it here.
$versions = Join-Path $Root 'versions'
$folders = @(Get-ChildItem -LiteralPath $Root -Directory -Force -Filter 'staging-*') +
    @(if (Test-Ordinary $versions) { Get-ChildItem -LiteralPath $versions -Directory -Force })
$renamed = [Collections.Generic.List[object]]::new()
foreach ($folder in $folders) {
    $path = $folder.FullName
    if (!(Test-Ordinary $path) -or !(Test-Ordinary (Join-Path $path 'build-manifest.json'))) { continue }
    if ($folder.Name -like '.removing-*') { $renamed.Add(@($path, $path)); continue }  # Left by an earlier run.
    if ($folder.Name -notmatch '^([0-9a-f]{40}|staging-[0-9a-f]{32})$') { continue }
    $target = Join-Path $versions ('.removing-' + [Guid]::NewGuid().ToString('N'))
    try {
        $null = [IO.Directory]::CreateDirectory($versions)
        [IO.Directory]::Move($path, $target)
        $renamed.Add(@($path, $target))
    } catch {
        Write-Warning "In use: $path : $_"
        foreach ($pair in $renamed) { if ($pair[0] -ne $pair[1]) { [IO.Directory]::Move($pair[1], $pair[0]) } }
        exit 4
    }
}

# 2. Delete each version's own files (its manifest's list), then its folders once they are empty. The manifest goes
#    last, and only when every file it lists is gone, so a run that fails partway leaves the next run its list.
foreach ($pair in $renamed) {
    $folder = $pair[1]
    $list = Join-Path $folder 'build-manifest.json'
    try { $manifest = Get-Content -LiteralPath $list -Raw | ConvertFrom-Json }
    catch { $failed++; Write-Warning "Unreadable manifest in $folder : $_"; continue }
    $before = $failed
    $parents = @{}
    foreach ($name in @($manifest.files.PSObject.Properties.Name)) {
        if (!$name -or $name -match '[\\:]' -or $name.StartsWith('/') -or
            @($name.Split('/') | Where-Object { !$_ -or $_ -eq '.' -or $_ -eq '..' }).Count) { continue }
        $path = Join-Path $folder $name.Replace('/', '\')
        Remove-File $path
        for ($parent = [IO.Path]::GetDirectoryName($path); $parent.Length -gt $folder.Length; $parent = [IO.Path]::GetDirectoryName($parent)) {
            $parents[$parent] = $true
        }
    }
    if ($failed -ne $before) { continue }
    Remove-File $list
    foreach ($parent in @($parents.Keys | Sort-Object Length -Descending) + $folder) { Remove-EmptyFolder $parent }
}

# 3. The version pointer and the installer's other files beside it, and the update check's (RemoteFeed).
$owned = '^(version\.json|version\.lock|version-[0-9a-f]{32}\.tmp|version\.json\.[0-9a-f]{32}\.tmp|restart-[0-9a-f]{32}\.json|' +
    'update-check\.json|update-check\.lock|update-check\.json\.[0-9a-f]{32}\.tmp|update-[0-9a-f]{40}(\.[A-Za-z0-9]+)?)$'
foreach ($file in Get-ChildItem -LiteralPath $Root -File -Force) {
    if ($file.Name -match $owned) {
        Remove-File $file.FullName
    }
}

# 4. The Desktop and Start menu shortcuts, only while they still start an installed version.
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @([Environment]::GetFolderPath('DesktopDirectory'), [Environment]::GetFolderPath('Programs'))) {
    if (!$folder) { continue }
    foreach ($link in @((Join-Path $folder 'Takeoff Pal.lnk'), (Join-Path $folder 'Estimator.lnk'))) {
        if (!(Test-Path -LiteralPath $link -PathType Leaf)) { continue }
        if ($shell.CreateShortcut($link).TargetPath.StartsWith("$versions\", [StringComparison]::OrdinalIgnoreCase)) {
            try { [IO.File]::Delete($link) } catch { $failed++; Write-Warning "Could not remove $link : $_" }
        }
    }
}

if ($failed) { exit 5 }

# 5. Last, the uninstaller's own files: the icon, then the uninstaller and this helper together. Both are read first
#    and written back if either can't be deleted, so a run that stops here can always be run again.
$setup = Join-Path $Root 'setup'
Remove-File (Join-Path $setup 'estimator.ico')
if ($failed) { exit 5 }
$recovery = @('Uninstall Estimator.exe', 'uninstall.ps1' | ForEach-Object { Join-Path $setup $_ } | Where-Object { Test-Ordinary $_ })
$saved = @{}
try {
    foreach ($path in $recovery) { $saved[$path] = [IO.File]::ReadAllBytes($path) }
    foreach ($path in $recovery) { [IO.File]::SetAttributes($path, 'Normal'); [IO.File]::Delete($path) }
} catch {
    Write-Warning "Could not remove the uninstaller: $_"
    foreach ($path in $saved.Keys) { if (!(Test-Path -LiteralPath $path)) { [IO.File]::WriteAllBytes($path, $saved[$path]) } }
    exit 5
}
foreach ($folder in @($setup, $versions, $Root)) { Remove-EmptyFolder $folder }
exit $(if ($failed) { 5 } else { 0 })
