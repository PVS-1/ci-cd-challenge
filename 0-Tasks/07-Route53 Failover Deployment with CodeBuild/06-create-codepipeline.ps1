[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$RepositoryName = "cmtr-msdta2zd-repo",
    [string]$ProjectName = "cmtr-msdta2zd-codebuild",
    [string]$PipelineName = "cmtr-msdta2zd-pipeline",
    [string]$PipelineRoleName = "cmtr-msdta2zd-codepipeline-role"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("codepipeline-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

function Test-AwsResource {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & aws @Arguments 1>$null 2>$null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference
    return $exitCode -eq 0
}

try {
    $AccountId = (Invoke-Aws @("sts", "get-caller-identity", "--query", "Account", "--output", "text")).Trim()
    $ArtifactBucket = "cmtr-msdta2zd-pipeline-artifacts-${AccountId}"
    $PipelineRoleArn = "arn:aws:iam::${AccountId}:role/${PipelineRoleName}"

    Write-Output "=== 1. Create or verify pipeline artifact bucket ==="
    if (-not (Test-AwsResource @("s3api", "head-bucket", "--bucket", $ArtifactBucket))) {
        Invoke-Aws @("s3api", "create-bucket", "--bucket", $ArtifactBucket, "--region", $Region, "--create-bucket-configuration", "LocationConstraint=$Region") | Out-Host
    } else {
        Write-Output "Artifact bucket already exists: $ArtifactBucket"
    }
    Invoke-Aws @("s3api", "put-bucket-versioning", "--bucket", $ArtifactBucket, "--versioning-configuration", "Status=Enabled") | Out-Host
    Invoke-Aws @("s3api", "put-public-access-block", "--bucket", $ArtifactBucket, "--public-access-block-configuration", "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true") | Out-Host

    $TrustPolicyPath = Join-Path $TempDirectory "pipeline-trust.json"
    $TrustPolicy = @'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "codepipeline.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
'@
    [System.IO.File]::WriteAllText($TrustPolicyPath, $TrustPolicy, $Utf8NoBom)

    $PolicyPath = Join-Path $TempDirectory "pipeline-policy.json"
    $Policy = @{
        Version = "2012-10-17"
        Statement = @(
            @{
                Effect = "Allow"
                Action = @("codecommit:GetBranch", "codecommit:GetCommit", "codecommit:UploadArchive", "codecommit:GetUploadArchiveStatus", "codecommit:CancelUploadArchive")
                Resource = "arn:aws:codecommit:${Region}:${AccountId}:${RepositoryName}"
            },
            @{
                Effect = "Allow"
                Action = @("codebuild:StartBuild", "codebuild:BatchGetBuilds")
                Resource = "arn:aws:codebuild:${Region}:${AccountId}:project/${ProjectName}"
            },
            @{
                Effect = "Allow"
                Action = @("s3:GetBucketVersioning", "s3:GetBucketAcl", "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject")
                Resource = @("arn:aws:s3:::${ArtifactBucket}", "arn:aws:s3:::${ArtifactBucket}/*")
            }
        )
    } | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($PolicyPath, $Policy, $Utf8NoBom)

    Write-Output "=== 2. Create or verify CodePipeline service role ==="
    if (-not (Test-AwsResource @("iam", "get-role", "--role-name", $PipelineRoleName))) {
        Invoke-Aws @("iam", "create-role", "--role-name", $PipelineRoleName, "--assume-role-policy-document", "file://$TrustPolicyPath") | Out-Host
    } else {
        Write-Output "Role already exists: $PipelineRoleName"
    }
    Invoke-Aws @("iam", "put-role-policy", "--role-name", $PipelineRoleName, "--policy-name", "CodeCommitToCodeBuild", "--policy-document", "file://$PolicyPath") | Out-Host

    $PipelinePath = Join-Path $TempDirectory "pipeline.json"
    $Pipeline = @{
        pipeline = @{
            name = $PipelineName
            roleArn = $PipelineRoleArn
            artifactStore = @{ type = "S3"; location = $ArtifactBucket }
            stages = @(
                @{
                    name = "Source"
                    actions = @(
                        @{
                            name = "CodeCommitSource"
                            actionTypeId = @{ category = "Source"; owner = "AWS"; provider = "CodeCommit"; version = "1" }
                            runOrder = 1
                            configuration = @{ RepositoryName = $RepositoryName; BranchName = "main"; PollForSourceChanges = "true" }
                            outputArtifacts = @(@{ name = "SourceOutput" })
                        }
                    )
                },
                @{
                    name = "Build"
                    actions = @(
                        @{
                            name = "CodeBuildDeploy"
                            actionTypeId = @{ category = "Build"; owner = "AWS"; provider = "CodeBuild"; version = "1" }
                            runOrder = 1
                            configuration = @{ ProjectName = $ProjectName }
                            inputArtifacts = @(@{ name = "SourceOutput" })
                            outputArtifacts = @(@{ name = "BuildOutput" })
                        }
                    )
                }
            )
            version = 1
        }
    } | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($PipelinePath, $Pipeline, $Utf8NoBom)

    Write-Output "=== 3. Create or update CodePipeline ==="
    if (Test-AwsResource @("codepipeline", "get-pipeline", "--name", $PipelineName, "--region", $Region)) {
        Invoke-Aws @("codepipeline", "update-pipeline", "--cli-input-json", "file://$PipelinePath", "--region", $Region) | Out-Host
    } else {
        Invoke-Aws @("codepipeline", "create-pipeline", "--cli-input-json", "file://$PipelinePath", "--region", $Region) | Out-Host
    }

    Write-Output "=== 4. Verify pipeline stages ==="
    Invoke-Aws @(
        "codepipeline", "get-pipeline",
        "--name", $PipelineName,
        "--region", $Region,
        "--query", "pipeline.stages[].{Name:name,Actions:actions[].actionTypeId.provider}",
        "--output", "json"
    ) | Out-Host
    Invoke-Aws @(
        "codepipeline", "get-pipeline-state",
        "--name", $PipelineName,
        "--region", $Region,
        "--query", "stageStates[].{Stage:stageName,Status:latestExecution.status}",
        "--output", "json"
    ) | Out-Host

    Write-Output "Objective 5 complete. Pipeline ready: $PipelineName"
}
finally {
    Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}