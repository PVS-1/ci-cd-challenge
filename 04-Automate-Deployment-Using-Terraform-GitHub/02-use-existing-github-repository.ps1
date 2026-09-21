[CmdletBinding()]
param(
    [string]$ExpectedRemote = "https://github.com/PVS-1/ci-cd-challenge.git"
)

$ErrorActionPreference = "Stop"
$TaskRoot = $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $TaskRoot

Write-Output "=== 1. Verify local Git repository ==="
$isRepository = (git -C $RepositoryRoot rev-parse --is-inside-work-tree 2>$null).Trim()
if ($isRepository -ne "true") {
    throw "Repository root is not a Git repository: $RepositoryRoot"
}

$remoteUrl = (git -C $RepositoryRoot remote get-url origin 2>&1).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
    throw "Git remote 'origin' is not configured."
}

Write-Output "Repository root: $RepositoryRoot"
Write-Output "Remote origin: $remoteUrl"

if ($remoteUrl -ne $ExpectedRemote -and $remoteUrl -ne ($ExpectedRemote -replace '\.git$', '')) {
    throw "Unexpected origin. Expected '$ExpectedRemote', actual '$remoteUrl'."
}

Write-Output "=== 2. Verify GitHub main branch ==="
git -C $RepositoryRoot ls-remote --exit-code origin refs/heads/main | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Remote main branch was not found or GitHub authentication failed."
}

$currentBranch = (git -C $RepositoryRoot branch --show-current).Trim()
Write-Output "Local branch: $currentBranch"
Write-Output "Objective 2 complete. Existing GitHub repository is ready: $remoteUrl"
