# Verify Authenticode signatures and extract an NSIS Setup.exe.
# Called from windows-sign.yml and ship.yml. Never print secret values.
# Never use Set-PSDebug -Trace. Fail if a required signature is missing or invalid.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

function Usage {
    Write-Error "usage: sign-windows.ps1 extract <Setup.exe> <out-dir> | verify <file> [<file>...]"
    exit 2
}

if ($args.Count -lt 2) { Usage }
$command = $args[0]

function Find-SignTool {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "${env:ProgramFiles}\Windows Kits\10\bin"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $found = Get-ChildItem -Path $root -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match '\\x64$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Verify-One {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "missing file to verify"
        exit 1
    }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($null -eq $sig -or $sig.Status -ne 'Valid') {
        $status = if ($null -eq $sig) { 'missing' } else { [string]$sig.Status }
        Write-Error ("Authenticode status for {0} is {1}; expected Valid" -f (Split-Path $Path -Leaf), $status)
        exit 1
    }
    if (-not $sig.TimeStamperCertificate) {
        Write-Error ("{0} is signed but has no timestamp" -f (Split-Path $Path -Leaf))
        exit 1
    }
    $subject = $sig.SignerCertificate.Subject
    $issuer = $sig.SignerCertificate.Issuer
    $thumb = $sig.SignerCertificate.Thumbprint
    Write-Host ("OK {0}" -f (Split-Path $Path -Leaf))
    Write-Host ("  subject: {0}" -f $subject)
    Write-Host ("  issuer: {0}" -f $issuer)
    Write-Host ("  thumbprint: {0}" -f $thumb)
    $tool = Find-SignTool
    if ($tool) {
        & $tool verify /pa /tw /v $Path
        if ($LASTEXITCODE -ne 0) {
            Write-Error "signtool verify /pa /tw failed"
            exit 1
        }
    } else {
        Write-Host "signtool.exe not on PATH; Get-AuthenticodeSignature Status=Valid with a timestamp certificate is the check"
    }
}

if ($command -eq 'verify') {
    foreach ($path in $args[1..($args.Count - 1)]) {
        Verify-One -Path $path
    }
    exit 0
}

if ($command -ne 'extract') { Usage }
if ($args.Count -ne 3) { Usage }
$setup = $args[1]
$out = $args[2]
if (-not (Test-Path -LiteralPath $setup)) {
    Write-Error "Setup.exe not found"
    exit 1
}
New-Item -ItemType Directory -Force -Path $out | Out-Null
$seven = @(
    "${env:ProgramFiles}\7-Zip\7z.exe",
    "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
    "7z"
) | Where-Object { $_ -eq '7z' -or (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $seven) {
    Write-Error "7z.exe is required to unpack the NSIS installer"
    exit 1
}
& $seven x -y "-o$out" -- $setup
if ($LASTEXITCODE -ne 0) {
    Write-Error "7z extract failed"
    exit 1
}
Write-Host "extracted installer"
