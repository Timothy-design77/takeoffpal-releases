# Estimator-Setup.exe runs this from its temporary folder: the build's own installer (Install Estimator.ps1), after
# checking each file Setup writes for the uninstaller by the installer's own rule (no link or junction there or on the
# way).
# A failure is written in full to Estimator's setup log, and one plain line (what went wrong, what to do) to -Reason
# for Setup to show. Exit 0 = installed, 1 = not installed.
param([Parameter(Mandatory)][string]$Build, [Parameter(Mandatory)][string]$Setup, [Parameter(Mandatory)][string]$Reason)
$ErrorActionPreference = 'Stop'
$log = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Estimator\logs\setup.log'

function Write-Log([string]$Text) {
    try {
        $null = New-Item -ItemType Directory -Force (Split-Path $log)
        $entry = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), ($Text -replace '\s*[\r\n]+\s*', ' / ')
        Add-Content -LiteralPath $log -Value $entry -Encoding UTF8
    } catch { }  # A log that can't be written never stops the install.
}

try {
    . (Join-Path $Build 'Install Estimator.ps1')
    foreach ($name in @('estimator.ico', 'uninstall.ps1', 'Uninstall Estimator.exe')) {
        $null = Assert-OrdinaryPath (Join-Path $Setup $name)  # Each file Setup writes, and every folder above it.
    }
    $installed = Install-Estimator $Build 3>&1 | ForEach-Object {
        if ($_ -is [Management.Automation.WarningRecord]) { Write-Log "Warning: $_" } else { $_ }
    }
    Write-Log "Installed $($installed.SourceCommit)"
    # Claude Code, if it is on this PC, gets this version's MCP server (a tester build ships agent_mcp.pyc). Never fails.
    $mcp = Get-ChildItem -LiteralPath (Join-Path $installed.InstalledPath 'app\src\estimator\application') -Filter 'agent_mcp.py*' -EA SilentlyContinue | Select-Object -First 1
    if ($mcp) {
        try { & (Join-Path $installed.InstalledPath 'runtime\python.exe') -I $mcp.FullName --claude *> $null } catch { Write-Log "Claude Code MCP not added: $_" }
    }
    exit 0
} catch {
    $why = $_.Exception.Message
    $plain = switch -Regex ($why) {
        'unrelated shortcut' { "A shortcut named Takeoff Pal on your Desktop or Start menu isn't Takeoff Pal's. Rename it, then run Setup again."; break }
        'Reparse points' { "Takeoff Pal's folder links to another place. Remove that link, then run Setup again."; break }
        'stayed locked' { 'Takeoff Pal is busy. Close it, then run Setup again.'; break }
        'payload|manifest|package' { "Takeoff Pal's files are damaged. Uninstall Takeoff Pal, download Setup again, then run it."; break }
        default { "Takeoff Pal couldn't be installed. Restart the PC, then run Setup again." }
    }
    Write-Log "Not installed: $why | $($_.ScriptStackTrace) | Shown: $plain"
    [IO.File]::WriteAllText($Reason, $plain, [Text.Encoding]::ASCII)
    exit 1
}
