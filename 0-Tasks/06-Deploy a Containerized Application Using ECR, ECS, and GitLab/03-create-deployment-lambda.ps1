[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$FunctionName = "cmtr-msdta2zd-function",
    [string]$LambdaRoleName = "cmtr-msdta2zd-lambda-role",
    [string]$EcrRepository = "cmtr-msdta2zd-static",
    [string]$EcsCluster = "cmtr-msdta2zd-cluster",
    [string]$EcsService = "cmtr-msdta2zd-service",
    [string]$EcsTaskDefinition = "cmtr-msdta2zd-task",
    [string]$ContainerName = "web"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("ecs-deploy-lambda-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

function Test-AwsResource {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & aws @Arguments 1>$null 2>$null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    return $exitCode -eq 0
}

try {
    Write-Output "=== 1. Verify AWS identity and ECS cluster ==="
    $AccountId = ([string](Invoke-AwsCli @(
        "sts", "get-caller-identity",
        "--query", "Account",
        "--output", "text"
    ))).Trim()
    $EcrRepositoryUri = "$AccountId.dkr.ecr.$Region.amazonaws.com/$EcrRepository"

    Invoke-AwsCli @(
        "ecs", "describe-clusters",
        "--clusters", $EcsCluster,
        "--region", $Region,
        "--query", "clusters[0].{Name:clusterName,Status:status,Arn:clusterArn}",
        "--output", "json"
    ) | Out-Host

    Write-Output "=== 2. Create or verify Lambda execution role ==="
    $RoleArn = "arn:aws:iam::${AccountId}:role/${LambdaRoleName}"
    $TrustPolicyPath = Join-Path $TempDirectory "lambda-trust.json"
    $TrustPolicy = @'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
'@
    [System.IO.File]::WriteAllText($TrustPolicyPath, $TrustPolicy, $Utf8NoBom)

    if (-not (Test-AwsResource @("iam", "get-role", "--role-name", $LambdaRoleName))) {
        Invoke-AwsCli @(
            "iam", "create-role",
            "--role-name", $LambdaRoleName,
            "--assume-role-policy-document", "file://$TrustPolicyPath"
        ) | Out-Host
    } else {
        Write-Output "Lambda role already exists: $LambdaRoleName"
    }

    Invoke-AwsCli @(
        "iam", "attach-role-policy",
        "--role-name", $LambdaRoleName,
        "--policy-arn", "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
    ) | Out-Host

    $DeploymentPolicyPath = Join-Path $TempDirectory "lambda-deployment-policy.json"
    $DeploymentPolicy = @{
        Version = "2012-10-17"
        Statement = @(
            @{
                Effect = "Allow"
                Action = @("ecr:DescribeImages", "ecr:BatchGetImage")
                Resource = "arn:aws:ecr:${Region}:${AccountId}:repository/${EcrRepository}"
            },
            @{
                Effect = "Allow"
                Action = @("ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition", "ecs:UpdateService")
                Resource = "*"
            },
            @{
                Effect = "Allow"
                Action = "iam:PassRole"
                Resource = "*"
            }
        )
    } | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($DeploymentPolicyPath, $DeploymentPolicy, $Utf8NoBom)
    Invoke-AwsCli @(
        "iam", "put-role-policy",
        "--role-name", $LambdaRoleName,
        "--policy-name", "EcsImageDeployment",
        "--policy-document", "file://$DeploymentPolicyPath"
    ) | Out-Host

    Write-Output "=== 3. Create Lambda source package ==="
    $LambdaSourcePath = Join-Path $TempDirectory "lambda_function.py"
    $LambdaZipPath = Join-Path $TempDirectory "lambda.zip"
    $LambdaSource = @'
import json
import os

import boto3


ecr = boto3.client("ecr")
ecs = boto3.client("ecs")


def lambda_handler(event, context):
    repository = os.environ["ECR_REPOSITORY"]
    cluster = os.environ["ECS_CLUSTER"]
    service = os.environ["ECS_SERVICE"]
    task_definition = os.environ["ECS_TASK_DEFINITION"]
    container_name = os.environ["CONTAINER_NAME"]

    detail = event.get("detail", {})
    image_tag = detail.get("image-tag", "latest")
    image_digest = detail.get("image-digest")
    image_uri = f"{repository}:{image_tag}"

    if image_digest:
        image_uri = f"{repository}@{image_digest}"

    current = ecs.describe_task_definition(taskDefinition=task_definition)
    task = current["taskDefinition"]
    containers = task["containerDefinitions"]

    for container in containers:
        if container["name"] == container_name:
            container["image"] = image_uri

    register_args = {
        "family": task["family"],
        "taskRoleArn": task.get("taskRoleArn"),
        "executionRoleArn": task.get("executionRoleArn"),
        "networkMode": task.get("networkMode"),
        "containerDefinitions": containers,
        "volumes": task.get("volumes", []),
        "placementConstraints": task.get("placementConstraints", []),
        "requiresCompatibilities": task.get("requiresCompatibilities", ["FARGATE"]),
        "cpu": task.get("cpu"),
        "memory": task.get("memory"),
    }
    register_args = {key: value for key, value in register_args.items() if value is not None}
    registered = ecs.register_task_definition(**register_args)
    revision = registered["taskDefinition"]["taskDefinitionArn"]

    updated = ecs.update_service(
        cluster=cluster,
        service=service,
        taskDefinition=revision,
        forceNewDeployment=True,
    )

    return {
        "statusCode": 200,
        "body": json.dumps({"message": "Service updated successfully", "taskDefinition": revision, "image": image_uri}),
    }
'@
    [System.IO.File]::WriteAllText($LambdaSourcePath, $LambdaSource, $Utf8NoBom)
    Compress-Archive -Path $LambdaSourcePath -DestinationPath $LambdaZipPath -Force

    $EnvironmentVariables = "Variables={ECR_REPOSITORY=$EcrRepositoryUri,ECS_CLUSTER=$EcsCluster,ECS_SERVICE=$EcsService,ECS_TASK_DEFINITION=$EcsTaskDefinition,CONTAINER_NAME=$ContainerName}"
    Write-Output "=== 4. Create or update Lambda function ==="
    if (Test-AwsResource @("lambda", "get-function", "--function-name", $FunctionName, "--region", $Region)) {
        Invoke-AwsCli @(
            "lambda", "update-function-code",
            "--function-name", $FunctionName,
            "--zip-file", "fileb://$LambdaZipPath",
            "--region", $Region
        ) | Out-Host
        Invoke-AwsCli @(
            "lambda", "update-function-configuration",
            "--function-name", $FunctionName,
            "--role", $RoleArn,
            "--runtime", "python3.12",
            "--handler", "lambda_function.lambda_handler",
            "--timeout", "60",
            "--environment", $EnvironmentVariables,
            "--region", $Region
        ) | Out-Host
    } else {
        Invoke-AwsCli @(
            "lambda", "create-function",
            "--function-name", $FunctionName,
            "--runtime", "python3.12",
            "--role", $RoleArn,
            "--handler", "lambda_function.lambda_handler",
            "--timeout", "60",
            "--environment", $EnvironmentVariables,
            "--zip-file", "fileb://$LambdaZipPath",
            "--region", $Region
        ) | Out-Host
    }

    Write-Output "Objective 5 complete. Lambda function configured: $FunctionName"
}
finally {
    Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
