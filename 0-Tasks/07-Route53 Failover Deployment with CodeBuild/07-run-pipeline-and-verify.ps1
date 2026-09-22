[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$PipelineName = "cmtr-msdta2zd-pipeline",
    [string]$StackName = "cmtr-msdta2zd-r53-stack"
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

Write-Output "=== 1. Start CodePipeline execution ==="
$Execution = (Invoke-Aws @(
    "codepipeline", "start-pipeline-execution",
    "--name", $PipelineName,
    "--region", $Region,
    "--output", "json"
) | ConvertFrom-Json)
$ExecutionId = $Execution.pipelineExecutionId
Write-Output "Pipeline execution started: $ExecutionId"

Write-Output "=== 2. Read pipeline execution status ==="
$ExecutionStatus = (Invoke-Aws @(
    "codepipeline", "get-pipeline-execution",
    "--pipeline-name", $PipelineName,
    "--pipeline-execution-id", $ExecutionId,
    "--region", $Region,
    "--query", "pipelineExecution.status",
    "--output", "text"
)).Trim()
Write-Output "Pipeline execution status: $ExecutionStatus"

if ($ExecutionStatus -ne "Succeeded") {
    Write-Output "Pipeline is asynchronous. Re-run this script after CodePipeline reports Succeeded to verify the stack and Route 53 records."
    return
}

Write-Output "=== 3. Verify CloudFormation stack ==="
$Stack = (Invoke-Aws @(
    "cloudformation", "describe-stacks",
    "--stack-name", $StackName,
    "--region", $Region,
    "--query", "Stacks[0].{Name:StackName,Status:StackStatus,Outputs:Outputs}",
    "--output", "json"
) | ConvertFrom-Json)
$Stack | ConvertTo-Json -Depth 5

if ($Stack.Status -notin @("CREATE_COMPLETE", "UPDATE_COMPLETE")) {
    throw "Unexpected stack status: $($Stack.Status)"
}

$HostedZoneId = ($Stack.Outputs | Where-Object OutputKey -eq "HostedZoneId" | Select-Object -ExpandProperty OutputValue -First 1)
if ([string]::IsNullOrWhiteSpace($HostedZoneId)) {
    throw "HostedZoneId output is missing from stack $StackName"
}

Write-Output "=== 4. Verify Route 53 failover records ==="
Invoke-Aws @(
    "route53", "list-resource-record-sets",
    "--hosted-zone-id", $HostedZoneId,
    "--query", "ResourceRecordSets[?Failover!=null].{Name:Name,Type:Type,Failover:Failover,Value:ResourceRecords[0].Value,HealthCheckId:HealthCheckId}",
    "--output", "json"
) | Out-Host

Write-Output "Objective 6 complete. Pipeline succeeded and Route 53 failover stack is deployed."