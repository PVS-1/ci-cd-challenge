[CmdletBinding()]
param(
    [string]$Prefix = "cmtr-msdta2zd",
    [string]$PrimaryRegion = "us-east-1",
    [string]$SecondaryRegion = "eu-west-1",
    [string]$RepositoryName = "cmtr-msdta2zd-repo",
    [string]$EcrRepositoryName = "cmtr-msdta2zd-north-pole",
    [string]$CodeBuildProjectName = "cmtr-msdta2zd-docker-build",
    [string]$PipelineName = "cmtr-msdta2zd-cicd-pipeline",
    [int]$TimeoutMinutes = 25
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

function Get-HostedZoneId {
    param([string]$ZoneName)
    $zones = (Invoke-Aws @("route53", "list-hosted-zones-by-name", "--dns-name", "$ZoneName.", "--output", "json") | ConvertFrom-Json).HostedZones
    $zone = $zones | Where-Object { $_.Name.TrimEnd('.') -eq $ZoneName } | Select-Object -First 1
    if (-not $zone) { throw "Hosted zone $ZoneName was not found." }
    return ($zone.Id -replace ".*/", "")
}

function Wait-Command {
    param([string]$CommandId, [string]$InstanceId, [string]$Region)
    $deadline = (Get-Date).AddMinutes(3)
    do {
        $invocation = Invoke-Aws @("ssm", "get-command-invocation", "--command-id", $CommandId, "--instance-id", $InstanceId, "--region", $Region, "--output", "json") | ConvertFrom-Json
        if ($invocation.Status -in @("Success", "Failed", "TimedOut", "Cancelled")) { return $invocation }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    throw "SSM command $CommandId did not finish within three minutes."
}

function Show-DeploymentFailureDetails {
    param([string]$PipelineExecutionId)

    Write-Output "=== Deploy action failure details ==="
    $execution = Invoke-Aws @("codepipeline", "get-pipeline-execution", "--pipeline-name", $PipelineName, "--pipeline-execution-id", $PipelineExecutionId, "--region", $PrimaryRegion, "--output", "json") | ConvertFrom-Json
    $deployStage = $execution.pipelineExecution.stageStates | Where-Object { $_.stageName -eq "Deploy" } | Select-Object -First 1
    $deployStage.actionStates | ForEach-Object {
        [pscustomobject]@{
            Action = $_.actionName
            Status = $_.latestExecution.status
            ErrorCode = $_.latestExecution.errorDetails.code
            ErrorMessage = $_.latestExecution.errorDetails.message
            ExternalExecutionId = $_.latestExecution.externalExecutionId
        }
    } | Format-Table -AutoSize | Out-Host

    foreach ($deploymentRegion in @($PrimaryRegion, $SecondaryRegion)) {
        $suffix = if ($deploymentRegion -eq $PrimaryRegion) { "us-east-1" } else { "eu-west-1" }
        $applicationName = "$Prefix-app-$suffix"
        $deploymentGroupName = "$Prefix-dg-$suffix"
        $deploymentId = (Invoke-Aws @("deploy", "list-deployments", "--application-name", $applicationName, "--deployment-group-name", $deploymentGroupName, "--include-only-statuses", "Failed", "--region", $deploymentRegion, "--query", "deployments[0]", "--output", "text")).Trim()
        if ([string]::IsNullOrWhiteSpace($deploymentId) -or $deploymentId -eq "None") {
            Write-Output "No failed CodeDeploy deployment found for $suffix."
            continue
        }

        Write-Output "=== CodeDeploy failure: $suffix ($deploymentId) ==="
        Invoke-Aws @("deploy", "get-deployment", "--deployment-id", $deploymentId, "--region", $deploymentRegion, "--query", "deploymentInfo.{Status:status,ErrorCode:errorInformation.code,ErrorMessage:errorInformation.message,CreateTime:createTime,CompleteTime:completeTime}", "--output", "table") | Out-Host
        Invoke-Aws @("deploy", "list-deployment-targets", "--deployment-id", $deploymentId, "--region", $deploymentRegion, "--query", "targetIds", "--output", "text") | ForEach-Object {
            foreach ($targetId in ($_ -split "\s+" | Where-Object { $_ })) {
                Invoke-Aws @("deploy", "get-deployment-target", "--deployment-id", $deploymentId, "--target-id", $targetId, "--region", $deploymentRegion, "--query", "deploymentTarget.instanceTarget.{TargetId:targetId,Status:status,LastError:lastUpdatedAt,LifecycleEvents:lifecycleEvents[?status==`Failed`].{Event:lifecycleEventName,Diagnostics:diagnostics.message}}", "--output", "json") | Out-Host
            }
        }
    }
}

Write-Output "=== Confirm AWS identity ==="
Invoke-Aws @("sts", "get-caller-identity", "--query", "{Account:Account,Arn:Arn}", "--output", "table") | Out-Host

Write-Output "=== Start pipeline execution ==="
$execution = Invoke-Aws @("codepipeline", "start-pipeline-execution", "--name", $PipelineName, "--region", $PrimaryRegion, "--output", "json") | ConvertFrom-Json
$executionId = $execution.pipelineExecutionId
Write-Output "Pipeline execution: $executionId"

Write-Output "=== Wait for source, build, and both deploy actions ==="
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$status = "InProgress"
do {
    $status = (Invoke-Aws @("codepipeline", "get-pipeline-execution", "--pipeline-name", $PipelineName, "--pipeline-execution-id", $executionId, "--region", $PrimaryRegion, "--query", "pipelineExecution.status", "--output", "text")).Trim()
    Write-Output "Pipeline status: $status"
    if ($status -in @("Succeeded", "Failed", "Stopped", "Superseded")) { break }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)

if ($status -ne "Succeeded") {
    Invoke-Aws @("codepipeline", "get-pipeline-state", "--name", $PipelineName, "--region", $PrimaryRegion, "--query", "stageStates[].{Stage:stageName,Status:latestExecution.status,Summary:latestExecution.summary}", "--output", "table") | Out-Host
    Show-DeploymentFailureDetails -PipelineExecutionId $executionId
    throw "Pipeline execution $executionId ended with status $status."
}

Write-Output "=== Verify pipeline stages ==="
Invoke-Aws @("codepipeline", "get-pipeline-state", "--name", $PipelineName, "--region", $PrimaryRegion, "--query", "stageStates[].{Stage:stageName,Status:latestExecution.status,Execution:latestExecution.pipelineExecutionId}", "--output", "table") | Out-Host

Write-Output "=== Verify ECR image and artifact bucket versioning ==="
$images = (Invoke-Aws @("ecr", "list-images", "--repository-name", $EcrRepositoryName, "--region", $PrimaryRegion, "--query", "imageIds", "--output", "json") | ConvertFrom-Json)
if (-not $images -or $images.Count -eq 0) { throw "ECR repository $EcrRepositoryName has no images." }
$images | ConvertTo-Json -Depth 4 | Write-Output
foreach ($bucketRegion in @($PrimaryRegion, $SecondaryRegion)) {
    $bucket = "$Prefix-artifacts-$bucketRegion"
    $versioning = (Invoke-Aws @("s3api", "get-bucket-versioning", "--bucket", $bucket, "--region", $bucketRegion, "--query", "Status", "--output", "text")).Trim()
    if ($versioning -ne "Enabled") { throw "Versioning is not enabled on $bucket." }
    Write-Output "PASS: $bucket versioning is Enabled"
}

Write-Output "=== Verify IAM roles and policies ==="
foreach ($roleName in @("$Prefix-codebuild-role", "$Prefix-codedeploy-role", "$Prefix-pipeline-role")) {
    $role = Invoke-Aws @("iam", "get-role", "--role-name", $roleName, "--query", "Role.RoleName", "--output", "text").Trim()
    if ($role -ne $roleName) { throw "IAM role $roleName was not found." }
    $policies = Invoke-Aws @("iam", "list-attached-role-policies", "--role-name", $roleName, "--query", "AttachedPolicies[].PolicyName", "--output", "text")
    if ($policies -match "AdministratorAccess") { throw "$roleName has AdministratorAccess attached." }
    Write-Output "PASS: $roleName exists without AdministratorAccess"
}

Write-Output "=== Verify CodeDeploy blue green groups ==="
foreach ($deploymentRegion in @($PrimaryRegion, $SecondaryRegion)) {
    $suffix = if ($deploymentRegion -eq $PrimaryRegion) { "us-east-1" } else { "eu-west-1" }
    $group = Invoke-Aws @("deploy", "get-deployment-group", "--application-name", "$Prefix-app-$suffix", "--deployment-group-name", "$Prefix-dg-$suffix", "--region", $deploymentRegion, "--output", "json") | ConvertFrom-Json
    $deploymentType = [string]$group.deploymentGroup.deploymentStyle.deploymentType
    if (($deploymentType -replace "_", "") -ine "BLUEGREEN") { throw "CodeDeploy group $suffix has deployment type '$deploymentType', not blue/green." }
    if ($group.deploymentGroup.blueGreenDeploymentConfiguration.greenFleetProvisioningOption.action -ne "COPY_AUTO_SCALING_GROUP") { throw "CodeDeploy group $suffix does not copy the ASG." }
    Write-Output "PASS: $suffix CodeDeploy group is blue/green"
}

Write-Output "=== Verify Route 53 failover records and health checks ==="
$zoneName = "$Prefix-zone"
$hostedZoneId = Get-HostedZoneId -ZoneName $zoneName
$records = (Invoke-Aws @("route53", "list-resource-record-sets", "--hosted-zone-id", $hostedZoneId, "--query", "ResourceRecordSets[?Failover!=null]", "--output", "json") | ConvertFrom-Json)
$applicationRecords = @($records | Where-Object { $_.Name.TrimEnd('.') -eq "app.$zoneName" })
if ($applicationRecords.Count -ne 2) { throw "Expected two failover records for app.$zoneName, found $($applicationRecords.Count)." }
if (-not ($applicationRecords | Where-Object { $_.Failover -eq "PRIMARY" -and $_.HealthCheckId })) { throw "PRIMARY record or health check is missing." }
if (-not ($applicationRecords | Where-Object { $_.Failover -eq "SECONDARY" -and $_.HealthCheckId })) { throw "SECONDARY record or health check is missing." }
$applicationRecords | Select-Object Name, Failover, SetIdentifier, HealthCheckId | Format-Table -AutoSize | Out-Host

Write-Output "=== Verify application through test instance ==="
$testInstanceId = (Invoke-Aws @("ec2", "describe-instances", "--filters", "Name=tag:Name,Values=$Prefix-test-us-east-1", "Name=instance-state-name,Values=running", "--region", $PrimaryRegion, "--query", "Reservations[0].Instances[0].InstanceId", "--output", "text")).Trim()
if ([string]::IsNullOrWhiteSpace($testInstanceId) -or $testInstanceId -eq "None") { throw "Running test instance $Prefix-test-us-east-1 was not found." }
$commandText = "getent hosts app.$zoneName; curl --fail --silent http://app.$zoneName/health; curl --fail --silent http://app.$zoneName/"
$commandId = (Invoke-Aws @("ssm", "send-command", "--instance-ids", $testInstanceId, "--document-name", "AWS-RunShellScript", "--parameters", "commands=$commandText", "--region", $PrimaryRegion, "--query", "Command.CommandId", "--output", "text")).Trim()
$invocation = Wait-Command -CommandId $commandId -InstanceId $testInstanceId -Region $PrimaryRegion
$invocation.StandardOutputContent | Write-Output
if ($invocation.Status -ne "Success") { throw "Test instance verification failed: $($invocation.StandardErrorContent)" }
if ($invocation.StandardOutputContent -notmatch 'healthy' -or $invocation.StandardOutputContent -notmatch 'region') { throw "Application response did not contain health and region data." }

Write-Output "All non-destructive verification checks passed for pipeline execution $executionId."
