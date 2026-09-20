$ErrorActionPreference = "Stop"

# OBJECTIVE 1: create Elastic Beanstalk application and environment.
# This is a standalone PowerShell script. It does not call any other local file.

$Region = "eu-west-1"
$ApplicationName = "cmtr-msdta2zd-app"
$EnvironmentName = "cmtr-msdta2zd-env"
$ServiceRoleName = "ElasticBeanstalkServiceRole"
$InstanceProfileName = "ElasticBeanstalkInstanceProfileRole"
$VpcName = "cmtr-msdta2zd-vpc"
$VpcCidr = "10.0.0.0/16"

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

    & aws @Arguments *> $null
    return $LASTEXITCODE -eq 0
}

function Ensure-ManagedPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RoleName,
        [Parameter(Mandatory = $true)]
        [string]$PolicyArn
    )

    $attachedPolicies = [string](Invoke-AwsCli @(
        "iam", "list-attached-role-policies",
        "--role-name", $RoleName,
        "--query", "AttachedPolicies[].PolicyArn",
        "--output", "text"
    ))

    if ($attachedPolicies -match [regex]::Escape($PolicyArn)) {
        Write-Output "Policy already attached: $PolicyArn"
        return
    }

    Invoke-AwsCli @(
        "iam", "attach-role-policy",
        "--role-name", $RoleName,
        "--policy-arn", $PolicyArn
    ) | Out-Host
}

