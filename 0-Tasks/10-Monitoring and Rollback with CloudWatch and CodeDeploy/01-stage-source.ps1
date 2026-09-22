[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryDirectory
)

$ErrorActionPreference = "Stop"
$sourceDirectory = Join-Path $PSScriptRoot "source"

if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
    throw "Source directory was not found: $sourceDirectory"
}
if (-not (Test-Path -LiteralPath $RepositoryDirectory -PathType Container)) {
    throw "Repository directory was not found: $RepositoryDirectory"
}
if (-not (Test-Path -LiteralPath (Join-Path $RepositoryDirectory ".git") -PathType Container)) {
    throw "RepositoryDirectory is not a Git working tree: $RepositoryDirectory"
}

Copy-Item -Path (Join-Path $sourceDirectory "*") -Destination $RepositoryDirectory -Recurse -Force
Write-Output "Deployment source copied to $RepositoryDirectory"
Write-Output "Commit and push app.py, requirements.txt, buildspec.yml, appspec.yml, and scripts/ to the configured GitHub branch."
