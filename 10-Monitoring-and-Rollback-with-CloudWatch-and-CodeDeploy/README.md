# Monitoring and Rollback with CloudWatch and CodeDeploy

## What was implemented

This folder contains a Flask application deployed to EC2 instances through:

```text
GitHub -> CodePipeline -> CodeBuild -> CodeDeploy -> ALB target group
```

The pipeline is `cmtr-msdta2zd-codepipeline` in `eu-west-1`.

- Source: GitHub repository `PVS-1/ci-cd-challenge`, branch `main`
- Build: `cmtr-msdta2zd-codebuild-project`
- Deploy: `cmtr-msdta2zd-codedeploy-application` and `cmtr-msdta2zd-codedeploy-deployment-group`
- Load balancer: `cmtr-msdta2zd-alb`
- Target group: `cmtr-msdta2zd-target-group`
- Alarm: `ALBUnhealthy`

## Application

`app.py` serves:

- `/`: `Hello from the environment msdta2zd!`
- `/health`: HTTP 200 health response

The pre-created target group uses port `8000` and health-check path `/health`, so the Flask service runs on `0.0.0.0:8000`.

## Deployment artifact

`buildspec.yml` runs inside this folder and uses `base-directory` so the CodeDeploy artifact still has this root layout:

```text
app.py
requirements.txt
appspec.yml
scripts/
```

`appspec.yml` deploys files to `/opt/cmtr-msdta2zd-app`.

- `scripts/install.sh` creates a virtual environment, installs dependencies and writes a systemd unit.
- `scripts/start.sh` enables and restarts `cmtr-msdta2zd-app.service`.
- `scripts/stop.sh` stops the prior service safely.

## Monitoring and rollback

CloudWatch alarm `ALBUnhealthy` monitors `AWS/ApplicationELB` metric `UnHealthyHostCount` for the target group and ALB.

CodeDeploy has alarm monitoring enabled and automatically rolls back for:

- `DEPLOYMENT_FAILURE`
- `DEPLOYMENT_STOP_ON_ALARM`
- `DEPLOYMENT_STOP_ON_REQUEST`

The target group uses deregistration delay `0`, so a retained old blue instance does not keep the alarm in `ALARM` after traffic moves to the healthy green fleet.

## Verified result

The successful deployment was `d-XM9LJ18LL` and the corresponding CodePipeline execution was `6176e9c8-0cd5-4b22-9df5-c77fff924649`.

Verified outcomes:

- CodeDeploy deployment: `Succeeded`
- CodePipeline execution: `Succeeded`
- Green ALB target: `healthy`
- ALB response: HTTP 200 with the required text
- CodeDeploy alarm rollback configuration: enabled

## Verification commands

```powershell
$region = "eu-west-1"

aws codepipeline get-pipeline-state `
  --name cmtr-msdta2zd-codepipeline `
  --region $region

aws elbv2 describe-target-health `
  --target-group-arn "arn:aws:elasticloadbalancing:eu-west-1:976193228318:targetgroup/cmtr-msdta2zd-target-group/f1e39d402b3f36c1" `
  --region $region

aws cloudwatch describe-alarms `
  --alarm-names ALBUnhealthy `
  --region $region

aws deploy get-deployment-group `
  --application-name cmtr-msdta2zd-codedeploy-application `
  --deployment-group-name cmtr-msdta2zd-codedeploy-deployment-group `
  --region $region
```

No AWS credentials or GitHub tokens are stored in this repository.
