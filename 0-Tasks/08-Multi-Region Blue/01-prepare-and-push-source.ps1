[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string]$RepositoryName = "cmtr-msdta2zd-repo",
    [string]$SourceDirectory = "$PSScriptRoot\source"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = @(& aws @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed: aws $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }
    return ($output | Out-String).Trim()
}

function Get-BranchCommitId {
    param([string]$Repository, [string]$Branch, [string]$AwsRegion)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = @(& aws codecommit get-branch --repository-name $Repository --branch-name $Branch --region $AwsRegion --query branch.commitId --output text 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference
    if ($exitCode -ne 0) { return $null }
    $commitId = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($commitId) -or $commitId -eq "None") { return $null }
    return $commitId
}

if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
    throw "Source directory does not exist: $SourceDirectory"
}

Write-Output "=== Confirm AWS identity ==="
Invoke-Aws @("sts", "get-caller-identity", "--query", "{Account:Account,Arn:Arn}", "--output", "table") | Out-Host

Write-Output "=== Ensure CodeCommit repository exists ==="
$oldPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$null = @(& aws codecommit get-repository --repository-name $RepositoryName --region $Region --output json 2>&1)
$repositoryExitCode = $LASTEXITCODE
$ErrorActionPreference = $oldPreference
if ($repositoryExitCode -ne 0) {
    Invoke-Aws @(
        "codecommit", "create-repository",
        "--repository-name", $RepositoryName,
        "--repository-description", "Blue/green multi-region application source",
        "--region", $Region,
        "--output", "json"
    ) | Out-Host
}

$parentCommitId = Get-BranchCommitId -Repository $RepositoryName -Branch "main" -AwsRegion $Region
$files = @(
    "app.py", "Dockerfile", "requirements.txt", "buildspec.yml", "appspec.yml",
    "scripts/stop_container.sh", "scripts/after_install.sh", "scripts/start_container.sh"
)

Write-Output "=== Push deployment source to CodeCommit main ==="
foreach ($relativePath in $files) {
    $filePath = Join-Path $SourceDirectory $relativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Required source file does not exist: $filePath"
    }
    $arguments = @(
        "codecommit", "put-file", "--repository-name", $RepositoryName,
        "--branch-name", "main", "--file-content", "fileb://$filePath",
        "--file-path", $relativePath, "--commit-message", "Add blue green deployment source",
        "--region", $Region, "--output", "json"
    )
    if (-not [string]::IsNullOrWhiteSpace($parentCommitId)) {
        $arguments += @("--parent-commit-id", $parentCommitId)
    }
    $commit = Invoke-Aws $arguments | ConvertFrom-Json
    $parentCommitId = $commit.commitId
    Write-Output "Pushed $relativePath at commit $parentCommitId"
}

Write-Output "Source preparation complete. Branch main is ready for CodePipeline."
