[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$RepositoryName = "cmtr-msdta2zd-repo",
    [string]$PipelineName = "cmtr-msdta2zd-pipeline",
    [string]$BuildProjectName = "cmtr-msdta2zd-codebuild",
    [string]$RoleName = "cmtr-msdta2zd-codebuild-role",
    [string]$StackName = "cmtr-msdta2zd-r53-stack",
    [string]$TestInstanceName = "cmtr-msdta2zd-ec2-test"
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

Write-Output "=== 1. Confirm AWS session ==="
Invoke-Aws @("sts", "get-caller-identity", "--output", "json") | Out-Host

Write-Output "=== 2. Confirm CodeCommit deployment files ==="
foreach ($fileName in @("template.yml", "buildspec.yml")) {
    Invoke-Aws @(
        "codecommit", "get-file",
        "--repository-name", $RepositoryName,
        "--commit-specifier", "main",
        "--file-path", $fileName,
        "--query", "commitId",
        "--output", "text",
        "--region", $Region
    ) | ForEach-Object { Write-Output "$fileName found at commit $($_.Trim())" }
}

Write-Output "=== 3. Confirm pipeline and latest build ==="
Invoke-Aws @(
    "codepipeline", "get-pipeline-state",
    "--name", $PipelineName,
    "--region", $Region,
    "--query", "stageStates[].{Stage:stageName,Status:latestExecution.status,ExecutionId:latestExecution.pipelineExecutionId}",
    "--output", "table"
) | Out-Host

$latestBuildId = (Invoke-Aws @(
    "codebuild", "list-builds-for-project",
    "--project-name", $BuildProjectName,
    "--region", $Region,
    "--sort-order", "DESCENDING",
    "--query", "ids[0]",
    "--output", "text"
)).Trim()
Invoke-Aws @(
    "codebuild", "batch-get-builds",
    "--ids", $latestBuildId,
    "--region", $Region,
    "--query", "builds[0].{Id:id,Status:buildStatus,Started:startTime,Completed:endTime}",
    "--output", "table"
) | Out-Host

Write-Output "=== 4. Confirm CodeBuild role is not AdministratorAccess ==="
$attachedPolicies = Invoke-Aws @(
    "iam", "list-attached-role-policies",
    "--role-name", $RoleName,
    "--query", "AttachedPolicies[].PolicyName",
    "--output", "text"
)
if ($attachedPolicies -match "AdministratorAccess") {
    throw "CodeBuild role $RoleName has AdministratorAccess attached."
}
Write-Output "PASS: $RoleName does not have AdministratorAccess attached."

Write-Output "=== 5. Confirm CloudFormation stack ==="
$stack = Invoke-Aws @(
    "cloudformation", "describe-stacks",
    "--stack-name", $StackName,
    "--region", $Region,
    "--query", "Stacks[0].{Status:StackStatus,Outputs:Outputs}",
    "--output", "json"
) | ConvertFrom-Json
if ($stack.Status -in @("CREATE_IN_PROGRESS", "UPDATE_IN_PROGRESS")) {
    Write-Output "Deployment is still in progress: $StackName is $($stack.Status). Re-run this verifier after CodeBuild completes."
    return
}
if ($stack.Status -notin @("CREATE_COMPLETE", "UPDATE_COMPLETE")) {
    Invoke-Aws @(
        "cloudformation", "describe-stack-events",
        "--stack-name", $StackName,
        "--region", $Region,
        "--query", "StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`DELETE_FAILED`].{LogicalId:LogicalResourceId,Status:ResourceStatus,Reason:ResourceStatusReason}",
        "--output", "table"
    ) | Out-Host
    throw "Stack $StackName is $($stack.Status), not a complete state."
}
$hostedZoneId = ($stack.Outputs | Where-Object OutputKey -eq "HostedZoneId" | Select-Object -ExpandProperty OutputValue -First 1)
$applicationRecordName = ($stack.Outputs | Where-Object OutputKey -eq "ApplicationRecordName" | Select-Object -ExpandProperty OutputValue -First 1)
Write-Output "PASS: $StackName is $($stack.Status); hosted zone is $hostedZoneId."

Write-Output "=== 6. Confirm Route 53 failover records ==="
$records = Invoke-Aws @(
    "route53", "list-resource-record-sets",
    "--hosted-zone-id", $hostedZoneId,
    "--query", "ResourceRecordSets[?Failover!=null].{Name:Name,Failover:Failover,Value:ResourceRecords[0].Value,HealthCheckId:HealthCheckId}",
    "--output", "json"
) | ConvertFrom-Json
$normalizedRecordName = $applicationRecordName.TrimEnd('.')
$applicationRecords = $records | Where-Object { $_.Name.TrimEnd('.') -eq $normalizedRecordName }
$primaryRecord = $applicationRecords | Where-Object Failover -eq "PRIMARY"
$secondaryRecord = $applicationRecords | Where-Object Failover -eq "SECONDARY"
if ($null -eq $primaryRecord -or $null -eq $secondaryRecord -or [string]::IsNullOrWhiteSpace($primaryRecord.HealthCheckId)) {
    throw "Expected PRIMARY and SECONDARY records, with a health check on PRIMARY, were not found."
}
$applicationRecords | Format-Table -AutoSize | Out-Host

Write-Output "=== 7. Confirm private DNS resolution from test instance ==="
$instanceId = (Invoke-Aws @(
    "ec2", "describe-instances",
    "--filters", "Name=tag:Name,Values=$TestInstanceName", "Name=instance-state-name,Values=running",
    "--region", $Region,
    "--query", "Reservations[0].Instances[0].InstanceId",
    "--output", "text"
)).Trim()
if ([string]::IsNullOrWhiteSpace($instanceId) -or $instanceId -eq "None") {
    throw "Running test instance $TestInstanceName was not found."
}

$commandId = (Invoke-Aws @(
    "ssm", "send-command",
    "--instance-ids", $instanceId,
    "--document-name", "AWS-RunShellScript",
    "--parameters", "commands=dig +short $applicationRecordName",
    "--region", $Region,
    "--query", "Command.CommandId",
    "--output", "text"
)).Trim()
Invoke-Aws @(
    "ssm", "wait", "command-executed",
    "--command-id", $commandId,
    "--instance-id", $instanceId,
    "--region", $Region
) | Out-Null
$dnsAnswer = (Invoke-Aws @(
    "ssm", "get-command-invocation",
    "--command-id", $commandId,
    "--instance-id", $instanceId,
    "--region", $Region,
    "--query", "StandardOutputContent",
    "--output", "text"
)).Trim()
if ($dnsAnswer -ne $primaryRecord.Value) {
    throw "DNS returned '$dnsAnswer'; expected primary IP '$($primaryRecord.Value)'."
}
Write-Output "PASS: $applicationRecordName resolves to primary IP $dnsAnswer from $instanceId."
Write-Output "All final verification checks passed. The task is ready to submit."