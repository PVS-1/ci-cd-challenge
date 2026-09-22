[CmdletBinding()]
param(
    [string]$Prefix = "cmtr-msdta2zd",
    [string]$PrimaryRegion = "us-east-1",
    [string]$SecondaryRegion = "eu-west-1",
    [string]$RepositoryName = "cmtr-msdta2zd-repo",
    [string]$EcrRepositoryName = "cmtr-msdta2zd-north-pole",
    [string]$CodeBuildProjectName = "cmtr-msdta2zd-docker-build",
    [string]$PipelineName = "cmtr-msdta2zd-cicd-pipeline"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$accountId = $null
$tempFiles = [System.Collections.Generic.List[string]]::new()

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
    [pscustomobject]@{ ExitCode = $exitCode; Output = ($output | Out-String).Trim() }
}

function Write-JsonFile {
    param([Parameter(Mandatory = $true)]$Value)
    $path = Join-Path $env:TEMP ("cmtr-msdta2zd-" + [guid]::NewGuid().ToString("N") + ".json")
    ConvertTo-Json -InputObject $Value -Depth 20 | Set-Content -LiteralPath $path -Encoding ascii
    $tempFiles.Add($path)
    return $path
}

function Get-AccountId {
    if ($script:accountId) { return $script:accountId }
    $script:accountId = (Invoke-Aws @("sts", "get-caller-identity", "--query", "Account", "--output", "text")).Trim()
    return $script:accountId
}

function Ensure-IamRole {
    param([string]$RoleName, [string]$ServicePrincipal)
    $role = Invoke-AwsOptional @("iam", "get-role", "--role-name", $RoleName, "--output", "json")
    if ($role.ExitCode -eq 0) {
        return (($role.Output | ConvertFrom-Json).Role.Arn)
    }
    $trust = @{ Version = "2012-10-17"; Statement = @(@{ Effect = "Allow"; Principal = @{ Service = $ServicePrincipal }; Action = "sts:AssumeRole" }) }
    $trustFile = Write-JsonFile $trust
    $created = Invoke-Aws @("iam", "create-role", "--role-name", $RoleName, "--assume-role-policy-document", "file://$trustFile", "--output", "json") | ConvertFrom-Json
    return $created.Role.Arn
}

function Ensure-CustomerPolicy {
    param([string]$PolicyName, [hashtable]$Document)
    $arn = "arn:aws:iam::$((Get-AccountId))`:policy/$PolicyName"
    $policy = Invoke-AwsOptional @("iam", "get-policy", "--policy-arn", $arn, "--output", "json")
    $policyDocument = Write-JsonFile $Document
    if ($policy.ExitCode -ne 0) {
        Invoke-Aws @("iam", "create-policy", "--policy-name", $PolicyName, "--policy-document", "file://$policyDocument", "--output", "json") | Out-Null
        return $arn
    }

    $newVersion = Invoke-Aws @("iam", "create-policy-version", "--policy-arn", $arn, "--policy-document", "file://$policyDocument", "--set-as-default", "--output", "json") | ConvertFrom-Json
    $versions = (Invoke-Aws @("iam", "list-policy-versions", "--policy-arn", $arn, "--output", "json") | ConvertFrom-Json).Versions
    foreach ($version in ($versions | Where-Object { -not $_.IsDefaultVersion })) {
        Invoke-Aws @("iam", "delete-policy-version", "--policy-arn", $arn, "--version-id", $version.VersionId) | Out-Null
    }
    return $arn
}

function Attach-Policy {
    param([string]$RoleName, [string]$PolicyArn)
    Invoke-Aws @("iam", "attach-role-policy", "--role-name", $RoleName, "--policy-arn", $PolicyArn) | Out-Null
}

