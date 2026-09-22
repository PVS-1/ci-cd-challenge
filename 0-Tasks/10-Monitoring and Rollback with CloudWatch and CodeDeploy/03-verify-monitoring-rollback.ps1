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

Write-Output "=== Confirm AWS identity ==="
Invoke-Aws @("sts", "get-caller-identity", "--query", "{Account:Account,Arn:Arn}", "--output", "table") | Out-Host

$pipelineName = "$Prefix-codepipeline"
$applicationName = "$Prefix-codedeploy-application"
$deploymentGroupName = "$Prefix-codedeploy-deployment-group"

Write-Output "=== Verify pipeline ==="
Invoke-Aws @(
    "codepipeline", "get-pipeline-state", "--name", $pipelineName, "--region", $Region,
    "--query", "stageStates[].{Stage:stageName,Status:latestExecution.status,Summary:latestExecution.summary}", "--output", "table"
) | Out-Host

Write-Output "=== Verify CodeDeploy alarm rollback configuration ==="
$deploymentGroup = Invoke-Aws @(
    "deploy", "get-deployment-group", "--application-name", $applicationName,
    "--deployment-group-name", $deploymentGroupName, "--region", $Region, "--output", "json"
) | ConvertFrom-Json
$alarmConfiguration = $deploymentGroup.deploymentGroupInfo.alarmConfiguration
$rollbackConfiguration = $deploymentGroup.deploymentGroupInfo.autoRollbackConfiguration
if (-not $alarmConfiguration.enabled -or $alarmConfiguration.alarms.name -notcontains "ALBUnhealthy") {
    throw "CodeDeploy deployment group does not have enabled ALBUnhealthy alarm monitoring."
}
if (-not $rollbackConfiguration.enabled -or $rollbackConfiguration.events -notcontains "DEPLOYMENT_STOP_ON_ALARM") {
    throw "CodeDeploy deployment group does not roll back when the alarm triggers."
}
Write-Output "PASS: CodeDeploy monitors ALBUnhealthy and has rollback on alarm enabled."

Write-Output "=== Verify CloudWatch alarm ==="
$alarm = Invoke-Aws @(
    "cloudwatch", "describe-alarms", "--alarm-names", "ALBUnhealthy", "--region", $Region,
    "--query", "MetricAlarms[0].{State:StateValue,Metric:MetricName,Namespace:Namespace,Threshold:Threshold,EvaluationPeriods:EvaluationPeriods,Dimensions:Dimensions}", "--output", "json"
) | ConvertFrom-Json
if ($alarm.Metric -ne "UnHealthyHostCount" -or $alarm.Namespace -ne "AWS/ApplicationELB") {
    throw "ALBUnhealthy is not monitoring Application Load Balancer unhealthy hosts."
}
$alarm | ConvertTo-Json -Depth 5 | Write-Output

Write-Output "=== Verify ALB target health ==="
$loadBalancer = Invoke-Aws @("elbv2", "describe-load-balancers", "--names", "$Prefix-alb", "--region", $Region, "--output", "json") | ConvertFrom-Json
$dnsName = $loadBalancer.LoadBalancers[0].DNSName
$targetHealth = Invoke-Aws @(
    "elbv2", "describe-target-health", "--target-group-arn",
    (Invoke-Aws @("elbv2", "describe-target-groups", "--names", "$Prefix-target-group", "--region", $Region, "--query", "TargetGroups[0].TargetGroupArn", "--output", "text")).Trim(),
    "--region", $Region, "--query", "TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}", "--output", "table"
)
$targetHealth | Out-Host

Write-Output "=== Verify application through ALB ==="
$response = Invoke-WebRequest -Uri "http://$dnsName/" -UseBasicParsing -TimeoutSec 20
if ($response.StatusCode -ne 200 -or $response.Content -notmatch "Hello from the environment msdta2zd!") {
    throw "ALB response did not contain the required application text."
}
Write-Output "PASS: http://$dnsName/ returned the required application text."

Write-Output "All monitoring and rollback verification checks passed."
