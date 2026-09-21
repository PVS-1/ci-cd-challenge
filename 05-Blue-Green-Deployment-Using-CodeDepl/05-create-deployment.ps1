[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$CodeDeployApplicationName = "cmtr-msdta2zd-app",
    [string]$DeploymentGroupName = "cmtr-msdta2zd-dg",
    [string]$GitHubRepository = "PVS-1/ci-cd-challenge",
    [string]$CommitId = ""
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$TaskRoot = $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $TaskRoot

function Invoke-AwsCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | Out-String).Trim()
        throw "AWS CLI command failed: aws $($Arguments -join ' ')`n$details"
    }

    return $output
}

try {
    Write-Output "=== 1. Verify CodeDeploy application and deployment group ==="
    Invoke-AwsCli @(
        "deploy", "get-application",
        "--application-name", $CodeDeployApplicationName,
        "--region", $Region
    ) | Out-Host

    Invoke-AwsCli @(
        "deploy", "get-deployment-group",
        "--application-name", $CodeDeployApplicationName,
        "--deployment-group-name", $DeploymentGroupName,
        "--region", $Region
    ) | Out-Host

    if ([string]::IsNullOrWhiteSpace($CommitId)) {
        $CommitId = (git -C $RepositoryRoot rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($CommitId)) {
            throw "Could not determine the current Git commit."
        }
    }

    Write-Output "=== 2. Create blue-green deployment from GitHub ==="
    $DeploymentId = ([string](Invoke-AwsCli @(
        "deploy", "create-deployment",
        "--application-name", $CodeDeployApplicationName,
        "--deployment-group-name", $DeploymentGroupName,
        "--deployment-config-name", "CodeDeployDefault.OneAtATime",
        "--github-location", "repository=$GitHubRepository,commitId=$CommitId",
        "--description", "Blue-green deployment from $GitHubRepository@$CommitId",
        "--region", $Region,
        "--query", "deploymentId",
        "--output", "text"
    ))).Trim()

    Write-Output "Objective 5 complete. DeploymentId: $DeploymentId"
    Write-Output "Monitor with:"
    Write-Output "aws deploy get-deployment --deployment-id $DeploymentId --region $Region --output table"
}
finally {
}