$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("elastic-beanstalk-objective-1-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    Write-Output "=== 1. Verify AWS identity ==="
    Invoke-AwsCli @(
        "sts", "get-caller-identity",
        "--query", "{Account:Account,Arn:Arn}",
        "--output", "json"
    )

    $PlatformArn = $env:PLATFORM_ARN
    if ([string]::IsNullOrWhiteSpace($PlatformArn)) {
        $PlatformArn = [string](Invoke-AwsCli @(
            "elasticbeanstalk", "list-platform-versions",
            "--region", $Region,
            "--filters", "Type=PlatformName,Operator=Contains,Values=Python",
            "--max-items", "100",
            "--query", "reverse(sort_by(PlatformSummaryList,&PlatformVersion))[0].PlatformArn",
            "--output", "text"
        )).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($PlatformArn) -or $PlatformArn -eq "None") {
        throw "Could not find a Python Elastic Beanstalk platform."
    }

    Write-Output "Using Python platform: $PlatformArn"

    $ElasticBeanstalkTrustPath = Join-Path $TempDirectory "elasticbeanstalk-trust.json"
    $Ec2TrustPath = Join-Path $TempDirectory "ec2-trust.json"

    $ElasticBeanstalkTrust = @'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "elasticbeanstalk.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
'@

    $Ec2Trust = @'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
'@

    [System.IO.File]::WriteAllText($ElasticBeanstalkTrustPath, $ElasticBeanstalkTrust, $Utf8NoBom)
    [System.IO.File]::WriteAllText($Ec2TrustPath, $Ec2Trust, $Utf8NoBom)

    Write-Output "=== 2. Create or verify Elastic Beanstalk service role ==="
    if (-not (Test-AwsResource @("iam", "get-role", "--role-name", $ServiceRoleName))) {
        Invoke-AwsCli @(
            "iam", "create-role",
            "--role-name", $ServiceRoleName,
            "--assume-role-policy-document", "file://$ElasticBeanstalkTrustPath"
        ) | Out-Host
    } else {
        Write-Output "Already exists: $ServiceRoleName"
    }

    Ensure-ManagedPolicy -RoleName $ServiceRoleName -PolicyArn "arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth"

    Write-Output "=== 3. Create or verify EC2 instance profile role ==="
    if (-not (Test-AwsResource @("iam", "get-role", "--role-name", $InstanceProfileName))) {
        Invoke-AwsCli @(
            "iam", "create-role",
            "--role-name", $InstanceProfileName,
            "--assume-role-policy-document", "file://$Ec2TrustPath"
        ) | Out-Host
    } else {
        Write-Output "Already exists: $InstanceProfileName"
    }

    Ensure-ManagedPolicy -RoleName $InstanceProfileName -PolicyArn "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier"

    if (-not (Test-AwsResource @("iam", "get-instance-profile", "--instance-profile-name", $InstanceProfileName))) {
        Invoke-AwsCli @(
            "iam", "create-instance-profile",
            "--instance-profile-name", $InstanceProfileName
        ) | Out-Host
    } else {
        Write-Output "Instance profile already exists: $InstanceProfileName"
    }

    $ProfileRoles = [string](Invoke-AwsCli @(
        "iam", "get-instance-profile",
        "--instance-profile-name", $InstanceProfileName,
        "--query", "InstanceProfile.Roles[].RoleName",
        "--output", "text"
    ))

    if ($ProfileRoles -notmatch [regex]::Escape($InstanceProfileName)) {
        Invoke-AwsCli @(
            "iam", "add-role-to-instance-profile",
            "--instance-profile-name", $InstanceProfileName,
            "--role-name", $InstanceProfileName
        ) | Out-Host
    } else {
        Write-Output "Role already attached: $InstanceProfileName"
    }

    Write-Output "=== 4. Create or verify public VPC networking ==="
    $VpcId = [string](Invoke-AwsCli @(
        "ec2", "describe-vpcs",
        "--filters", "Name=tag:Name,Values=$VpcName",
        "--region", $Region,
        "--query", "Vpcs[0].VpcId",
        "--output", "text"
    )).Trim()

    if ([string]::IsNullOrWhiteSpace($VpcId) -or $VpcId -eq "None") {
        $VpcId = [string](Invoke-AwsCli @(
            "ec2", "create-vpc",
            "--cidr-block", $VpcCidr,
            "--region", $Region,
            "--query", "Vpc.VpcId",
            "--output", "text"
        )).Trim()
        Invoke-AwsCli @("ec2", "create-tags", "--resources", $VpcId, "--tags", "Key=Name,Value=$VpcName", "--region", $Region) | Out-Host
        Invoke-AwsCli @("ec2", "modify-vpc-attribute", "--vpc-id", $VpcId, "--enable-dns-support", "Value=true", "--region", $Region) | Out-Host
        Invoke-AwsCli @("ec2", "modify-vpc-attribute", "--vpc-id", $VpcId, "--enable-dns-hostnames", "Value=true", "--region", $Region) | Out-Host
    } else {
        Write-Output "Already exists: VPC $VpcId"
    }

    $InternetGatewayId = [string](Invoke-AwsCli @(
        "ec2", "describe-internet-gateways",
        "--filters", "Name=attachment.vpc-id,Values=$VpcId",
        "--region", $Region,
        "--query", "InternetGateways[0].InternetGatewayId",
        "--output", "text"
    )).Trim()

    if ([string]::IsNullOrWhiteSpace($InternetGatewayId) -or $InternetGatewayId -eq "None") {
        $InternetGatewayId = [string](Invoke-AwsCli @(
            "ec2", "create-internet-gateway",
            "--region", $Region,
            "--query", "InternetGateway.InternetGatewayId",
            "--output", "text"
        )).Trim()
        Invoke-AwsCli @("ec2", "create-tags", "--resources", $InternetGatewayId, "--tags", "Key=Name,Value=$VpcName-igw", "--region", $Region) | Out-Host
        Invoke-AwsCli @("ec2", "attach-internet-gateway", "--internet-gateway-id", $InternetGatewayId, "--vpc-id", $VpcId, "--region", $Region) | Out-Host
    }

    $RouteTableId = [string](Invoke-AwsCli @(
        "ec2", "describe-route-tables",
        "--filters", "Name=vpc-id,Values=$VpcId", "Name=tag:Name,Values=$VpcName-public-routes",
        "--region", $Region,
        "--query", "RouteTables[0].RouteTableId",
        "--output", "text"
    )).Trim()

    if ([string]::IsNullOrWhiteSpace($RouteTableId) -or $RouteTableId -eq "None") {
        $RouteTableId = [string](Invoke-AwsCli @(
            "ec2", "create-route-table",
            "--vpc-id", $VpcId,
            "--region", $Region,
            "--query", "RouteTable.RouteTableId",
            "--output", "text"
        )).Trim()
        Invoke-AwsCli @("ec2", "create-tags", "--resources", $RouteTableId, "--tags", "Key=Name,Value=$VpcName-public-routes", "--region", $Region) | Out-Host
    }

    $DefaultRouteGateway = [string](Invoke-AwsCli @(
        "ec2", "describe-route-tables",
        "--route-table-ids", $RouteTableId,
        "--region", $Region,
        "--query", "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]",
        "--output", "text"
    )).Trim()
    if ([string]::IsNullOrWhiteSpace($DefaultRouteGateway) -or $DefaultRouteGateway -eq "None") {
        Invoke-AwsCli @("ec2", "create-route", "--route-table-id", $RouteTableId, "--destination-cidr-block", "0.0.0.0/0", "--gateway-id", $InternetGatewayId, "--region", $Region) | Out-Host
    }

    $AvailabilityZones = @(([string](Invoke-AwsCli @(
        "ec2", "describe-availability-zones",
        "--filters", "Name=state,Values=available",
        "--region", $Region,
        "--query", "AvailabilityZones[].ZoneName",
        "--output", "text"
    ))).Trim() -split "\s+") | Where-Object { $_ }

    if ($AvailabilityZones.Count -lt 2) {
        throw "At least two availability zones are required for Elastic Beanstalk."
    }

    $SubnetIds = @()
    $SubnetDefinitions = @(
        @{ Name = "$VpcName-public-1"; Cidr = "10.0.1.0/24"; Zone = $AvailabilityZones[0] },
        @{ Name = "$VpcName-public-2"; Cidr = "10.0.2.0/24"; Zone = $AvailabilityZones[1] }
    )

    foreach ($SubnetDefinition in $SubnetDefinitions) {
        $SubnetId = [string](Invoke-AwsCli @(
            "ec2", "describe-subnets",
            "--filters", "Name=vpc-id,Values=$VpcId", "Name=tag:Name,Values=$($SubnetDefinition.Name)",
            "--region", $Region,
            "--query", "Subnets[0].SubnetId",
            "--output", "text"
        )).Trim()

        if ([string]::IsNullOrWhiteSpace($SubnetId) -or $SubnetId -eq "None") {
            $SubnetId = [string](Invoke-AwsCli @(
                "ec2", "describe-subnets",
                "--filters", "Name=vpc-id,Values=$VpcId", "Name=cidr-block,Values=$($SubnetDefinition.Cidr)",
                "--region", $Region,
                "--query", "Subnets[0].SubnetId",
                "--output", "text"
            )).Trim()

            if (-not [string]::IsNullOrWhiteSpace($SubnetId) -and $SubnetId -ne "None") {
                Invoke-AwsCli @(
                    "ec2", "create-tags",
                    "--resources", $SubnetId,
                    "--tags", "Key=Name,Value=$($SubnetDefinition.Name)",
                    "--region", $Region
                ) | Out-Host
                Write-Output "Using existing subnet $SubnetId for CIDR $($SubnetDefinition.Cidr)"
            }
        }

        if ([string]::IsNullOrWhiteSpace($SubnetId) -or $SubnetId -eq "None") {
            $SubnetId = [string](Invoke-AwsCli @(
                "ec2", "create-subnet",
                "--vpc-id", $VpcId,
                "--cidr-block", $SubnetDefinition.Cidr,
                "--availability-zone", $SubnetDefinition.Zone,
                "--region", $Region,
                "--query", "Subnet.SubnetId",
                "--output", "text"
            )).Trim()
            Invoke-AwsCli @("ec2", "create-tags", "--resources", $SubnetId, "--tags", "Key=Name,Value=$($SubnetDefinition.Name)", "--region", $Region) | Out-Host
            Invoke-AwsCli @("ec2", "modify-subnet-attribute", "--subnet-id", $SubnetId, "--map-public-ip-on-launch", "Value=true", "--region", $Region) | Out-Host
        }

        $AssociationId = [string](Invoke-AwsCli @(
            "ec2", "describe-route-tables",
            "--filters", "Name=vpc-id,Values=$VpcId",
            "--region", $Region,
            "--query", "RouteTables[].Associations[?SubnetId=='$SubnetId'].RouteTableAssociationId | [0]",
            "--output", "text"
        )).Trim()
        if ([string]::IsNullOrWhiteSpace($AssociationId) -or $AssociationId -eq "None") {
            Invoke-AwsCli @("ec2", "associate-route-table", "--route-table-id", $RouteTableId, "--subnet-id", $SubnetId, "--region", $Region) | Out-Host
        }
        $SubnetIds += $SubnetId
    }

    Write-Output "=== 5. Create application if missing ==="
    $ApplicationExists = [string](Invoke-AwsCli @(
        "elasticbeanstalk", "describe-applications",
        "--application-names", $ApplicationName,
        "--region", $Region,
        "--query", "Applications[0].ApplicationName",
        "--output", "text"
    )).Trim()

    if ($ApplicationExists -ne $ApplicationName) {
        Invoke-AwsCli @(
            "elasticbeanstalk", "create-application",
            "--application-name", $ApplicationName,
            "--description", "Elastic Beanstalk Flask CI-CD application",
            "--region", $Region
        ) | Out-Host
    } else {
        Write-Output "Already exists: $ApplicationName"
    }

    Write-Output "=== 6. Create environment if missing ==="
    $EnvironmentState = [string](Invoke-AwsCli @(
        "elasticbeanstalk", "describe-environments",
        "--application-name", $ApplicationName,
        "--environment-names", $EnvironmentName,
        "--region", $Region,
        "--query", "Environments[0].{Name:EnvironmentName,Status:Status}",
        "--output", "json"
    )) | ConvertFrom-Json

    $EnvironmentStatus = [string]$EnvironmentState.Status
    $EnvironmentExists = [string]$EnvironmentState.Name

    if ($EnvironmentStatus -eq "Terminating") {
        throw "Environment '$EnvironmentName' is still terminating. Wait until it disappears, then rerun the script."
    }

    if ($EnvironmentStatus -eq "Terminated") {
        $EnvironmentExists = ""
    }

    if ($EnvironmentExists -ne $EnvironmentName) {
        $OptionSettingsPath = Join-Path $TempDirectory "environment-options.json"
        $OptionSettings = @(
            @{ Namespace = "aws:elasticbeanstalk:environment"; OptionName = "ServiceRole"; Value = $ServiceRoleName },
            @{ Namespace = "aws:autoscaling:launchconfiguration"; OptionName = "IamInstanceProfile"; Value = $InstanceProfileName },
            @{ Namespace = "aws:ec2:vpc"; OptionName = "VPCId"; Value = $VpcId },
            @{ Namespace = "aws:ec2:vpc"; OptionName = "Subnets"; Value = ($SubnetIds -join ",") },
            @{ Namespace = "aws:ec2:vpc"; OptionName = "ELBSubnets"; Value = ($SubnetIds -join ",") },
            @{ Namespace = "aws:ec2:vpc"; OptionName = "ELBScheme"; Value = "public" },
            @{ Namespace = "aws:ec2:vpc"; OptionName = "AssociatePublicIpAddress"; Value = "true" }
        ) | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($OptionSettingsPath, $OptionSettings, $Utf8NoBom)

        Invoke-AwsCli @(
            "elasticbeanstalk", "create-environment",
            "--application-name", $ApplicationName,
            "--environment-name", $EnvironmentName,
            "--platform-arn", $PlatformArn,
            "--option-settings", "file://$OptionSettingsPath",
            "--region", $Region
        ) | Out-Host
    } else {
        Write-Output "Already exists: $EnvironmentName"
    }

    Write-Output "=== 7. Environment status ==="
    Invoke-AwsCli @(
        "elasticbeanstalk", "describe-environments",
        "--application-name", $ApplicationName,
        "--environment-names", $EnvironmentName,
        "--region", $Region,
        "--query", "Environments[].{Name:EnvironmentName,Status:Status,Health:Health,CNAME:CNAME}",
        "--output", "table"
    )
}
finally {
    Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
