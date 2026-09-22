[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$RepositoryName = "cmtr-msdta2zd-repo",
    [string]$BranchName = "main",
    [string]$SourceDirectory
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
    $SourceDirectory = Join-Path $PSScriptRoot "source"
}

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = @(& aws @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference

    if ($exitCode -ne 0) {
        throw "AWS CLI failed: aws $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }

    return ($output | Out-String)
}

function Get-BranchCommitId {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Branch
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = @(& aws codecommit get-branch --repository-name $Name --branch-name $Branch --region $Region --query "branch.commitId" --output text 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference

    if ($exitCode -ne 0) {
        return $null
    }

    return (($output | Out-String).Trim())
}

$SourceFiles = @("template.yml", "buildspec.yml")
foreach ($SourceFile in $SourceFiles) {
    $SourcePath = Join-Path $SourceDirectory $SourceFile
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Required source file is missing: $SourcePath"
    }
}

Write-Output "=== 1. Upload source files to CodeCommit ==="
$ParentCommitId = Get-BranchCommitId -Name $RepositoryName -Branch $BranchName
foreach ($SourceFile in $SourceFiles) {
    $SourcePath = Join-Path $SourceDirectory $SourceFile
    $PutFileArguments = @(
        "codecommit", "put-file",
        "--repository-name", $RepositoryName,
        "--branch-name", $BranchName,
        "--file-path", $SourceFile,
        "--file-content", "fileb://$SourcePath",
        "--commit-message", "Update $SourceFile for Route 53 failover deployment",
        "--region", $Region,
        "--query", "commitId",
        "--output", "text"
    )
    if (-not [string]::IsNullOrWhiteSpace($ParentCommitId)) {
        $PutFileArguments += @("--parent-commit-id", $ParentCommitId)
    }
    try {
        $ParentCommitId = (Invoke-Aws $PutFileArguments).Trim()
        Write-Output "Committed ${SourceFile}: $ParentCommitId"
    } catch {
        if ($_.Exception.Message -match "SameFileContentException") {
            Write-Output "Unchanged file already present: $SourceFile"
        } else {
            throw
        }
    }
}

Write-Output "=== 2. Verify CodeCommit branch and files ==="
Invoke-Aws @(
    "codecommit", "get-branch",
    "--repository-name", $RepositoryName,
    "--branch-name", $BranchName,
    "--region", $Region,
    "--query", "branch.{Name:branchName,CommitId:commitId}",
    "--output", "json"
) | Out-Host

foreach ($SourceFile in $SourceFiles) {
    Invoke-Aws @(
        "codecommit", "get-file",
        "--repository-name", $RepositoryName,
        "--commit-specifier", $BranchName,
        "--file-path", $SourceFile,
        "--region", $Region,
        "--query", "{Path:blobId,Size:fileSize}",
        "--output", "json"
    ) | Out-Host
}

Write-Output "Objective 1 source control complete. template.yml and buildspec.yml are in ${RepositoryName}/${BranchName}."