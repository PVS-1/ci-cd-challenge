[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$ProjectName = "cmtr-msdta2zd-codebuild",
    [string]$RoleName = "cmtr-msdta2zd-codebuild-role"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("codebuild-" + [guid]::NewGuid().ToString("N"))
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

function Test-CodeBuildProject {
    param([Parameter(Mandatory = $true)][string]$Name)

    $ProjectNameOutput = Invoke-Aws @(
        "codebuild", "batch-get-projects",
        "--names", $Name,
        "--region", $Region,
        "--query", "projects[0].name",
        "--output", "text"
    )

    return ($ProjectNameOutput.Trim() -eq $Name)
}

try {
    $AccountId = (Invoke-Aws @("sts", "get-caller-identity", "--query", "Account", "--output", "text")).Trim()
    $RoleArn = "arn:aws:iam::${AccountId}:role/${RoleName}"
    $ArtifactBucket = "cmtr-msdta2zd-pipeline-artifacts-${AccountId}"

    $TrustPolicyPath = Join-Path $TempDirectory "codebuild-trust.json"
    $TrustPolicy = @'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "codebuild.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
'@
    [System.IO.File]::WriteAllText($TrustPolicyPath, $TrustPolicy, $Utf8NoBom)

    $PolicyPath = Join-Path $TempDirectory "codebuild-policy.json"
    $Policy = @{
        Version = "2012-10-17"
        Statement = @(
            @{
                Effect = "Allow"
                Action = @("logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents")
                Resource = "arn:aws:logs:${Region}:${AccountId}:log-group:/aws/codebuild/${ProjectName}:*"
            },
            @{
                Effect = "Allow"
                Action = @("s3:GetObject", "s3:GetObjectVersion", "s3:PutObject")
                Resource = "arn:aws:s3:::${ArtifactBucket}/*"
            },
            @{
                Effect = "Allow"
                Action = "ssm:GetParameter"
                Resource = @(
                    "arn:aws:ssm:${Region}:${AccountId}:parameter/cmtr-msdta2zd/*",
                    "arn:aws:ssm:ap-south-1:${AccountId}:parameter/cmtr-msdta2zd/*"
                )
            },
            @{
                Effect = "Allow"
                Action = "ec2:DescribeVpcs"
                Resource = "*"
            },
            @{
                Effect = "Allow"
                Action = @("cloudformation:CreateStack", "cloudformation:UpdateStack", "cloudformation:DescribeStacks", "cloudformation:DescribeStackEvents", "cloudformation:DescribeStackResources", "cloudformation:GetTemplate", "cloudformation:CreateChangeSet", "cloudformation:DescribeChangeSet", "cloudformation:ExecuteChangeSet", "cloudformation:DeleteChangeSet")
                Resource = "arn:aws:cloudformation:${Region}:${AccountId}:stack/cmtr-msdta2zd-r53-stack/*"
            },
            @{
                Effect = "Allow"
                Action = @("route53:CreateHostedZone", "route53:DeleteHostedZone", "route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ChangeResourceRecordSets", "route53:GetChange", "route53:CreateHealthCheck", "route53:DeleteHealthCheck", "route53:GetHealthCheck")
                Resource = "*"
            }
        )
    } | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($PolicyPath, $Policy, $Utf8NoBom)

    Write-Output "=== 1. Create or verify CodeBuild service role ==="
    if (-not (Test-AwsResource @("iam", "get-role", "--role-name", $RoleName))) {
        Invoke-Aws @("iam", "create-role", "--role-name", $RoleName, "--assume-role-policy-document", "file://$TrustPolicyPath") | Out-Host
    } else {
        Write-Output "Role already exists: $RoleName"
    }
    Invoke-Aws @("iam", "put-role-policy", "--role-name", $RoleName, "--policy-name", "Route53FailoverDeployment", "--policy-document", "file://$PolicyPath") | Out-Host

    $ProjectArguments = @(
        "--name", $ProjectName,
        "--source", "type=CODEPIPELINE,buildspec=buildspec.yml",
        "--artifacts", "type=CODEPIPELINE",
        "--environment", "type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=false",
        "--service-role", $RoleArn,
        "--timeout-in-minutes", "15",
        "--region", $Region
    )

    Write-Output "=== 2. Create or update CodeBuild project ==="
    if (Test-CodeBuildProject -Name $ProjectName) {
        Invoke-Aws (@("codebuild", "update-project") + $ProjectArguments) | Out-Host
    } else {
        Invoke-Aws (@("codebuild", "create-project") + $ProjectArguments) | Out-Host
    }

    Write-Output "=== 3. Verify project and role policy ==="
    Invoke-Aws @(
        "codebuild", "batch-get-projects",
        "--names", $ProjectName,
        "--region", $Region,
        "--query", "projects[0].{Name:name,Source:source.type,Artifacts:artifacts.type,Role:serviceRole,Image:environment.image}",
        "--output", "json"
    ) | Out-Host
    Invoke-Aws @(
        "iam", "get-role-policy",
        "--role-name", $RoleName,
        "--policy-name", "Route53FailoverDeployment",
        "--query", "PolicyDocument.Statement[].Action",
        "--output", "json"
    ) | Out-Host

    Write-Output "Objective 4 complete. CodeBuild project and least-privilege role are ready."
}
finally {
    Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}