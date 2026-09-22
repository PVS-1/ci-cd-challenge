[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$RepositoryName = "cmtr-msdta2zd-static"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Invoke-AwsCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & aws @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    if ($exitCode -ne 0) {
        throw (($output | Out-String).Trim())
    }

    return ($output | Out-String)
}

Write-Output "=== 1. Verify AWS identity ==="
$Identity = Invoke-AwsCli @(
    "sts", "get-caller-identity",
    "--query", "{Account:Account,Arn:Arn}",
    "--output", "json"
)
$Identity | ConvertFrom-Json | ConvertTo-Json

Write-Output "=== 2. Check ECR repository ==="
$RepositoryOutput = $null
$RepositoryExists = $true
try {
    $RepositoryOutput = Invoke-AwsCli @(
        "ecr", "describe-repositories",
        "--repository-names", $RepositoryName,
        "--region", $Region,
        "--query", "repositories[0]",
        "--output", "json"
    )
} catch {
    if ($_.Exception.Message -match "RepositoryNotFoundException") {
        $RepositoryExists = $false
    } else {
        throw
    }
}

if (-not $RepositoryExists) {
    Write-Output "=== 3. Create ECR repository ==="
    $RepositoryOutput = Invoke-AwsCli @(
        "ecr", "create-repository",
        "--repository-name", $RepositoryName,
        "--image-scanning-configuration", "scanOnPush=true",
        "--image-tag-mutability", "MUTABLE",
        "--region", $Region,
        "--query", "repository",
        "--output", "json"
    )
} else {
    Write-Output "Repository already exists: $RepositoryName"
}

$Repository = $RepositoryOutput | ConvertFrom-Json
Write-Output "=== Objective 1 complete ==="
Write-Output ("Repository: {0}" -f $Repository.repositoryName)
Write-Output ("Registry URI: {0}" -f $Repository.repositoryUri)
Write-Output ("Region: {0}" -f $Region)
