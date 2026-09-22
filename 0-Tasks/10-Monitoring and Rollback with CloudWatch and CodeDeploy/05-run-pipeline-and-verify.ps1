[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$PipelineName = "cmtr-msdta2zd-codepipeline",
    [string]$Prefix = "cmtr-msdta2zd",
    [int]$TimeoutMinutes = 12
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

function Invoke-AwsOptional {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = @(& aws @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output | Out-String).Trim() }
}

Write-Output "=== Confirm AWS identity ==="
Invoke-Aws @("sts", "get-caller-identity", "--query", "{Account:Account,Arn:Arn}", "--output", "table") | Out-Host

Write-Output "=== Start pipeline execution ==="
$execution = Invoke-Aws @("codepipeline", "start-pipeline-execution", "--name", $PipelineName, "--region", $Region, "--output", "json") | ConvertFrom-Json
$executionId = $execution.pipelineExecutionId
Write-Output "Pipeline execution: $executionId"

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    $statusQuery = Invoke-AwsOptional @("codepipeline", "get-pipeline-execution", "--pipeline-name", $PipelineName, "--pipeline-execution-id", $executionId, "--region", $Region, "--query", "pipelineExecution.status", "--output", "text")
    if ($statusQuery.ExitCode -ne 0) {
        Write-Warning "Temporary CodePipeline status query failure: $($statusQuery.Output)"
        Start-Sleep -Seconds 15
        continue
    }
    $status = $statusQuery.Output.Trim()
    Write-Output "Pipeline status: $status"
    if ($status -in @("Succeeded", "Failed", "Stopped", "Superseded")) { break }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)

if ($status -ne "Succeeded") {
    Invoke-Aws @("codepipeline", "get-pipeline-state", "--name", $PipelineName, "--region", $Region, "--query", "stageStates[].{Stage:stageName,Status:latestExecution.status,Summary:latestExecution.summary}", "--output", "table") | Out-Host
    throw "Pipeline execution $executionId ended with status $status."
}

Write-Output "=== Run monitoring and rollback verification ==="
$applicationName = "$Prefix-codedeploy-application"
$deploymentGroupName = "$Prefix-codedeploy-deployment-group"
$serviceRoleArn = (Invoke-Aws @(
    "deploy", "get-deployment-group", "--application-name", $applicationName,
    "--deployment-group-name", $deploymentGroupName, "--region", $Region,
    "--query", "deploymentGroupInfo.serviceRoleArn", "--output", "text"
)).Trim()
Invoke-Aws @(
    "deploy", "update-deployment-group", "--application-name", $applicationName,
    "--current-deployment-group-name", $deploymentGroupName, "--service-role-arn", $serviceRoleArn,
    "--alarm-configuration", "enabled=true,ignorePollAlarmFailure=false,alarms=[{name=ALBUnhealthy}]",
    "--auto-rollback-configuration", "enabled=true,events=[DEPLOYMENT_FAILURE,DEPLOYMENT_STOP_ON_ALARM,DEPLOYMENT_STOP_ON_REQUEST]",
    "--region", $Region
) | Out-Null
& (Join-Path $PSScriptRoot "03-verify-monitoring-rollback.ps1") -Region $Region -Prefix $Prefix
