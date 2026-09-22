[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubOAuthToken,
    [Parameter(Mandatory = $true)]
    [string]$GitHubRepository,
    [string]$BranchName = "main",
    [string]$Region = "eu-west-1",
    [string]$Prefix = "cmtr-msdta2zd"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$tempFiles = [System.Collections.Generic.List[string]]::new()

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& aws @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $displayArguments = $Arguments | ForEach-Object {
            if ($_ -eq $GitHubOAuthToken) { "[REDACTED]" } else { $_ }
        }
        throw "AWS CLI failed: aws $($displayArguments -join ' ')`n$(($output | Out-String).Trim())"
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

function Write-JsonFile {
    param([Parameter(Mandatory = $true)]$Value)

    $path = Join-Path $env:TEMP ("cmtr-msdta2zd-" + [guid]::NewGuid().ToString("N") + ".json")
    ConvertTo-Json -InputObject $Value -Depth 20 | Set-Content -LiteralPath $path -Encoding ascii
    $tempFiles.Add($path)
    return $path
}

function Ensure-Role {
    param([string]$RoleName, [string]$ServicePrincipal)

    $existing = Invoke-AwsOptional @("iam", "get-role", "--role-name", $RoleName, "--output", "json")
    if ($existing.ExitCode -eq 0) {
        return (($existing.Output | ConvertFrom-Json).Role.Arn)
    }

    $trustPolicy = @{ Version = "2012-10-17"; Statement = @(@{ Effect = "Allow"; Principal = @{ Service = $ServicePrincipal }; Action = "sts:AssumeRole" }) }
    $trustFile = Write-JsonFile $trustPolicy
    return (Invoke-Aws @("iam", "create-role", "--role-name", $RoleName, "--assume-role-policy-document", "file://$trustFile", "--query", "Role.Arn", "--output", "text")).Trim()
}

function Set-RolePolicy {
    param([string]$RoleName, [string]$PolicyName, [hashtable]$Policy)

    $policyFile = Write-JsonFile $Policy
    Invoke-Aws @("iam", "put-role-policy", "--role-name", $RoleName, "--policy-name", $PolicyName, "--policy-document", "file://$policyFile") | Out-Null
}

function Ensure-Bucket {
    param([string]$BucketName)

    $existing = Invoke-AwsOptional @("s3api", "head-bucket", "--bucket", $BucketName, "--region", $Region)
    if ($existing.ExitCode -ne 0) {
        Invoke-Aws @("s3api", "create-bucket", "--bucket", $BucketName, "--region", $Region, "--create-bucket-configuration", "LocationConstraint=$Region") | Out-Null
    }
    Invoke-Aws @("s3api", "put-public-access-block", "--bucket", $BucketName, "--public-access-block-configuration", "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true") | Out-Null
    Invoke-Aws @("s3api", "put-bucket-versioning", "--bucket", $BucketName, "--versioning-configuration", "Status=Enabled") | Out-Null
}

function Grant-InstanceArtifactAccess {
    param([string]$TargetGroupArn, [string]$ArtifactBucket)

    $instanceId = (Invoke-Aws @("elbv2", "describe-target-health", "--target-group-arn", $TargetGroupArn, "--region", $Region, "--query", "TargetHealthDescriptions[0].Target.Id", "--output", "text")).Trim()
    if ([string]::IsNullOrWhiteSpace($instanceId) -or $instanceId -eq "None") {
        throw "Target group $TargetGroupArn has no registered EC2 instances from which to resolve its instance profile."
    }
    $instanceProfileArn = (Invoke-Aws @("ec2", "describe-instances", "--instance-ids", $instanceId, "--region", $Region, "--query", "Reservations[0].Instances[0].IamInstanceProfile.Arn", "--output", "text")).Trim()
    if ([string]::IsNullOrWhiteSpace($instanceProfileArn) -or $instanceProfileArn -eq "None") {
        throw "Instance $instanceId does not have an IAM instance profile."
    }
    $instanceProfileName = $instanceProfileArn.Split("/")[-1]
    $roleNames = (Invoke-Aws @("iam", "get-instance-profile", "--instance-profile-name", $instanceProfileName, "--query", "InstanceProfile.Roles[].RoleName", "--output", "text")).Trim()
    if ([string]::IsNullOrWhiteSpace($roleNames) -or $roleNames -eq "None") {
        throw "Instance profile $instanceProfileName has no IAM roles."
    }
    $artifactPolicy = @{ Version = "2012-10-17"; Statement = @(
        @{ Effect = "Allow"; Action = @("s3:GetObject", "s3:GetObjectVersion"); Resource = "arn:aws:s3:::$ArtifactBucket/*" },
        @{ Effect = "Allow"; Action = @("s3:GetBucketLocation", "s3:GetBucketVersioning"); Resource = "arn:aws:s3:::$ArtifactBucket" }
    ) }
    foreach ($roleName in ($roleNames -split "\s+" | Where-Object { $_ })) {
        Set-RolePolicy -RoleName $roleName -PolicyName "$Prefix-codepipeline-artifact-read" -Policy $artifactPolicy
        Write-Output "Granted artifact download access to EC2 role $roleName."
    }
}

function Get-CodeBuildVpcConfiguration {
    param([string]$VpcId)

    $subnets = (Invoke-Aws @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$VpcId", "Name=state,Values=available", "--region", $Region, "--output", "json") | ConvertFrom-Json).Subnets
    $subnetIds = @($subnets | Where-Object { -not $_.MapPublicIpOnLaunch } | ForEach-Object { $_.SubnetId })
    if ($subnetIds.Count -eq 0) {
        throw "No available private subnets were found in VPC $VpcId for CodeBuild."
    }

    $securityGroups = (Invoke-Aws @("ec2", "describe-security-groups", "--filters", "Name=vpc-id,Values=$VpcId", "--region", $Region, "--output", "json") | ConvertFrom-Json).SecurityGroups
    $securityGroup = $securityGroups | Where-Object {
        $_.GroupName -eq "$Prefix-sg" -or ($_.Tags | Where-Object { $_.Key -eq "Name" -and $_.Value -eq "$Prefix-sg" })
    } | Select-Object -First 1
    if (-not $securityGroup) {
        throw "Security group $Prefix-sg was not found in VPC $VpcId for CodeBuild."
    }

    return @{ vpcId = $VpcId; subnets = $subnetIds; securityGroupIds = @($securityGroup.GroupId) }
}

function Test-GitHubToken {
    param([string]$Repository, [string]$Token)

    $headers = @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github+json"; "User-Agent" = "cmtr-msdta2zd-codepipeline" }
    try {
        $repositoryResponse = Invoke-WebRequest -Uri "https://api.github.com/repos/$Repository" -Headers $headers -UseBasicParsing -TimeoutSec 20
        if ($repositoryResponse.StatusCode -ne 200) {
            throw "GitHub repository API returned HTTP $($repositoryResponse.StatusCode)."
        }
        $webhookResponse = Invoke-WebRequest -Uri "https://api.github.com/repos/$Repository/hooks" -Headers $headers -UseBasicParsing -TimeoutSec 20
        if ($webhookResponse.StatusCode -ne 200) {
            throw "GitHub webhook API returned HTTP $($webhookResponse.StatusCode)."
        }
    } catch {
        throw "GitHub PAT cannot access $Repository and repository webhooks. Create a classic PAT with repo and admin:repo_hook scopes, or a fine-grained PAT with repository Contents read/write and Webhooks read/write, then rerun. Details: $($_.Exception.Message)"
    }
}

try {
    Write-Output "=== Confirm AWS identity ==="
    $accountId = (Invoke-Aws @("sts", "get-caller-identity", "--query", "Account", "--output", "text")).Trim()
    if ($GitHubRepository -notmatch "^[^/]+/[^/]+$") {
        throw "GitHubRepository must use the owner/repository format."
    }
    $githubOwner, $githubRepositoryName = $GitHubRepository.Split("/", 2)
    Test-GitHubToken -Repository $GitHubRepository -Token $GitHubOAuthToken

    Write-Output "=== Discover pre-created ALB and CodeDeploy resources ==="
    $loadBalancer = Invoke-Aws @("elbv2", "describe-load-balancers", "--names", "$Prefix-alb", "--region", $Region, "--output", "json") | ConvertFrom-Json
    $loadBalancerArn = $loadBalancer.LoadBalancers[0].LoadBalancerArn
    $loadBalancerDimension = ($loadBalancerArn.Split(":")[-1] -replace "^loadbalancer/", "")
    $targetGroup = Invoke-Aws @("elbv2", "describe-target-groups", "--names", "$Prefix-target-group", "--region", $Region, "--output", "json") | ConvertFrom-Json
    $targetGroupArn = $targetGroup.TargetGroups[0].TargetGroupArn
    $targetGroupDimension = $targetGroupArn.Split(":")[-1]
    $codeBuildVpcConfig = Get-CodeBuildVpcConfiguration -VpcId $targetGroup.TargetGroups[0].VpcId
    Invoke-Aws @("elbv2", "modify-target-group-attributes", "--target-group-arn", $targetGroupArn, "--attributes", "Key=deregistration_delay.timeout_seconds,Value=0", "--region", $Region) | Out-Null
    $deploymentGroup = "$Prefix-codedeploy-deployment-group"
    $applicationName = "$Prefix-codedeploy-application"
    $codeDeployGroup = Invoke-Aws @("deploy", "get-deployment-group", "--application-name", $applicationName, "--deployment-group-name", $deploymentGroup, "--region", $Region, "--output", "json") | ConvertFrom-Json
    $codeDeployRoleArn = $codeDeployGroup.deploymentGroupInfo.serviceRoleArn

    Write-Output "=== Create CloudWatch unhealthy host alarm ==="
    Invoke-Aws @(
        "cloudwatch", "put-metric-alarm", "--alarm-name", "ALBUnhealthy",
        "--alarm-description", "Rollback CodeDeploy deployment when ALB has unhealthy targets.",
        "--namespace", "AWS/ApplicationELB", "--metric-name", "UnHealthyHostCount",
        "--dimensions", "Name=TargetGroup,Value=$targetGroupDimension", "Name=LoadBalancer,Value=$loadBalancerDimension",
        "--statistic", "Maximum", "--period", "60", "--evaluation-periods", "1", "--datapoints-to-alarm", "1",
        "--threshold", "1", "--comparison-operator", "GreaterThanOrEqualToThreshold",
        "--treat-missing-data", "notBreaching", "--region", $Region
    ) | Out-Null

    Write-Output "=== Configure initial CodeDeploy rollback ==="
    $alarmConfiguration = @{ enabled = $false; ignorePollAlarmFailure = $false; alarms = @(@{ name = "ALBUnhealthy" }) }
    $rollbackConfiguration = @{ enabled = $true; events = @("DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM", "DEPLOYMENT_STOP_ON_REQUEST") }
    $alarmFile = Write-JsonFile $alarmConfiguration
    $rollbackFile = Write-JsonFile $rollbackConfiguration
    Invoke-Aws @(
        "deploy", "update-deployment-group", "--application-name", $applicationName,
        "--current-deployment-group-name", $deploymentGroup, "--service-role-arn", $codeDeployRoleArn,
        "--alarm-configuration", "file://$alarmFile", "--auto-rollback-configuration", "file://$rollbackFile",
        "--region", $Region
    ) | Out-Null

    Write-Output "=== Create artifact bucket and IAM roles ==="
    $artifactBucket = "$Prefix-monitoring-artifacts-$accountId-$Region"
    Ensure-Bucket -BucketName $artifactBucket
    Grant-InstanceArtifactAccess -TargetGroupArn $targetGroupArn -ArtifactBucket $artifactBucket
    $codeBuildRoleName = "$Prefix-codebuild-role"
    $pipelineRoleName = "$Prefix-codepipeline-role"
    $codeBuildRoleArn = Ensure-Role -RoleName $codeBuildRoleName -ServicePrincipal "codebuild.amazonaws.com"
    $pipelineRoleArn = Ensure-Role -RoleName $pipelineRoleName -ServicePrincipal "codepipeline.amazonaws.com"
    $codeBuildPolicy = @{ Version = "2012-10-17"; Statement = @(
        @{ Effect = "Allow"; Action = @("logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"); Resource = "*" },
        @{ Effect = "Allow"; Action = @("s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"); Resource = "arn:aws:s3:::$artifactBucket/*" },
        @{ Effect = "Allow"; Action = @("ec2:CreateNetworkInterface", "ec2:CreateNetworkInterfacePermission", "ec2:DeleteNetworkInterface", "ec2:DescribeDhcpOptions", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeVpcs"); Resource = "*" }
    ) }
    $pipelinePolicy = @{ Version = "2012-10-17"; Statement = @(
        @{ Effect = "Allow"; Action = @("s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning", "s3:GetBucketLocation"); Resource = @("arn:aws:s3:::$artifactBucket", "arn:aws:s3:::$artifactBucket/*") },
        @{ Effect = "Allow"; Action = "codebuild:StartBuild"; Resource = "arn:aws:codebuild:${Region}:${accountId}:project/$Prefix-codebuild-project" },
        @{ Effect = "Allow"; Action = "codebuild:BatchGetBuilds"; Resource = "arn:aws:codebuild:${Region}:${accountId}:project/$Prefix-codebuild-project" },
        @{ Effect = "Allow"; Action = @("codedeploy:CreateDeployment", "codedeploy:GetApplication", "codedeploy:GetApplicationRevision", "codedeploy:GetDeployment", "codedeploy:GetDeploymentConfig", "codedeploy:GetDeploymentGroup", "codedeploy:RegisterApplicationRevision"); Resource = "*" }
    ) }
    Set-RolePolicy -RoleName $codeBuildRoleName -PolicyName "$Prefix-codebuild-policy" -Policy $codeBuildPolicy
    Set-RolePolicy -RoleName $pipelineRoleName -PolicyName "$Prefix-codepipeline-policy" -Policy $pipelinePolicy

    Write-Output "=== Create CodeBuild project ==="
    $projectName = "$Prefix-codebuild-project"
    $project = @{
        name = $projectName
        serviceRole = $codeBuildRoleArn
        source = @{ type = "CODEPIPELINE"; buildspec = "10-Monitoring-and-Rollback-with-CloudWatch-and-CodeDeploy/buildspec.yml" }
        artifacts = @{ type = "CODEPIPELINE" }
        environment = @{ type = "LINUX_CONTAINER"; image = "aws/codebuild/standard:7.0"; computeType = "BUILD_GENERAL1_SMALL"; imagePullCredentialsType = "CODEBUILD"; privilegedMode = $false }
        vpcConfig = $codeBuildVpcConfig
    }
    $projectFile = Write-JsonFile $project
    $projectExists = Invoke-AwsOptional @("codebuild", "batch-get-projects", "--names", $projectName, "--region", $Region, "--output", "json")
    if ($projectExists.ExitCode -eq 0 -and (($projectExists.Output | ConvertFrom-Json).projects.Count -gt 0)) {
        Invoke-Aws @("codebuild", "update-project", "--cli-input-json", "file://$projectFile", "--region", $Region) | Out-Null
    } else {
        Invoke-Aws @("codebuild", "create-project", "--cli-input-json", "file://$projectFile", "--region", $Region) | Out-Null
    }

    Write-Output "=== Create CodePipeline and GitHub webhook ==="
    $pipelineName = "$Prefix-codepipeline"
    $pipeline = @{
        version = 1
        name = $pipelineName
        roleArn = $pipelineRoleArn
        artifactStore = @{ type = "S3"; location = $artifactBucket }
        stages = @(
            @{ name = "Source"; actions = @(@{ name = "GitHubSource"; actionTypeId = @{ category = "Source"; owner = "ThirdParty"; provider = "GitHub"; version = "1" }; runOrder = 1; outputArtifacts = @(@{ name = "SourceArtifact" }); configuration = @{ Owner = $githubOwner; Repo = $githubRepositoryName; Branch = $BranchName; OAuthToken = $GitHubOAuthToken; PollForSourceChanges = "false" } }) },
            @{ name = "Build"; actions = @(@{ name = "Build"; actionTypeId = @{ category = "Build"; owner = "AWS"; provider = "CodeBuild"; version = "1" }; runOrder = 1; inputArtifacts = @(@{ name = "SourceArtifact" }); outputArtifacts = @(@{ name = "BuildArtifact" }); configuration = @{ ProjectName = $projectName } }) },
            @{ name = "Deploy"; actions = @(@{ name = "Deploy"; actionTypeId = @{ category = "Deploy"; owner = "AWS"; provider = "CodeDeploy"; version = "1" }; runOrder = 1; inputArtifacts = @(@{ name = "BuildArtifact" }); configuration = @{ ApplicationName = $applicationName; DeploymentGroupName = $deploymentGroup } }) }
        )
    }
    $pipelineFile = Write-JsonFile $pipeline
    $pipelineExists = Invoke-AwsOptional @("codepipeline", "get-pipeline", "--name", $pipelineName, "--region", $Region, "--output", "json")
    if ($pipelineExists.ExitCode -eq 0) {
        Invoke-Aws @("codepipeline", "update-pipeline", "--pipeline", "file://$pipelineFile", "--region", $Region) | Out-Null
    } else {
        Invoke-Aws @("codepipeline", "create-pipeline", "--pipeline", "file://$pipelineFile", "--region", $Region) | Out-Null
    }

    $webhookName = "$Prefix-github-webhook"
    $webhookSecret = [guid]::NewGuid().ToString("N")
    $webhook = @{ webhook = @{
            name = $webhookName
            targetPipeline = $pipelineName
            targetAction = "GitHubSource"
            filters = @(@{ jsonPath = "$.ref"; matchEquals = "refs/heads/$BranchName" })
            authentication = "GITHUB_HMAC"
            authenticationConfiguration = @{ SecretToken = $webhookSecret }
        }
    }
    $webhookFile = Write-JsonFile $webhook
    Invoke-Aws @("codepipeline", "put-webhook", "--cli-input-json", "file://$webhookFile", "--region", $Region) | Out-Null
    Invoke-Aws @("codepipeline", "register-webhook-with-third-party", "--webhook-name", $webhookName, "--region", $Region) | Out-Null

    Write-Output "Provisioning complete. Pipeline: $pipelineName; alarm: ALBUnhealthy; webhook: $webhookName; artifact bucket: $artifactBucket"
} finally {
    foreach ($file in $tempFiles) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
