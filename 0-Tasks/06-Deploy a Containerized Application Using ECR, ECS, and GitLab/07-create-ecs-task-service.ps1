[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$ClusterName = "cmtr-msdta2zd-cluster",
    [string]$ServiceName = "cmtr-msdta2zd-service",
    [string]$TaskFamily = "cmtr-msdta2zd-task",
    [string]$EcrRegistry = "682033508402.dkr.ecr.eu-west-1.amazonaws.com",
    [string]$EcrRepository = "cmtr-msdta2zd-static",
    [string]$ExecutionRoleName = "cmtr-msdta2zd-ecs-task-execution-role",
    [string]$TaskRoleName = "cmtr-msdta2zd-ecs-task-role",
    [string]$ContainerName = "web",
    [string]$VpcName = "cmtr-msdta2zd-ecs-vpc",
    [string]$VpcCidr = "10.60.0.0/16"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("ecs-service-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = @(& aws @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($exitCode -ne 0) {
        throw "AWS CLI failed: aws $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }
    return ($output | Out-String)
}

try {
    Write-Output "=== 1. Verify ECS cluster ==="
    Invoke-Aws @(
        "ecs", "describe-clusters",
        "--clusters", $ClusterName,
        "--region", $Region,
        "--query", "clusters[0].{Name:clusterName,Status:status}",
        "--output", "json"
    ) | Out-Host

    $AccountId = ([string](Invoke-Aws @(
        "sts", "get-caller-identity",
        "--query", "Account",
        "--output", "text"
    ))).Trim()

    $ExecutionRoleArn = "arn:aws:iam::${AccountId}:role/${ExecutionRoleName}"
    $TaskRoleArn = "arn:aws:iam::${AccountId}:role/${TaskRoleName}"
    $ImageUri = "$EcrRegistry/$EcrRepository`:latest"

    Write-Output "=== 2. Discover available subnets ==="
    $SubnetJson = Invoke-Aws @(
        "ec2", "describe-subnets",
        "--filters", "Name=state,Values=available",
        "--region", $Region,
        "--query", "Subnets[].{Id:SubnetId,VpcId:VpcId,Az:AvailabilityZone}",
        "--output", "json"
    )
    $Subnets = @($SubnetJson | ConvertFrom-Json)

    if ($Subnets.Count -lt 2) {
        Write-Output "No suitable subnets found. Creating public ECS networking."
        $VpcId = ([string](Invoke-Aws @(
            "ec2", "describe-vpcs",
            "--filters", "Name=tag:Name,Values=$VpcName",
            "--region", $Region,
            "--query", "Vpcs[0].VpcId",
            "--output", "text"
        ))).Trim()

        if ([string]::IsNullOrWhiteSpace($VpcId) -or $VpcId -eq "None") {
            $VpcId = ([string](Invoke-Aws @(
                "ec2", "create-vpc",
                "--cidr-block", $VpcCidr,
                "--region", $Region,
                "--query", "Vpc.VpcId",
                "--output", "text"
            ))).Trim()
            Invoke-Aws @("ec2", "create-tags", "--resources", $VpcId, "--tags", "Key=Name,Value=$VpcName", "--region", $Region) | Out-Host
            Invoke-Aws @("ec2", "modify-vpc-attribute", "--vpc-id", $VpcId, "--enable-dns-support", "Value=true", "--region", $Region) | Out-Host
            Invoke-Aws @("ec2", "modify-vpc-attribute", "--vpc-id", $VpcId, "--enable-dns-hostnames", "Value=true", "--region", $Region) | Out-Host
        }

        $InternetGatewayId = ([string](Invoke-Aws @(
            "ec2", "describe-internet-gateways",
            "--filters", "Name=attachment.vpc-id,Values=$VpcId",
            "--region", $Region,
            "--query", "InternetGateways[0].InternetGatewayId",
            "--output", "text"
        ))).Trim()
        if ([string]::IsNullOrWhiteSpace($InternetGatewayId) -or $InternetGatewayId -eq "None") {
            $InternetGatewayId = ([string](Invoke-Aws @(
                "ec2", "create-internet-gateway",
                "--region", $Region,
                "--query", "InternetGateway.InternetGatewayId",
                "--output", "text"
            ))).Trim()
            Invoke-Aws @("ec2", "attach-internet-gateway", "--internet-gateway-id", $InternetGatewayId, "--vpc-id", $VpcId, "--region", $Region) | Out-Host
        }

        $RouteTableId = ([string](Invoke-Aws @(
            "ec2", "describe-route-tables",
            "--filters", "Name=vpc-id,Values=$VpcId", "Name=tag:Name,Values=$VpcName-public-routes",
            "--region", $Region,
            "--query", "RouteTables[0].RouteTableId",
            "--output", "text"
        ))).Trim()
        if ([string]::IsNullOrWhiteSpace($RouteTableId) -or $RouteTableId -eq "None") {
            $RouteTableId = ([string](Invoke-Aws @(
                "ec2", "create-route-table",
                "--vpc-id", $VpcId,
                "--region", $Region,
                "--query", "RouteTable.RouteTableId",
                "--output", "text"
            ))).Trim()
            Invoke-Aws @("ec2", "create-tags", "--resources", $RouteTableId, "--tags", "Key=Name,Value=$VpcName-public-routes", "--region", $Region) | Out-Host
            Invoke-Aws @("ec2", "create-route", "--route-table-id", $RouteTableId, "--destination-cidr-block", "0.0.0.0/0", "--gateway-id", $InternetGatewayId, "--region", $Region) | Out-Host
        }

        $AvailabilityZones = @(([string](Invoke-Aws @(
            "ec2", "describe-availability-zones",
            "--filters", "Name=state,Values=available",
            "--region", $Region,
            "--query", "AvailabilityZones[].ZoneName",
            "--output", "text"
        ))).Trim() -split "\s+") | Where-Object { $_ }
        if ($AvailabilityZones.Count -lt 2) {
            throw "At least two availability zones are required."
        }

        $SubnetIds = @()
        foreach ($SubnetSpec in @(
            @{ Name = "$VpcName-public-1"; Cidr = "10.60.1.0/24"; Zone = $AvailabilityZones[0] },
            @{ Name = "$VpcName-public-2"; Cidr = "10.60.2.0/24"; Zone = $AvailabilityZones[1] }
        )) {
            $SubnetId = ([string](Invoke-Aws @(
                "ec2", "describe-subnets",
                "--filters", "Name=vpc-id,Values=$VpcId", "Name=cidr-block,Values=$($SubnetSpec.Cidr)",
                "--region", $Region,
                "--query", "Subnets[0].SubnetId",
                "--output", "text"
            ))).Trim()
            if ([string]::IsNullOrWhiteSpace($SubnetId) -or $SubnetId -eq "None") {
                $SubnetId = ([string](Invoke-Aws @(
                    "ec2", "create-subnet",
                    "--vpc-id", $VpcId,
                    "--cidr-block", $SubnetSpec.Cidr,
                    "--availability-zone", $SubnetSpec.Zone,
                    "--region", $Region,
                    "--query", "Subnet.SubnetId",
                    "--output", "text"
                ))).Trim()
                Invoke-Aws @("ec2", "create-tags", "--resources", $SubnetId, "--tags", "Key=Name,Value=$($SubnetSpec.Name)", "--region", $Region) | Out-Host
                Invoke-Aws @("ec2", "modify-subnet-attribute", "--subnet-id", $SubnetId, "--map-public-ip-on-launch", "Value=true", "--region", $Region) | Out-Host
            }
            Invoke-Aws @("ec2", "associate-route-table", "--route-table-id", $RouteTableId, "--subnet-id", $SubnetId, "--region", $Region) | Out-Host
            $SubnetIds += $SubnetId
        }
        $Subnets = @($SubnetIds | ForEach-Object { [pscustomobject]@{ Id = $_; VpcId = $VpcId } })
    }

    $SelectedSubnets = @($Subnets | Select-Object -First 2)
    $VpcId = $SelectedSubnets[0].VpcId
    if (($SelectedSubnets | Where-Object { $_.VpcId -ne $VpcId }).Count -gt 0) {
        throw "The first available subnets are in different VPCs. Pass explicit subnet parameters after inspecting AWS networking."
    }
    $SubnetIds = @($SelectedSubnets | ForEach-Object Id)
    Write-Output "Using VPC: $VpcId"
    Write-Output "Using subnets: $($SubnetIds -join ', ')"

    Write-Output "=== 3. Create or verify security group ==="
    $SecurityGroupName = "cmtr-msdta2zd-ecs-http"
    $SecurityGroupId = ([string](Invoke-Aws @(
        "ec2", "describe-security-groups",
        "--filters", "Name=vpc-id,Values=$VpcId", "Name=group-name,Values=$SecurityGroupName",
        "--region", $Region,
        "--query", "SecurityGroups[0].GroupId",
        "--output", "text"
    ))).Trim()

    if ([string]::IsNullOrWhiteSpace($SecurityGroupId) -or $SecurityGroupId -eq "None") {
        $SecurityGroupId = ([string](Invoke-Aws @(
            "ec2", "create-security-group",
            "--group-name", $SecurityGroupName,
            "--description", "HTTP access for ECS Fargate application",
            "--vpc-id", $VpcId,
            "--region", $Region,
            "--query", "GroupId",
            "--output", "text"
        ))).Trim()
        Invoke-Aws @("ec2", "authorize-security-group-ingress", "--group-id", $SecurityGroupId, "--protocol", "tcp", "--port", "80", "--cidr", "0.0.0.0/0", "--region", $Region) | Out-Host
    } else {
        Write-Output "Security group already exists: $SecurityGroupId"
    }

    Write-Output "=== 4. Register Fargate task definition ==="
    $LogGroupName = "/ecs/$TaskFamily"
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $LogGroupOutput = @(& aws logs create-log-group `
        --log-group-name $LogGroupName `
        --region $Region 2>&1)
    $LogGroupExitCode = $LASTEXITCODE
    $ErrorActionPreference = $PreviousErrorActionPreference
    if ($LogGroupExitCode -ne 0 -and (($LogGroupOutput | Out-String) -notmatch "ResourceAlreadyExistsException")) {
        throw "Could not create CloudWatch log group '$LogGroupName': $(($LogGroupOutput | Out-String).Trim())"
    }

    $TaskDefinitionPath = Join-Path $TempDirectory "task-definition.json"
    $TaskDefinition = @{
        family = $TaskFamily
        networkMode = "awsvpc"
        requiresCompatibilities = @("FARGATE")
        cpu = "256"
        memory = "512"
        executionRoleArn = $ExecutionRoleArn
        taskRoleArn = $TaskRoleArn
        containerDefinitions = @(
            @{
                name = $ContainerName
                image = $ImageUri
                essential = $true
                portMappings = @(@{ containerPort = 80; hostPort = 80; protocol = "tcp" })
                logConfiguration = @{
                    logDriver = "awslogs"
                    options = @{
                        "awslogs-group" = $LogGroupName
                        "awslogs-region" = $Region
                        "awslogs-stream-prefix" = "ecs"
                    }
                }
            }
        )
    } | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($TaskDefinitionPath, $TaskDefinition, $Utf8NoBom)

    $TaskDefinitionArn = ([string](Invoke-Aws @(
        "ecs", "register-task-definition",
        "--cli-input-json", "file://$TaskDefinitionPath",
        "--region", $Region,
        "--query", "taskDefinition.taskDefinitionArn",
        "--output", "text"
    ))).Trim()
    Write-Output "Task definition: $TaskDefinitionArn"

    Write-Output "=== 5. Create or verify ECS service ==="
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $ServiceJson = @(& aws ecs describe-services `
        --cluster $ClusterName `
        --services $ServiceName `
        --region $Region `
        --query "services[0].serviceName" `
        --output text 2>$null)
    $ServiceExitCode = $LASTEXITCODE
    $ErrorActionPreference = $PreviousErrorActionPreference
    $ServiceExists = $ServiceExitCode -eq 0 -and (($ServiceJson -join "").Trim() -eq $ServiceName)

    if (-not $ServiceExists) {
        $NetworkPath = Join-Path $TempDirectory "network-configuration.json"
        $NetworkConfiguration = @{
            awsvpcConfiguration = @{
                subnets = $SubnetIds
                securityGroups = @($SecurityGroupId)
                assignPublicIp = "ENABLED"
            }
        } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($NetworkPath, $NetworkConfiguration, $Utf8NoBom)

        Invoke-Aws @(
            "ecs", "create-service",
            "--cluster", $ClusterName,
            "--service-name", $ServiceName,
            "--task-definition", $TaskDefinitionArn,
            "--desired-count", "1",
            "--launch-type", "FARGATE",
            "--network-configuration", "file://$NetworkPath",
            "--region", $Region,
            "--query", "service.{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount}",
            "--output", "json"
        ) | Out-Host
    } else {
        Invoke-Aws @(
            "ecs", "update-service",
            "--cluster", $ClusterName,
            "--service", $ServiceName,
            "--task-definition", $TaskDefinitionArn,
            "--force-new-deployment",
            "--region", $Region,
            "--query", "service.{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount}",
            "--output", "json"
        ) | Out-Host
    }

    Write-Output "Objective complete. ECS service is being deployed."
}
finally {
    Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
