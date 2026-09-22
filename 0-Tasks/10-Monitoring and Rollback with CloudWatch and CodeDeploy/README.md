# Monitoring and Rollback with CloudWatch and CodeDeploy

## Source package

`source/` contains the Flask application and CodeDeploy artifacts:

- `app.py`: `/` returns `Hello from the environment msdta2zd!`; `/health` returns a healthy response.
- `buildspec.yml`: makes CodeDeploy lifecycle scripts executable and emits a deployment artifact.
- `appspec.yml`: copies the artifact to `/opt/cmtr-msdta2zd-app` and runs CodeDeploy hooks.
- `scripts/install.sh`: creates a Python virtual environment, installs Flask and creates a systemd service.
- `scripts/start.sh`: starts the service on port `8080`.
- `scripts/stop.sh`: stops the previous service safely.

## Provisioning flow

1. Create a GitHub PAT for the repository: classic PAT requires `repo` and `admin:repo_hook`; fine-grained PAT requires repository access plus Contents read/write and Webhooks read/write permissions.
2. Run `01-stage-source.ps1` to copy source files to the root of the GitHub working tree.
3. Commit and push the copied files to `main`.
4. Run `02-provision-pipeline-monitoring.ps1` with the GitHub token and GitHub `owner/repository`.
5. Run `03-verify-monitoring-rollback.ps1` after pipeline deployment succeeds.

## Commands

```powershell
Set-Location "C:\Users\helper\OneDrive - Lizard Soft\AZURE\!!Devops_Repos\AWS Chalenges\AWS CI-CD\10-Monitoring and Rollback with CloudWatch and CodeDeploy"

.\01-stage-source.ps1 `
  -RepositoryDirectory "C:\path\to\github-working-tree"
```

Commit and push source files from the GitHub working tree:

```powershell
git add app.py requirements.txt buildspec.yml appspec.yml scripts
git commit -m "Add monitored Flask deployment"
git push
```

Provision AWS resources:

```powershell
.\02-provision-pipeline-monitoring.ps1 `
  -GitHubOAuthToken "<GitHub fine-grained PAT>" `
  -GitHubRepository "<owner>/<repository>"
```

Verify the pipeline, monitoring and rollback configuration:

```powershell
.\03-verify-monitoring-rollback.ps1
```

## What provisioning configures

- CodeBuild project `cmtr-msdta2zd-codebuild-project`.
- CodePipeline `cmtr-msdta2zd-codepipeline`: GitHub source -> CodeBuild -> CodeDeploy, plus GitHub webhook.
- Versioned private S3 artifact bucket.
- IAM roles for CodeBuild and CodePipeline with required inline permissions.
- CloudWatch alarm `ALBUnhealthy` on ALB metric `UnHealthyHostCount`.
- CodeDeploy deployment group alarm monitoring and automatic rollback on alarm/failure.

The initial deploy should make targets healthy, leaving `ALBUnhealthy` in `OK`. A later unhealthy deployment makes the alarm enter `ALARM`; CodeDeploy stops the deployment and rolls back according to its `DEPLOYMENT_STOP_ON_ALARM` configuration.

No AWS credentials or GitHub access tokens are stored in these files.
