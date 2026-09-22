[CmdletBinding()]
param(
    [string]$PrimaryRegion = "us-east-1",
    [string]$SecondaryRegion = "eu-west-1",
    [string]$Prefix = "cmtr-msdta2zd"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& aws @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed: aws $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }

    return ($output | Out-String)
}

function Get-VpcByName {
    param(
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Invoke-Aws @(
        "ec2", "describe-vpcs",
        "--filters", "Name=tag:Name,Values=$Name",
        "--region", $Region,
        "--query", "Vpcs[].VpcId",
        "--output", "text"
    )
}

Write-Output "=== 1. Confirm AWS identity ==="
Invoke-Aws @("sts", "get-caller-identity", "--output", "json") | Out-Host

Write-Output "=== 2. Confirm CodeCommit source ==="
Invoke-Aws @(
    "codecommit", "get-repository",
    "--repository-name", "$Prefix-repo",
    "--region", $PrimaryRegion,
    "--query", "repositoryMetadata.{Name:repositoryName,Arn:Arn,DefaultBranch:defaultBranch}",
    "--output", "table"
) | Out-Host
Invoke-Aws @(
    "codecommit", "get-branch",
    "--repository-name", "$Prefix-repo",
    "--branch-name", "main",
    "--region", $PrimaryRegion,
    "--query", "branch.commitId",
    "--output", "text"
) | Out-Host

Write-Output "=== 3. Confirm primary regional infrastructure ==="
Get-VpcByName -Region $PrimaryRegion -Name "$Prefix-vpc-us-east-1" | ForEach-Object { Write-Output "VPC: $_" }
Invoke-Aws @("elbv2", "describe-load-balancers", "--names", "$Prefix-alb-us-east-1", "--region", $PrimaryRegion, "--query", "LoadBalancers[0].{Arn:LoadBalancerArn,Dns:DNSName,State:State.Code}", "--output", "table") | Out-Host
Invoke-Aws @("autoscaling", "describe-auto-scaling-groups", "--auto-scaling-group-names", "$Prefix-asg-blue-us-east-1", "--region", $PrimaryRegion, "--query", "AutoScalingGroups[0].{Name:AutoScalingGroupName,Desired:DesiredCapacity,Instances:length(Instances)}", "--output", "table") | Out-Host

Write-Output "=== 4. Confirm secondary regional infrastructure ==="
Get-VpcByName -Region $SecondaryRegion -Name "$Prefix-vpc-eu-west-1" | ForEach-Object { Write-Output "VPC: $_" }
Invoke-Aws @("elbv2", "describe-load-balancers", "--names", "$Prefix-alb-eu-west-1", "--region", $SecondaryRegion, "--query", "LoadBalancers[0].{Arn:LoadBalancerArn,Dns:DNSName,State:State.Code}", "--output", "table") | Out-Host
Invoke-Aws @("autoscaling", "describe-auto-scaling-groups", "--auto-scaling-group-names", "$Prefix-asg-blue-eu-west-1", "--region", $SecondaryRegion, "--query", "AutoScalingGroups[0].{Name:AutoScalingGroupName,Desired:DesiredCapacity,Instances:length(Instances)}", "--output", "table") | Out-Host

Write-Output "=== 5. Confirm test instance ==="
Invoke-Aws @(
    "ec2", "describe-instances",
    "--filters", "Name=tag:Name,Values=$Prefix-test-us-east-1", "Name=instance-state-name,Values=running",
    "--region", $PrimaryRegion,
    "--query", "Reservations[].Instances[].{Id:InstanceId,State:State.Name,PrivateIp:PrivateIpAddress}",
    "--output", "table"
) | Out-Host

Write-Output "Prerequisite discovery complete. Do not create deployment resources until every required item above is present."