function Ensure-Bucket {
    param([string]$BucketName, [string]$Region)
    $head = Invoke-AwsOptional @("s3api", "head-bucket", "--bucket", $BucketName, "--region", $Region)
    if ($head.ExitCode -ne 0) {
        if ($Region -eq "us-east-1") {
            Invoke-Aws @("s3api", "create-bucket", "--bucket", $BucketName, "--region", $Region) | Out-Null
        } else {
            Invoke-Aws @("s3api", "create-bucket", "--bucket", $BucketName, "--region", $Region, "--create-bucket-configuration", "LocationConstraint=$Region") | Out-Null
        }
    }
    Invoke-Aws @("s3api", "put-public-access-block", "--bucket", $BucketName, "--public-access-block-configuration", "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true", "--region", $Region) | Out-Null
    Invoke-Aws @("s3api", "put-bucket-versioning", "--bucket", $BucketName, "--versioning-configuration", "Status=Enabled", "--region", $Region) | Out-Null
}

function Ensure-EcrRepository {
    param([string]$RepositoryName, [string]$Region)
    $result = Invoke-AwsOptional @("ecr", "describe-repositories", "--repository-names", $RepositoryName, "--region", $Region, "--output", "json")
    if ($result.ExitCode -ne 0) {
        Invoke-Aws @("ecr", "create-repository", "--repository-name", $RepositoryName, "--image-scanning-configuration", "scanOnPush=true", "--region", $Region, "--output", "json") | Out-Null
    }
    return (Invoke-Aws @("ecr", "describe-repositories", "--repository-names", $RepositoryName, "--region", $Region, "--query", "repositories[0].repositoryArn", "--output", "text")).Trim()
}

function Get-VpcId {
    param([string]$Name, [string]$Region)
    $vpcId = (Invoke-Aws @("ec2", "describe-vpcs", "--filters", "Name=tag:Name,Values=$Name", "--region", $Region, "--query", "Vpcs[0].VpcId", "--output", "text")).Trim()
    if ([string]::IsNullOrWhiteSpace($vpcId) -or $vpcId -eq "None") { throw "VPC $Name was not found in $Region" }
    return $vpcId
}

function Get-PrivateHostedZoneIdForVpc {
    param([string]$ZoneName, [string]$VpcId, [string]$VpcRegion)

    $result = Invoke-Aws @("route53", "list-hosted-zones-by-vpc", "--vpc-id", $VpcId, "--vpc-region", $VpcRegion, "--output", "json") | ConvertFrom-Json
    $zone = $result.HostedZoneSummaries | Where-Object { $_.Name.TrimEnd('.') -eq $ZoneName } | Select-Object -First 1
    if (-not $zone) { return $null }
    return ($zone.HostedZoneId -replace ".*/", "")
}

function Get-RegionalInfrastructure {
    param([string]$Region, [string]$Suffix)
    $alb = Invoke-Aws @("elbv2", "describe-load-balancers", "--names", "$Prefix-alb-$Suffix", "--region", $Region, "--query", "LoadBalancers[0].{Arn:LoadBalancerArn,Dns:DNSName,Zone:CanonicalHostedZoneId}", "--output", "json") | ConvertFrom-Json
    $targetGroupName = "$Prefix-app-$Suffix"
    $targetGroupArn = (Invoke-Aws @("elbv2", "describe-target-groups", "--names", $targetGroupName, "--region", $Region, "--query", "TargetGroups[0].TargetGroupArn", "--output", "text")).Trim()
    $expectedAsgName = "$Prefix-asg-blue-$Suffix"
    $autoScalingGroups = (Invoke-Aws @("autoscaling", "describe-auto-scaling-groups", "--region", $Region, "--output", "json") | ConvertFrom-Json).AutoScalingGroups
    $expectedGroup = $autoScalingGroups | Where-Object { $_.AutoScalingGroupName -eq $expectedAsgName } | Select-Object -First 1
    if ($expectedGroup) {
        $asgName = $expectedGroup.AutoScalingGroupName
    } else {
        $replacementGroups = @($autoScalingGroups | Where-Object { $_.TargetGroupARNs -contains $targetGroupArn })
        if ($replacementGroups.Count -ne 1) {
            $availableNames = ($autoScalingGroups.AutoScalingGroupName -join ", ")
            throw "ASG $expectedAsgName was not found in $Region, and no unique replacement ASG is attached to $targetGroupName. Available ASGs: $availableNames"
        }
        $asgName = $replacementGroups[0].AutoScalingGroupName
        Write-Output "Using replacement blue fleet $asgName for $Suffix."
    }
    [pscustomobject]@{ Region = $Region; Suffix = $Suffix; AlbArn = $alb.Arn; AlbDns = $alb.Dns; AlbZone = $alb.Zone; TargetGroupArn = $targetGroupArn; TargetGroupName = $targetGroupName; AsgName = $asgName }
}

