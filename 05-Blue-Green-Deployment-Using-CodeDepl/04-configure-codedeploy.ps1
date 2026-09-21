[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$CodeDeployServiceRoleName = "cmtr-msdta2zd-codedeploy-role",
    [string]$CodeDeployApplicationName = "cmtr-msdta2zd-app",
    [string]$DeploymentGroupName = "cmtr-msdta2zd-dg",
    [string]$AutoScalingGroupName = "cmtr-msdta2zd-asg",
    [string]$TargetGroupName = "cmtr-msdta2zd-tg"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("codedeploy-objective-4-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-AwsCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | Out-String).Trim()
        throw "AWS CLI command failed: aws $($Arguments -join ' ')`n$details"
    }

    return $output
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
    Write-Output "=== 1. Verify AWS identity and pre-created infrastructure ==="
    $AccountId = ([string](Invoke-AwsCli @(
        "sts", "get-caller-identity",
        "--query", "Account",
        "--output", "text"
    ))).Trim()
    if ([string]::IsNullOrWhiteSpace($AccountId) -or $AccountId -eq "None") {
        throw "AWS account ID was not returned. Check the current AWS credentials."
    }

    $ExistingAutoScalingGroup = ([string](Invoke-AwsCli @(
        "autoscaling", "describe-auto-scaling-groups",
        "--auto-scaling-group-names", $AutoScalingGroupName,
        "--region", $Region,
        "--query", "AutoScalingGroups[0].AutoScalingGroupName",
        "--output", "text"
    ))).Trim()
    if ([string]::IsNullOrWhiteSpace($ExistingAutoScalingGroup) -or $ExistingAutoScalingGroup -eq "None") {
        $AutoScalingGroupJson = (Invoke-AwsCli @(
            "autoscaling", "describe-auto-scaling-groups",
            "--region", $Region,
            "--query", "AutoScalingGroups[].AutoScalingGroupName",
            "--output", "json"
        ) | Out-String)
        $AutoScalingGroupCandidates = @($AutoScalingGroupJson | ConvertFrom-Json)

        if ($AutoScalingGroupCandidates.Count -ne 1) {
            throw "ASG '$AutoScalingGroupName' was not found and automatic selection is ambiguous. Candidates: $($AutoScalingGroupCandidates -join ', ')"
        }

        $ExistingAutoScalingGroup = $AutoScalingGroupCandidates[0]
    }
    $AutoScalingGroupName = $ExistingAutoScalingGroup
    Write-Output "Using Auto Scaling Group: $ExistingAutoScalingGroup"

    $TargetGroupArn = ([string](Invoke-AwsCli @(
        "elbv2", "describe-target-groups",
        "--names", $TargetGroupName,
        "--region", $Region,
        "--query", "TargetGroups[0].TargetGroupArn",
        "--output", "text"
    ))).Trim()

    if ([string]::IsNullOrWhiteSpace($TargetGroupArn) -or $TargetGroupArn -eq "None") {
        $TargetGroupJson = (Invoke-AwsCli @(
            "elbv2", "describe-target-groups",
            "--region", $Region,
            "--query", "TargetGroups[].{Name:TargetGroupName,Arn:TargetGroupArn}",
            "--output", "json"
        ) | Out-String)
        $TargetGroupCandidates = @($TargetGroupJson | ConvertFrom-Json)

        if ($TargetGroupCandidates.Count -ne 1) {
            throw "Target group '$TargetGroupName' was not found and automatic selection is ambiguous."
        }

        $TargetGroupName = $TargetGroupCandidates[0].Name
        $TargetGroupArn = $TargetGroupCandidates[0].Arn
    }
    Write-Output "Using target group: $TargetGroupName"

    $RoleArn = "arn:aws:iam::${AccountId}:role/${CodeDeployServiceRoleName}"
    $TrustPolicyPath = Join-Path $TempDirectory "codedeploy-trust.json"
    $TrustPolicy = @'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "codedeploy.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
'@
    [System.IO.File]::WriteAllText($TrustPolicyPath, $TrustPolicy, $Utf8NoBom)

    Write-Output "=== 2. Create or verify CodeDeploy service role ==="
    if (-not (Test-AwsResource @("iam", "get-role", "--role-name", $CodeDeployServiceRoleName))) {
        Invoke-AwsCli @(
            "iam", "create-role",
            "--role-name", $CodeDeployServiceRoleName,
            "--assume-role-policy-document", "file://$TrustPolicyPath"
        ) | Out-Host
    } else {
        Write-Output "Already exists: $CodeDeployServiceRoleName"
    }

    $RequiredPolicies = @(
        "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole",
        "arn:aws:iam::aws:policy/AutoScalingFullAccess",
        "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
        "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
    )

    foreach ($PolicyArn in $RequiredPolicies) {
        $AttachedPolicies = [string](Invoke-AwsCli @(
            "iam", "list-attached-role-policies",
            "--role-name", $CodeDeployServiceRoleName,
            "--query", "AttachedPolicies[].PolicyArn",
            "--output", "text"
        ))

        if ($AttachedPolicies -notmatch [regex]::Escape($PolicyArn)) {
            Invoke-AwsCli @(
                "iam", "attach-role-policy",
                "--role-name", $CodeDeployServiceRoleName,
                "--policy-arn", $PolicyArn
            ) | Out-Host
        } else {
            Write-Output "Policy already attached: $PolicyArn"
        }
    }

    $CodeDeployInlinePolicyPath = Join-Path $TempDirectory "codedeploy-bluegreen-policy.json"
    $CodeDeployInlinePolicy = @{
        Version = "2012-10-17"
        Statement = @(
            @{
                Sid = "BlueGreenAutoScaling"
                Effect = "Allow"
                Action = @(
                    "autoscaling:CreateAutoScalingGroup",
                    "autoscaling:DeleteAutoScalingGroup",
                    "autoscaling:Describe*",
                    "autoscaling:UpdateAutoScalingGroup",
                    "autoscaling:PutLifecycleHook",
                    "autoscaling:DeleteLifecycleHook",
                    "autoscaling:SetInstanceProtection",
                    "autoscaling:TerminateInstanceInAutoScalingGroup",
                    "autoscaling:CompleteLifecycleAction"
                )
                Resource = "*"
            },
            @{
                Sid = "BlueGreenEc2"
                Effect = "Allow"
                Action = @(
                    "ec2:Describe*",
                    "ec2:RunInstances",
                    "ec2:TerminateInstances",
                    "ec2:CreateTags"
                )
                Resource = "*"
            },
            @{
                Sid = "BlueGreenLoadBalancing"
                Effect = "Allow"
                Action = @(
                    "elasticloadbalancing:Describe*",
                    "elasticloadbalancing:RegisterTargets",
                    "elasticloadbalancing:DeregisterTargets",
                    "elasticloadbalancing:ModifyTargetGroup"
                )
                Resource = "*"
            },
            @{
                Sid = "PassInstanceRole"
                Effect = "Allow"
                Action = "iam:PassRole"
                Resource = "*"
            }
        )
    } | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($CodeDeployInlinePolicyPath, $CodeDeployInlinePolicy, $Utf8NoBom)
    Invoke-AwsCli @(
        "iam", "put-role-policy",
        "--role-name", $CodeDeployServiceRoleName,
        "--policy-name", "CodeDeployBlueGreenOperations",
        "--policy-document", "file://$CodeDeployInlinePolicyPath"
    ) | Out-Host

    Write-Output "=== 3. Create or verify CodeDeploy application ==="
    $ApplicationExists = Test-AwsResource @(
        "deploy", "get-application",
        "--application-name", $CodeDeployApplicationName,
        "--region", $Region
    )

    if (-not $ApplicationExists) {
        Invoke-AwsCli @(
            "deploy", "create-application",
            "--application-name", $CodeDeployApplicationName,
            "--compute-platform", "Server",
            "--region", $Region
        ) | Out-Host
    } else {
        Write-Output "Already exists: $CodeDeployApplicationName"
    }

    Write-Output "=== 4. Create or verify blue-green deployment group ==="
    $DeploymentGroupExists = Test-AwsResource @(
        "deploy", "get-deployment-group",
        "--application-name", $CodeDeployApplicationName,
        "--deployment-group-name", $DeploymentGroupName,
        "--region", $Region
    )

    if (-not $DeploymentGroupExists) {
        $DeploymentGroupPath = Join-Path $TempDirectory "deployment-group.json"
        $DeploymentGroup = @{
            applicationName = $CodeDeployApplicationName
            deploymentGroupName = $DeploymentGroupName
            serviceRoleArn = $RoleArn
            deploymentConfigName = "CodeDeployDefault.OneAtATime"
            deploymentStyle = @{
                deploymentType = "BLUE_GREEN"
                deploymentOption = "WITH_TRAFFIC_CONTROL"
            }
            blueGreenDeploymentConfiguration = @{
                terminateBlueInstancesOnDeploymentSuccess = @{
                    action = "TERMINATE"
                    terminationWaitTimeInMinutes = 5
                }
                deploymentReadyOption = @{
                    actionOnTimeout = "CONTINUE_DEPLOYMENT"
                    waitTimeInMinutes = 0
                }
                greenFleetProvisioningOption = @{
                    action = "COPY_AUTO_SCALING_GROUP"
                }
            }
            autoScalingGroups = @($AutoScalingGroupName)
            loadBalancerInfo = @{
                targetGroupInfoList = @(
                    @{ name = $TargetGroupName }
                )
            }
        } | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($DeploymentGroupPath, $DeploymentGroup, $Utf8NoBom)

        Invoke-AwsCli @(
            "deploy", "create-deployment-group",
            "--cli-input-json", "file://$DeploymentGroupPath",
            "--region", $Region
        ) | Out-Host
    } else {
        Write-Output "Already exists: $DeploymentGroupName"
    }

    Write-Output "Objective 4 complete. CodeDeploy application and blue-green deployment group are configured."
}
finally {
    Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
