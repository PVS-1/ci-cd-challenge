[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
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

    return ($output | Out-String).Trim()
}

Write-Output "=== Target group health-check configuration ==="
$targetGroup = Invoke-Aws @(
    "elbv2", "describe-target-groups", "--names", "$Prefix-target-group", "--region", $Region,
    "--query", "TargetGroups[0].{Arn:TargetGroupArn,Port:Port,Protocol:Protocol,HealthCheckPort:HealthCheckPort,HealthCheckProtocol:HealthCheckProtocol,HealthCheckPath:HealthCheckPath,Matcher:Matcher.HttpCode}", "--output", "json"
) | ConvertFrom-Json
$targetGroup | ConvertTo-Json -Depth 4 | Write-Output

Write-Output "=== Registered target health ==="
Invoke-Aws @(
    "elbv2", "describe-target-health", "--target-group-arn", $targetGroup.Arn, "--region", $Region,
    "--query", "TargetHealthDescriptions[].{Instance:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}", "--output", "table"
) | Out-Host

Write-Output "=== Load balancer listener ports ==="
$loadBalancerArn = (Invoke-Aws @("elbv2", "describe-load-balancers", "--names", "$Prefix-alb", "--region", $Region, "--query", "LoadBalancers[0].LoadBalancerArn", "--output", "text")).Trim()
Invoke-Aws @(
    "elbv2", "describe-listeners", "--load-balancer-arn", $loadBalancerArn, "--region", $Region,
    "--query", "Listeners[].{Port:Port,Protocol:Protocol,DefaultActions:DefaultActions[].Type}", "--output", "table"
) | Out-Host