function Ensure-BlueFleetCapacity {
    param([string]$AutoScalingGroupName, [string]$Region)

    $group = Invoke-Aws @("autoscaling", "describe-auto-scaling-groups", "--auto-scaling-group-names", $AutoScalingGroupName, "--region", $Region, "--output", "json") | ConvertFrom-Json
    $autoScalingGroup = $group.AutoScalingGroups[0]
    $inServiceInstances = @($autoScalingGroup.Instances | Where-Object { $_.LifecycleState -eq "InService" })
    if ($inServiceInstances.Count -lt 2) {
        $maximumCapacity = [Math]::Max([int]$autoScalingGroup.MaxSize, 2)
        Write-Output "Restoring $AutoScalingGroupName to two InService blue-fleet instances."
        Invoke-Aws @("autoscaling", "update-auto-scaling-group", "--auto-scaling-group-name", $AutoScalingGroupName, "--min-size", "2", "--desired-capacity", "2", "--max-size", $maximumCapacity, "--region", $Region) | Out-Null
        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 15
            $group = Invoke-Aws @("autoscaling", "describe-auto-scaling-groups", "--auto-scaling-group-names", $AutoScalingGroupName, "--region", $Region, "--output", "json") | ConvertFrom-Json
            $inServiceInstances = @($group.AutoScalingGroups[0].Instances | Where-Object { $_.LifecycleState -eq "InService" })
        } while ($inServiceInstances.Count -lt 2 -and (Get-Date) -lt $deadline)
        if ($inServiceInstances.Count -lt 2) {
            throw "ASG $AutoScalingGroupName did not reach two InService instances within ten minutes."
        }
    }
}

function Ensure-CodeBuildProject {
    param([string]$ProjectName, [string]$RoleArn, [string]$RepositoryArn, [string]$Region)
    $source = @{ type = "CODEPIPELINE"; buildspec = "buildspec.yml" }
    $environment = @{ type = "ARM_CONTAINER"; image = "aws/codebuild/amazonlinux2-aarch64-standard:3.0"; computeType = "BUILD_GENERAL1_SMALL"; privilegedMode = $true; imagePullCredentialsType = "CODEBUILD"; environmentVariables = @(
        @{ name = "AWS_DEFAULT_REGION"; value = $Region; type = "PLAINTEXT" },
        @{ name = "AWS_ACCOUNT_ID"; value = (Get-AccountId); type = "PLAINTEXT" },
        @{ name = "IMAGE_REPO_NAME"; value = $EcrRepositoryName; type = "PLAINTEXT" }
    ) }
    $project = @{ name = $ProjectName; description = "Build and push the blue green application image"; source = $source; artifacts = @{ type = "CODEPIPELINE" }; environment = $environment; serviceRole = $RoleArn; timeoutInMinutes = 30 }
    $projectFile = Write-JsonFile $project
    $existing = Invoke-AwsOptional @("codebuild", "batch-get-projects", "--names", $ProjectName, "--region", $Region, "--output", "json")
    if ($existing.ExitCode -eq 0 -and (($existing.Output | ConvertFrom-Json).projects.Count -gt 0)) {
        Invoke-Aws @("codebuild", "update-project", "--cli-input-json", "file://$projectFile", "--region", $Region, "--output", "json") | Out-Null
    } else {
        Invoke-Aws @("codebuild", "create-project", "--cli-input-json", "file://$projectFile", "--region", $Region, "--output", "json") | Out-Null
    }
}

