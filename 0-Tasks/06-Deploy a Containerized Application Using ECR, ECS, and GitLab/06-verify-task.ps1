[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$EcrRepository = "cmtr-msdta2zd-static",
    [string]$EcsCluster = "cmtr-msdta2zd-cluster",
    [string]$EcsService = "cmtr-msdta2zd-service",
    [string]$EcsTaskDefinition = "cmtr-msdta2zd-task",
    [string]$LambdaFunction = "cmtr-msdta2zd-function",
    [string]$EventBridgeRule = "cmtr-msdta2zd-rule"
)

$ErrorActionPreference = "Continue"
$env:AWS_PAGER = ""
$Failures = 0

function Invoke-Check {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Output "=== $Name ==="
    $output = @(& aws @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Output "FAIL: $($output -join ' ')"
        $script:Failures++
        return $null
    }

    $text = $output -join [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        try {
            $text | ConvertFrom-Json | ConvertTo-Json -Depth 12
        } catch {
            Write-Output $text
        }
    }
    return $text
}

Invoke-Check "AWS identity" @(
    "sts", "get-caller-identity",
    "--query", "{Account:Account,Arn:Arn}",
    "--output", "json"
)

Invoke-Check "ECR repository" @(
    "ecr", "describe-repositories",
    "--repository-names", $EcrRepository,
    "--region", $Region,
    "--query", "repositories[0].{Name:repositoryName,Uri:repositoryUri,ScanOnPush:imageScanningConfiguration.scanOnPush}",
    "--output", "json"
)

Invoke-Check "ECR images" @(
    "ecr", "describe-images",
    "--repository-name", $EcrRepository,
    "--region", $Region,
    "--query", "imageDetails[].{Tags:imageTags,Digest:imageDigest,PushedAt:imagePushedAt}",
    "--output", "json"
)

Invoke-Check "ECS cluster" @(
    "ecs", "describe-clusters",
    "--clusters", $EcsCluster,
    "--region", $Region,
    "--query", "clusters[0].{Name:clusterName,Status:status,RunningTasks:runningTasksCount,ActiveServices:activeServicesCount}",
    "--output", "json"
)

Invoke-Check "ECS service" @(
    "ecs", "describe-services",
    "--cluster", $EcsCluster,
    "--services", $EcsService,
    "--region", $Region,
    "--query", "services[0].{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount,TaskDefinition:taskDefinition}",
    "--output", "json"
)

Invoke-Check "ECS task definition" @(
    "ecs", "describe-task-definition",
    "--task-definition", $EcsTaskDefinition,
    "--region", $Region,
    "--query", "taskDefinition.{Family:family,Revision:revision,Status:status,Image:containerDefinitions[0].image,ExecutionRole:executionRoleArn}",
    "--output", "json"
)

Write-Output "=== ECS running tasks ==="
$TaskArnOutput = @(& aws ecs list-tasks `
    --cluster $EcsCluster `
    --service-name $EcsService `
    --desired-status RUNNING `
    --region $Region `
    --query "taskArns[0]" `
    --output text 2>&1)
$TaskListExitCode = $LASTEXITCODE

if ($TaskListExitCode -ne 0) {
    Write-Output "FAIL: $($TaskArnOutput -join ' ')"
    $Failures++
} else {
    $TaskArn = ($TaskArnOutput -join "").Trim()
    if ([string]::IsNullOrWhiteSpace($TaskArn) -or $TaskArn -eq "None") {
        Write-Output "FAIL: ECS returned no task list."
        $Failures++
    } else {
        Write-Output "Running task: $TaskArn"
        Invoke-Check "ECS running task details" @(
            "ecs", "describe-tasks",
            "--cluster", $EcsCluster,
            "--tasks", $TaskArn,
            "--region", $Region,
            "--query", "tasks[].{Arn:taskArn,LastStatus:lastStatus,Health:healthStatus,TaskDefinition:taskDefinitionArn,Attachments:attachments}",
            "--output", "json"
        )
    }
}

Invoke-Check "Lambda function" @(
    "lambda", "get-function",
    "--function-name", $LambdaFunction,
    "--region", $Region,
    "--query", "Configuration.{Name:FunctionName,State:State,Runtime:Runtime,Role:Role,LastModified:LastModified}",
    "--output", "json"
)

Invoke-Check "EventBridge rule" @(
    "events", "describe-rule",
    "--name", $EventBridgeRule,
    "--region", $Region,
    "--query", "{Name:Name,State:State,Arn:Arn,EventPattern:EventPattern}",
    "--output", "json"
)

Invoke-Check "EventBridge Lambda targets" @(
    "events", "list-targets-by-rule",
    "--rule", $EventBridgeRule,
    "--region", $Region,
    "--query", "Targets[].Arn",
    "--output", "json"
)

Write-Output "=== Verification summary ==="
if ($Failures -eq 0) {
    Write-Output "PASS: all AWS checks completed without CLI errors."
    exit 0
}

Write-Output "FAIL: $Failures check(s) failed."
exit 1
