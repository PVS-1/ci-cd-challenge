[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PipelineExecutionId,
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

$pipelineName = "$Prefix-codepipeline"
$applicationName = "$Prefix-codedeploy-application"
$deploymentGroupName = "$Prefix-codedeploy-deployment-group"

Write-Output "=== CodePipeline deploy action details ==="
$actions = Invoke-Aws @(
    "codepipeline", "list-action-executions", "--pipeline-name", $pipelineName,
    "--filter", "pipelineExecutionId=$PipelineExecutionId", "--max-results", "100", "--region", $Region, "--output", "json"
) | ConvertFrom-Json
$actions.actionExecutionDetails | Where-Object { $_.stageName -eq "Deploy" } | ForEach-Object {
    [pscustomobject]@{
        Action = $_.actionName
        Status = $_.status
        ErrorCode = $_.errorDetails.code
        ErrorMessage = $_.errorDetails.message
        DeploymentId = $_.output.executionResult.externalExecutionId
    }
} | Format-Table -AutoSize | Out-Host

Write-Output "=== CloudWatch alarm state ==="
Invoke-Aws @("cloudwatch", "describe-alarms", "--alarm-names", "ALBUnhealthy", "--region", $Region, "--query", "MetricAlarms[0].{State:StateValue,Reason:StateReason,Updated:StateUpdatedTimestamp}", "--output", "table") | Out-Host

Write-Output "=== Latest CodeDeploy deployment ==="
$deploymentGroup = Invoke-Aws @(
    "deploy", "get-deployment-group", "--application-name", $applicationName,
    "--deployment-group-name", $deploymentGroupName, "--region", $Region,
    "--query", "deploymentGroupInfo.{AlarmEnabled:alarmConfiguration.enabled,AlarmNames:alarmConfiguration.alarms[].name,RollbackEnabled:autoRollbackConfiguration.enabled,RollbackEvents:autoRollbackConfiguration.events}", "--output", "json"
) | ConvertFrom-Json
$deploymentGroup | ConvertTo-Json -Depth 4 | Write-Output
$deploymentId = (Invoke-Aws @(
    "deploy", "list-deployments", "--application-name", $applicationName,
    "--deployment-group-name", $deploymentGroupName, "--region", $Region,
    "--query", "deployments[0]", "--output", "text"
)).Trim()
if ([string]::IsNullOrWhiteSpace($deploymentId) -or $deploymentId -eq "None") {
    Write-Output "No CodeDeploy deployment was created for $deploymentGroupName. Review the CodePipeline Deploy action error above."
    return
}
Invoke-Aws @("deploy", "get-deployment", "--deployment-id", $deploymentId, "--region", $Region, "--query", "deploymentInfo.{Id:deploymentId,Status:status,ErrorCode:errorInformation.code,ErrorMessage:errorInformation.message,Overview:deploymentOverview}", "--output", "json") | Out-Host

Write-Output "=== Failed lifecycle events by target ==="
$targetIds = (Invoke-Aws @("deploy", "list-deployment-targets", "--deployment-id", $deploymentId, "--region", $Region, "--query", "targetIds", "--output", "text")).Trim() -split "\s+"
foreach ($targetId in $targetIds | Where-Object { $_ }) {
    $target = Invoke-Aws @("deploy", "get-deployment-target", "--deployment-id", $deploymentId, "--target-id", $targetId, "--region", $Region, "--output", "json") | ConvertFrom-Json
    $instanceTarget = $target.deploymentTarget.instanceTarget
    [pscustomobject]@{
        Target = $instanceTarget.targetId
        Status = $instanceTarget.status
        FailedEvents = @($instanceTarget.lifecycleEvents | Where-Object { $_.status -eq "Failed" } | ForEach-Object {
            "$($_.lifecycleEventName): $($_.diagnostics.errorCode) $($_.diagnostics.message)"
        }) -join "; "
    } | Format-List | Out-Host
}
