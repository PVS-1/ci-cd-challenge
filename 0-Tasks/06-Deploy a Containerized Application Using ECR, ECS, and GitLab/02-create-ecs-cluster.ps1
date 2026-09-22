[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$ClusterName = "cmtr-msdta2zd-cluster"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Invoke-AwsCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }

    return $output | Out-String
}

Write-Output "=== 1. Verify AWS identity ==="
Invoke-AwsCli @(
    "sts", "get-caller-identity",
    "--query", "{Account:Account,Arn:Arn}",
    "--output", "json"
) | ConvertFrom-Json | ConvertTo-Json

Write-Output "=== 2. Create or verify ECS cluster ==="
$ClusterOutput = Invoke-AwsCli @(
    "ecs", "describe-clusters",
    "--clusters", $ClusterName,
    "--region", $Region,
    "--query", "clusters[0]",
    "--output", "json"
)
$Cluster = $ClusterOutput | ConvertFrom-Json

if ($null -eq $Cluster -or $Cluster.status -ne "ACTIVE") {
    Write-Output "Creating ECS cluster: $ClusterName"
    $ClusterOutput = Invoke-AwsCli @(
        "ecs", "create-cluster",
        "--cluster-name", $ClusterName,
        "--settings", "name=containerInsights,value=enabled",
        "--region", $Region,
        "--query", "cluster",
        "--output", "json"
    )
    $Cluster = $ClusterOutput | ConvertFrom-Json
} else {
    Write-Output "ECS cluster already exists: $ClusterName"
}

Write-Output "=== Objective 4 complete ==="
Write-Output ("Cluster name: {0}" -f $Cluster.clusterName)
Write-Output ("Cluster ARN: {0}" -f $Cluster.clusterArn)
Write-Output ("Status: {0}" -f $Cluster.status)
