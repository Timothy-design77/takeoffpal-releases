# Sign one file with the already-logged-in Azure session and ArtifactSigning module.
# Used as the NSIS !uninstfinalize hook. Never print secret values.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
if ($args.Count -ne 1 -or -not $args[0]) {
    Write-Error "usage: sign-one.ps1 <file>"
    exit 2
}
$path = $args[0]
if (-not (Test-Path -LiteralPath $path)) {
    Write-Error "file to sign is missing"
    exit 1
}
if (-not $env:AZURE_ARTIFACT_SIGNING_ENDPOINT -or -not $env:AZURE_ARTIFACT_SIGNING_ACCOUNT -or -not $env:AZURE_ARTIFACT_SIGNING_PROFILE) {
    Write-Error "missing signing account values"
    exit 1
}
Import-Module ArtifactSigning -ErrorAction Stop
$params = @{
    Endpoint = $env:AZURE_ARTIFACT_SIGNING_ENDPOINT
    CodeSigningAccountName = $env:AZURE_ARTIFACT_SIGNING_ACCOUNT
    CertificateProfileName = $env:AZURE_ARTIFACT_SIGNING_PROFILE
    Files = $path
    FileDigest = 'SHA256'
    TimestampRfc3161 = 'http://timestamp.acs.microsoft.com'
    TimestampDigest = 'SHA256'
}
Invoke-ArtifactSigning @params
$verify = Join-Path $PSScriptRoot '..\sign-windows.ps1'
& $verify verify $path
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
