[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$RepositoryName = "cmtr-msdta2zd-repo"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

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

function Test-CodeCommitRepository {
    param([Parameter(Mandatory = $true)][string]$Name)

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & aws codecommit get-repository --repository-name $Name --region $Region 1>$null 2>$null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference
    return $exitCode -eq 0
}

Write-Output "=== 1. Verify AWS identity ==="
Invoke-Aws @(
    "sts", "get-caller-identity",
    "--query", "{Account:Account,Arn:Arn}",
    "--output", "json"
) | Out-Host

Write-Output "=== 2. Create or verify CodeCommit repository ==="
if (Test-CodeCommitRepository -Name $RepositoryName) {
    Write-Output "Repository already exists: $RepositoryName"
} else {
    Invoke-Aws @(
        "codecommit", "create-repository",
        "--repository-name", $RepositoryName,
        "--repository-description", "Route 53 private DNS failover CloudFormation deployment",
        "--region", $Region,
        "--query", "repositoryMetadata.{Name:repositoryName,Arn:Arn,CloneUrlHttp:cloneUrlHttp}",
        "--output", "json"
    ) | Out-Host
}

Write-Output "=== 3. Confirm repository ==="
Invoke-Aws @(
    "codecommit", "get-repository",
    "--repository-name", $RepositoryName,
    "--region", $Region,
    "--query", "repositoryMetadata.{Name:repositoryName,Arn:Arn,CloneUrlHttp:cloneUrlHttp,DefaultBranch:defaultBranch}",
    "--output", "json"
) | Out-Host

Write-Output "Objective 1 complete. CodeCommit repository ready: $RepositoryName"