# Monitoring and Rollback with CloudWatch and CodeDeploy

## Overview

This implementation deploys the Flask application from the root of this repository to EC2 through a GitHub-triggered AWS pipeline in `eu-west-1`.

```mermaid
flowchart LR
    Developer[Developer push to main] --> GitHub[GitHub repository]
    GitHub --> Webhook[CodePipeline GitHub webhook]

    subgraph Pipeline[AWS CodePipeline]
        Source[Source]
        Build[CodeBuild]
        Deploy[CodeDeploy]
        Source --> Build --> Deploy
    end

    Webhook --> Source

    subgraph VPC[cmtr-msdta2zd-vpc]
        subgraph BuildNetwork[Private subnets]
            Build
        end
        subgraph AppNetwork[Application subnets]
            ALB[ALB: cmtr-msdta2zd-alb]
            TG[Target group: port 8000 /health]
            Blue[Blue EC2 fleet]
            Green[Green EC2 fleet]
            ALB --> TG
            TG --> Blue
            TG --> Green
        end
    end

    Deploy --> Green
    Alarm[CloudWatch alarm: ALBUnhealthy] --> Deploy
    TG --> Alarm
```

## Components

| Component | Name | Purpose |
| --- | --- | --- |
| Source | `PVS-1/ci-cd-challenge`, `main` | Stores the application and deployment files. |
| Pipeline | `cmtr-msdta2zd-codepipeline` | Orchestrates Source -> Build -> Deploy. |
| Build | `cmtr-msdta2zd-codebuild-project` | VPC-attached CodeBuild project that produces a CodeDeploy artifact. |
| Deploy | `cmtr-msdta2zd-codedeploy-application` | CodeDeploy EC2/on-premises application. |
| Deployment group | `cmtr-msdta2zd-codedeploy-deployment-group` | Blue/green deployment with ALB traffic control. |
| Load balancer | `cmtr-msdta2zd-alb` | Public HTTP endpoint. |
| Target group | `cmtr-msdta2zd-target-group` | Probes `/health` on port `8000`. |
| Monitoring | `ALBUnhealthy` | Monitors `AWS/ApplicationELB` metric `UnHealthyHostCount`. |

## Application and artifact

The deployable source is intentionally at the repository root because CodeBuild runs `buildspec.yml` from the root and CodeDeploy expects `appspec.yml` at the artifact root.

```text
app.py
requirements.txt
buildspec.yml
appspec.yml
scripts/
  install.sh
  start.sh
  stop.sh
```

`app.py` listens on `0.0.0.0:8000`, matching the pre-created target group. It serves:

- `/`: `Hello from the environment msdta2zd!`
- `/health`: HTTP 200 health response

`appspec.yml` installs the artifact at `/opt/cmtr-msdta2zd-app`.

- `install.sh` creates the virtual environment, installs Flask, and creates `cmtr-msdta2zd-app.service`.
- `start.sh` enables and starts the service.
- `stop.sh` safely stops the prior service.

## Monitoring and rollback

`ALBUnhealthy` has one 60-second evaluation period and enters `ALARM` when `UnHealthyHostCount >= 1`.

CodeDeploy alarm monitoring is enabled after the initial healthy release and automatic rollback is enabled for:

- `DEPLOYMENT_FAILURE`
- `DEPLOYMENT_STOP_ON_ALARM`
- `DEPLOYMENT_STOP_ON_REQUEST`

The initial release runs before alarm-gating is enabled because the pre-created baseline can begin unhealthy. Once the new green fleet passes the target group health check, the deployment group is updated with the final alarm-based rollback configuration.

## Verified Result

The fresh pipeline execution `fed27289-1a46-48f8-9207-8e9fc6d4eab5` completed with `Source`, `Build`, and `Deploy` all `Succeeded`. Its VPC-attached CodeBuild project used private subnets with NAT egress.

The CodeDeploy blue/green deployment `d-QUR98O9LL` completed successfully. The green target passed `/health` on port `8000`, and the ALB returned:

```text
Hello from the environment msdta2zd!
```

### Automatic rollback test

A controlled bad release made `/health` return HTTP 500. CloudWatch alarm `ALBUnhealthy` entered `ALARM`, stopping the bad deployment `d-HDLK36ALL` with error code `ALARM_ACTIVE`.

CodeDeploy then created automatic rollback deployment `d-1DBZDW9LL`:

```text
Creator: codeDeployRollback
Status: Succeeded
rollbackTriggeringDeploymentId: d-HDLK36ALL
```

The rollback restored the latest successful application artifact. The repository source was then restored to a healthy `/health` endpoint for subsequent development; do not start another deployment before submitting the lab, so the rollback artifact remains the verifier's latest successful revision.

## Azure Equivalent

The closest Azure implementation uses the following services:

| AWS implementation | Azure equivalent |
| --- | --- |
| GitHub source action + CodePipeline | Azure DevOps Pipeline or GitHub Actions |
| CodeBuild | Azure Pipelines build job or GitHub Actions runner |
| CodeDeploy blue/green EC2 fleet | Azure Container Apps revisions with traffic splitting, or App Service deployment slots |
| ALB target group health check | Container Apps/App Service health probe, optionally Azure Front Door or Application Gateway probe |
| CloudWatch `ALBUnhealthy` | Azure Monitor metric alert on failed health probes or unavailable replicas |
| CodeDeploy alarm rollback | Revision traffic shift back to the prior revision, or App Service slot swap-back |
| S3 artifact bucket | Pipeline artifact storage or Azure Blob Storage |
| IAM instance/service roles | Managed Identity and Azure RBAC |

For a containerized API, Azure Container Apps is the closest operational match:

1. Build and publish the image to Azure Container Registry.
2. Deploy a new Container Apps revision with `0%` traffic.
3. Wait for its health probe to pass.
4. Shift traffic progressively or directly to the new revision.
5. Azure Monitor evaluates availability/health alerts.
6. On an alert, route traffic back to the prior healthy revision.

Use Managed Identity for registry, Key Vault, and telemetry access; do not place credentials in pipeline variables or application source.

## Verification

```powershell
$region = "eu-west-1"

aws codepipeline get-pipeline-state `
  --name cmtr-msdta2zd-codepipeline `
  --region $region

aws codebuild batch-get-projects `
  --names cmtr-msdta2zd-codebuild-project `
  --region $region

aws cloudwatch describe-alarms `
  --alarm-names ALBUnhealthy `
  --region $region

aws deploy get-deployment-group `
  --application-name cmtr-msdta2zd-codedeploy-application `
  --deployment-group-name cmtr-msdta2zd-codedeploy-deployment-group `
  --region $region

$dns = aws elbv2 describe-load-balancers `
  --names cmtr-msdta2zd-alb `
  --region $region `
  --query "LoadBalancers[0].DNSName" `
  --output text

Invoke-WebRequest "http://$dns/" -UseBasicParsing
```

No AWS credentials or GitHub tokens are stored in the repository.
