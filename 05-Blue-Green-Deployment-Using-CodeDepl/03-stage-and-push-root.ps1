[CmdletBinding()]
param(
    [string]$CommitMessage = "Add CodeDeploy blue-green application"
)

$ErrorActionPreference = "Stop"
$TaskRoot = $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $TaskRoot
$SourceScripts = Join-Path $TaskRoot "scripts"
$RootScripts = Join-Path $RepositoryRoot "scripts"

$RequiredSourceFiles = @(
    (Join-Path $TaskRoot "application.py"),
    (Join-Path $TaskRoot "requirements.txt"),
    (Join-Path $TaskRoot "appspec.yml"),
    (Join-Path $SourceScripts "install-dependencies.sh"),
    (Join-Path $SourceScripts "stop-application.sh"),
    (Join-Path $SourceScripts "start-application.sh")
)

foreach ($sourceFile in $RequiredSourceFiles) {
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "Required Task 5 file is missing: $sourceFile"
    }
}

Write-Output "=== 1. Copy Task 5 files to repository root for validator ==="
Copy-Item -LiteralPath (Join-Path $TaskRoot "application.py") -Destination (Join-Path $RepositoryRoot "application.py") -Force
Copy-Item -LiteralPath (Join-Path $TaskRoot "requirements.txt") -Destination (Join-Path $RepositoryRoot "requirements.txt") -Force
Copy-Item -LiteralPath (Join-Path $TaskRoot "appspec.yml") -Destination (Join-Path $RepositoryRoot "appspec.yml") -Force
New-Item -ItemType Directory -Path $RootScripts -Force | Out-Null
Copy-Item -Path (Join-Path $SourceScripts "*") -Destination $RootScripts -Force

Write-Output "=== 2. Verify Git main branch ==="
$currentBranch = (git -C $RepositoryRoot branch --show-current).Trim()
if ($currentBranch -ne "main") {
    throw "Current branch is '$currentBranch'. Switch to main before pushing."
}

Write-Output "=== 3. Stage root deployment files ==="
git -C $RepositoryRoot add application.py requirements.txt appspec.yml scripts

git -C $RepositoryRoot update-index --chmod=+x scripts/install-dependencies.sh scripts/stop-application.sh scripts/start-application.sh

git -C $RepositoryRoot diff --cached --check
git -C $RepositoryRoot diff --cached --stat

Write-Output "=== 4. Commit and push ==="
git -C $RepositoryRoot commit -m $CommitMessage
git -C $RepositoryRoot push origin main

Write-Output "Objective 3 complete. Task 5 files are temporarily staged in repository root."
Write-Output "Move them back to the Task 5 folder only after challenge verification."