function Ensure-CodeDeployGroup {
    param([string]$Region, [string]$ApplicationName, [string]$DeploymentGroupName, [string]$ServiceRoleArn, [string]$AsgName, [string]$TargetGroupName)
    $app = Invoke-AwsOptional @("deploy", "get-application", "--application-name", $ApplicationName, "--region", $Region, "--output", "json")
    if ($app.ExitCode -ne 0) {
        Invoke-Aws @("deploy", "create-application", "--application-name", $ApplicationName, "--compute-platform", "Server", "--region", $Region) | Out-Null
    }
    $blueGreen = @{ terminateBlueInstancesOnDeploymentSuccess = @{ action = "TERMINATE"; terminationWaitTimeInMinutes = 0 }; deploymentReadyOption = @{ actionOnTimeout = "CONTINUE_DEPLOYMENT"; waitTimeInMinutes = 0 }; greenFleetProvisioningOption = @{ action = "COPY_AUTO_SCALING_GROUP" } }
    $loadBalancer = @{ targetGroupInfoList = @(@{ name = $TargetGroupName }) }
    $style = "deploymentType=BLUE_GREEN,deploymentOption=WITH_TRAFFIC_CONTROL"
    $blueGreenFile = Write-JsonFile $blueGreen
    $loadBalancerFile = Write-JsonFile $loadBalancer
    $group = Invoke-AwsOptional @("deploy", "get-deployment-group", "--application-name", $ApplicationName, "--deployment-group-name", $DeploymentGroupName, "--region", $Region, "--output", "json")
    $operation = if ($group.ExitCode -eq 0) { "update-deployment-group" } else { "create-deployment-group" }
    $deploymentGroupNameArguments = if ($operation -eq "update-deployment-group") {
        @("--current-deployment-group-name", $DeploymentGroupName)
    } else {
        @("--deployment-group-name", $DeploymentGroupName)
    }
    $deploymentGroupArguments = @(
        "deploy", $operation, "--application-name", $ApplicationName
    ) + $deploymentGroupNameArguments + @(
        "--service-role-arn", $ServiceRoleArn, "--deployment-style", $style,
        "--blue-green-deployment-configuration", "file://$blueGreenFile", "--load-balancer-info", "file://$loadBalancerFile",
        "--auto-scaling-groups", $AsgName, "--deployment-config-name", "CodeDeployDefault.AllAtOnce", "--region", $Region, "--output", "json"
    )
    Invoke-Aws $deploymentGroupArguments | Out-Null
}

function Ensure-HealthCheck {
    param([string]$Name, [string]$DomainName)
    $healthChecks = (Invoke-Aws @("route53", "list-health-checks", "--output", "json") | ConvertFrom-Json).HealthChecks
    foreach ($healthCheck in $healthChecks) {
        $tags = (Invoke-AwsOptional @("route53", "list-tags-for-resource", "--resource-type", "healthcheck", "--resource-id", $healthCheck.Id, "--output", "json")).Output
        if ($tags) {
            $tagList = ($tags | ConvertFrom-Json).ResourceTagSet.Tags
            if (($tagList | Where-Object { $_.Key -eq "Name" -and $_.Value -eq $Name })) { return $healthCheck.Id }
        }
    }
    $config = @{ Type = "HTTP"; FullyQualifiedDomainName = $DomainName; Port = 80; ResourcePath = "/health"; RequestInterval = 10; FailureThreshold = 3; MeasureLatency = $false }
    $configFile = Write-JsonFile $config
    $created = Invoke-Aws @("route53", "create-health-check", "--health-check-config", "file://$configFile", "--caller-reference", "$Name-$([guid]::NewGuid().ToString())", "--output", "json") | ConvertFrom-Json
    Invoke-Aws @("route53", "change-tags-for-resource", "--resource-type", "healthcheck", "--resource-id", $created.HealthCheck.Id, "--add-tags", "Key=Name,Value=$Name") | Out-Null
    return $created.HealthCheck.Id
}

try {
    Write-Output "=== Confirm AWS identity ==="
    Invoke-Aws @("sts", "get-caller-identity", "--query", "{Account:Account,Arn:Arn}", "--output", "table") | Out-Host
    $account = Get-AccountId

    Write-Output "=== Discover pre-deployed regional infrastructure ==="
    $primary = Get-RegionalInfrastructure -Region $PrimaryRegion -Suffix "us-east-1"
    $secondary = Get-RegionalInfrastructure -Region $SecondaryRegion -Suffix "eu-west-1"
    $primaryVpcId = Get-VpcId -Name "$Prefix-vpc-us-east-1" -Region $PrimaryRegion
    $secondaryVpcId = Get-VpcId -Name "$Prefix-vpc-eu-west-1" -Region $SecondaryRegion
    Ensure-BlueFleetCapacity -AutoScalingGroupName $primary.AsgName -Region $PrimaryRegion
    Ensure-BlueFleetCapacity -AutoScalingGroupName $secondary.AsgName -Region $SecondaryRegion

    Write-Output "=== Create ECR and artifact buckets ==="
    $ecrArn = Ensure-EcrRepository -RepositoryName $EcrRepositoryName -Region $PrimaryRegion
    $artifactBucketPrimary = "$Prefix-artifacts-us-east-1"
    $artifactBucketSecondary = "$Prefix-artifacts-eu-west-1"
    Ensure-Bucket -BucketName $artifactBucketPrimary -Region $PrimaryRegion
    Ensure-Bucket -BucketName $artifactBucketSecondary -Region $SecondaryRegion

    Write-Output "=== Create IAM roles and customer policies ==="
    $codeBuildRoleName = "$Prefix-codebuild-role"
    $codeDeployRoleName = "$Prefix-codedeploy-role"
    $pipelineRoleName = "$Prefix-pipeline-role"
    $eventsRoleName = "$Prefix-events-role"
    $codeBuildRoleArn = Ensure-IamRole -RoleName $codeBuildRoleName -ServicePrincipal "codebuild.amazonaws.com"
    $codeDeployRoleArn = Ensure-IamRole -RoleName $codeDeployRoleName -ServicePrincipal "codedeploy.amazonaws.com"
    $pipelineRoleArn = Ensure-IamRole -RoleName $pipelineRoleName -ServicePrincipal "codepipeline.amazonaws.com"
    $eventsRoleArn = Ensure-IamRole -RoleName $eventsRoleName -ServicePrincipal "events.amazonaws.com"
    $repoArn = "arn:aws:codecommit:${PrimaryRegion}:${account}:$RepositoryName"
    $codeBuildLogArn = "arn:aws:logs:${PrimaryRegion}:${account}:log-group:/aws/codebuild/${CodeBuildProjectName}:*"
    $codeBuildPolicy = @{ Version = "2012-10-17"; Statement = @(
        @{ Effect = "Allow"; Action = @("logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"); Resource = $codeBuildLogArn },
        @{ Effect = "Allow"; Action = @("s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"); Resource = @("arn:aws:s3:::$artifactBucketPrimary", "arn:aws:s3:::$artifactBucketPrimary/*", "arn:aws:s3:::$artifactBucketSecondary", "arn:aws:s3:::$artifactBucketSecondary/*") },
        @{ Effect = "Allow"; Action = "ecr:GetAuthorizationToken"; Resource = "*" },
        @{ Effect = "Allow"; Action = @("ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"); Resource = $ecrArn },
        @{ Effect = "Allow"; Action = "codecommit:GitPull"; Resource = $repoArn }
    ) }
    $codeDeployPolicy = @{ Version = "2012-10-17"; Statement = @(@{ Effect = "Allow"; Action = @("ec2:RunInstances", "ec2:CreateTags"); Resource = "*" }, @{ Effect = "Allow"; Action = "iam:PassRole"; Resource = "arn:aws:iam::${account}:role/*" }) }
    $pipelinePolicy = @{ Version = "2012-10-17"; Statement = @(
        @{ Effect = "Allow"; Action = @("s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning", "s3:GetBucketLocation"); Resource = @("arn:aws:s3:::$artifactBucketPrimary", "arn:aws:s3:::$artifactBucketPrimary/*", "arn:aws:s3:::$artifactBucketSecondary", "arn:aws:s3:::$artifactBucketSecondary/*") },
        @{ Effect = "Allow"; Action = @("codecommit:GetBranch", "codecommit:GetCommit", "codecommit:GetRepository", "codecommit:UploadArchive", "codecommit:GetUploadArchiveStatus", "codecommit:CancelUploadArchive"); Resource = $repoArn },
        @{ Effect = "Allow"; Action = @("codebuild:StartBuild", "codebuild:BatchGetBuilds"); Resource = "arn:aws:codebuild:${PrimaryRegion}:${account}:project/$CodeBuildProjectName" },
        @{ Effect = "Allow"; Action = @("codedeploy:CreateDeployment", "codedeploy:RegisterApplicationRevision", "codedeploy:GetDeployment", "codedeploy:GetApplicationRevision", "codedeploy:GetApplication", "codedeploy:GetDeploymentConfig", "codedeploy:GetDeploymentGroup"); Resource = "*" }
    ) }
    $eventsPolicy = @{ Version = "2012-10-17"; Statement = @(@{ Effect = "Allow"; Action = "codepipeline:StartPipelineExecution"; Resource = "arn:aws:codepipeline:${PrimaryRegion}:${account}:$PipelineName" }) }
    $codeBuildPolicyArn = Ensure-CustomerPolicy -PolicyName "cmtr-CodeBuild-pipeline" -Document $codeBuildPolicy
    $codeDeployPolicyArn = Ensure-CustomerPolicy -PolicyName "cmtr-CodeDeploy-blue-green" -Document $codeDeployPolicy
    $pipelinePolicyArn = Ensure-CustomerPolicy -PolicyName "cmtr-CodePipeline-artifacts" -Document $pipelinePolicy
    Attach-Policy -RoleName $codeBuildRoleName -PolicyArn $codeBuildPolicyArn
    Attach-Policy -RoleName $codeDeployRoleName -PolicyArn $codeDeployPolicyArn
    Attach-Policy -RoleName $codeDeployRoleName -PolicyArn "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
    Attach-Policy -RoleName $pipelineRoleName -PolicyArn $pipelinePolicyArn
    $eventsPolicyArn = Ensure-CustomerPolicy -PolicyName "cmtr-CodePipeline-events" -Document $eventsPolicy
    Attach-Policy -RoleName $eventsRoleName -PolicyArn $eventsPolicyArn

    Write-Output "=== Configure CodeBuild ==="
    Ensure-CodeBuildProject -ProjectName $CodeBuildProjectName -RoleArn $codeBuildRoleArn -RepositoryArn $repoArn -Region $PrimaryRegion

    Write-Output "=== Configure CodeDeploy blue green applications ==="
    Ensure-CodeDeployGroup -Region $PrimaryRegion -ApplicationName "$Prefix-app-us-east-1" -DeploymentGroupName "$Prefix-dg-us-east-1" -ServiceRoleArn $codeDeployRoleArn -AsgName $primary.AsgName -TargetGroupName $primary.TargetGroupName
    Ensure-CodeDeployGroup -Region $SecondaryRegion -ApplicationName "$Prefix-app-eu-west-1" -DeploymentGroupName "$Prefix-dg-eu-west-1" -ServiceRoleArn $codeDeployRoleArn -AsgName $secondary.AsgName -TargetGroupName $secondary.TargetGroupName

    Write-Output "=== Configure CodePipeline with parallel deploy actions ==="
    $artifactStores = @{
        $PrimaryRegion = @{ type = "S3"; location = $artifactBucketPrimary }
        $SecondaryRegion = @{ type = "S3"; location = $artifactBucketSecondary }
    }
    $pipeline = @{ version = 1; name = $PipelineName; roleArn = $pipelineRoleArn; artifactStores = $artifactStores; stages = @(
        @{ name = "Source"; actions = @(@{ name = "Source"; actionTypeId = @{ category = "Source"; owner = "AWS"; provider = "CodeCommit"; version = "1" }; runOrder = 1; outputArtifacts = @(@{ name = "SourceArtifact" }); configuration = @{ RepositoryName = $RepositoryName; BranchName = "main"; PollForSourceChanges = "false" } }) },
        @{ name = "Build"; actions = @(@{ name = "Build"; actionTypeId = @{ category = "Build"; owner = "AWS"; provider = "CodeBuild"; version = "1" }; runOrder = 1; inputArtifacts = @(@{ name = "SourceArtifact" }); outputArtifacts = @(@{ name = "BuildArtifact" }); configuration = @{ ProjectName = $CodeBuildProjectName } }) },
        @{ name = "Deploy"; actions = @(
            @{ name = "DeployRegion1"; actionTypeId = @{ category = "Deploy"; owner = "AWS"; provider = "CodeDeploy"; version = "1" }; runOrder = 1; region = $PrimaryRegion; inputArtifacts = @(@{ name = "BuildArtifact" }); configuration = @{ ApplicationName = "$Prefix-app-us-east-1"; DeploymentGroupName = "$Prefix-dg-us-east-1" } },
            @{ name = "DeployRegion2"; actionTypeId = @{ category = "Deploy"; owner = "AWS"; provider = "CodeDeploy"; version = "1" }; runOrder = 1; region = $SecondaryRegion; inputArtifacts = @(@{ name = "BuildArtifact" }); configuration = @{ ApplicationName = "$Prefix-app-eu-west-1"; DeploymentGroupName = "$Prefix-dg-eu-west-1" } }
        ) }
    ) }
    $pipelineFile = Write-JsonFile $pipeline
    $pipelineExists = Invoke-AwsOptional @("codepipeline", "get-pipeline", "--name", $PipelineName, "--region", $PrimaryRegion, "--output", "json")
    if ($pipelineExists.ExitCode -eq 0) {
        Invoke-Aws @("codepipeline", "update-pipeline", "--pipeline", "file://$pipelineFile", "--region", $PrimaryRegion, "--output", "json") | Out-Null
    } else {
        Invoke-Aws @("codepipeline", "create-pipeline", "--pipeline", "file://$pipelineFile", "--region", $PrimaryRegion, "--output", "json") | Out-Null
    }

    Write-Output "=== Enable EventBridge source trigger ==="
    $eventPattern = @{ source = @("aws.codecommit"); 'detail-type' = @("CodeCommit Repository State Change"); resources = @($repoArn); detail = @{ event = @("referenceUpdated"); referenceType = @("branch"); referenceName = @("main") } }
    $eventPatternFile = Write-JsonFile $eventPattern
    $ruleName = "$Prefix-source-trigger"
    $ruleArn = (Invoke-Aws @("events", "put-rule", "--name", $ruleName, "--event-pattern", "file://$eventPatternFile", "--state", "ENABLED", "--region", $PrimaryRegion, "--query", "RuleArn", "--output", "text")).Trim()
    $target = @{ Id = $PipelineName; Arn = "arn:aws:codepipeline:${PrimaryRegion}:${account}:$PipelineName"; RoleArn = $eventsRoleArn }
    $targetFile = Write-JsonFile @($target)
    Invoke-Aws @("events", "put-targets", "--rule", $ruleName, "--targets", "file://$targetFile", "--region", $PrimaryRegion, "--output", "json") | Out-Null

    Write-Output "=== Configure Route 53 private failover zone ==="
    $zoneName = "$Prefix-zone"
    $primaryHostedZoneId = Get-PrivateHostedZoneIdForVpc -ZoneName $zoneName -VpcId $primaryVpcId -VpcRegion $PrimaryRegion
    $secondaryHostedZoneId = Get-PrivateHostedZoneIdForVpc -ZoneName $zoneName -VpcId $secondaryVpcId -VpcRegion $SecondaryRegion
    if ($primaryHostedZoneId) {
        $hostedZoneId = $primaryHostedZoneId
    } elseif ($secondaryHostedZoneId) {
        $hostedZoneId = $secondaryHostedZoneId
        Invoke-Aws @("route53", "associate-vpc-with-hosted-zone", "--hosted-zone-id", $hostedZoneId, "--vpc", "VPCRegion=$PrimaryRegion,VPCId=$primaryVpcId", "--output", "json") | Out-Null
    } else {
        $vpcArgument = "VPCRegion=$PrimaryRegion,VPCId=$primaryVpcId"
        $zone = (Invoke-Aws @("route53", "create-hosted-zone", "--name", $zoneName, "--caller-reference", "$Prefix-$([guid]::NewGuid().ToString())", "--hosted-zone-config", "PrivateZone=true", "--vpc", $vpcArgument, "--output", "json") | ConvertFrom-Json).HostedZone
        $hostedZoneId = $zone.Id -replace ".*/", ""
    }
    if ($secondaryHostedZoneId -and $secondaryHostedZoneId -ne $hostedZoneId) {
        $duplicateRecords = (Invoke-Aws @("route53", "list-resource-record-sets", "--hosted-zone-id", $secondaryHostedZoneId, "--output", "json") | ConvertFrom-Json).ResourceRecordSets
        if ($duplicateRecords | Where-Object { $_.Type -notin @("NS", "SOA") }) {
            throw "Cannot reconcile duplicate hosted zone $secondaryHostedZoneId because it contains application DNS records."
        }
        Invoke-Aws @("route53", "delete-hosted-zone", "--id", $secondaryHostedZoneId, "--output", "json") | Out-Null
    }
    if (-not $secondaryHostedZoneId -or $secondaryHostedZoneId -ne $hostedZoneId) {
        Invoke-Aws @("route53", "associate-vpc-with-hosted-zone", "--hosted-zone-id", $hostedZoneId, "--vpc", "VPCRegion=$SecondaryRegion,VPCId=$secondaryVpcId", "--output", "json") | Out-Null
    }
    $primaryHealthCheckId = Ensure-HealthCheck -Name "$Prefix-primary" -DomainName $primary.AlbDns
    $secondaryHealthCheckId = Ensure-HealthCheck -Name "$Prefix-secondary" -DomainName $secondary.AlbDns
    $recordName = "app.$zoneName"
    $recordChanges = @{ Changes = @(
        @{ Action = "UPSERT"; ResourceRecordSet = @{ Name = $recordName; Type = "A"; AliasTarget = @{ HostedZoneId = $primary.AlbZone; DNSName = "dualstack.$($primary.AlbDns)"; EvaluateTargetHealth = $true }; Failover = "PRIMARY"; SetIdentifier = $PrimaryRegion; HealthCheckId = $primaryHealthCheckId } },
        @{ Action = "UPSERT"; ResourceRecordSet = @{ Name = $recordName; Type = "A"; AliasTarget = @{ HostedZoneId = $secondary.AlbZone; DNSName = "dualstack.$($secondary.AlbDns)"; EvaluateTargetHealth = $true }; Failover = "SECONDARY"; SetIdentifier = $SecondaryRegion; HealthCheckId = $secondaryHealthCheckId } }
    ) }
    $recordFile = Write-JsonFile $recordChanges
    Invoke-Aws @("route53", "change-resource-record-sets", "--hosted-zone-id", $hostedZoneId, "--change-batch", "file://$recordFile", "--output", "json") | Out-Null

    Write-Output "Provisioning complete. Hosted zone: $hostedZoneId; EventBridge rule: $ruleArn"
} finally {
    foreach ($file in $tempFiles) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
