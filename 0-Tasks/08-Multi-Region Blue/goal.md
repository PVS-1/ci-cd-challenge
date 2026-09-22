# Task 08: Multi-Region Blue/Green CI/CD

## Architecture
Blue/Green Multi-Region CI/CD
Git commit
• app.py
• Dockerfile
CodePipeline
Source
CodeCommit
Build
Docker→ECR
Deploy Region1
us-east-1
Deploy Region2
eu-west-1
trigger
push
Route 53 Failover
Primary: us-east-1
Secondary: eu-west-1
eu-west-1 (Secondary)
ALB + Blue ASG
Green ASG (Auto-created)
ECR
Main
Failover
us-east-1 (Primary)
ALB + Blue ASG
Green ASG (Auto-created)
## The Goal of the Task
To build a fully automated, multi-regional CI/CD pipeline that deploys a containerized Python application to EC2 instances using AWS CodePipeline, CodeBuild, and CodeDeploy with a blue/green deployment strategy, including Route 53 failover routing for high availability across two AWS regions.

The pipeline automatically builds a Docker image, pushes it to Amazon ECR, and performs blue/green deployments to Auto Scaling Groups behind Application Load Balancers in two regions. Route 53 health checks monitor the ALBs and automatically failover to the secondary region if the primary becomes unhealthy.

## Task Resources
In this task, you will work with pre-deployed infrastructure and need to create additional resources to complete the CI/CD pipeline.

Pre-Deployed Infrastructure

The following resources have been deployed for you via CloudFormation:

Region 1 (us-east-1)

VPC cmtr-msdta2zd-vpc-us-east-1: VPC with CIDR 10.0.0.0/16
Subnets: Two public subnets in different availability zones
Security Groups: Security groups for ALB and EC2 instances (HTTP/8080 allowed)
Application Load Balancer cmtr-msdta2zd-alb-us-east-1: Internet-facing ALB with health checks
Target Group cmtr-msdta2zd-app-us-east-1: Target group for application instances (port 8080)
Auto Scaling Group cmtr-msdta2zd-asg-blue-us-east-1: Blue environment ASG with 2 instances
Launch Template: Pre-configured with Docker, CodeDeploy agent, and IAM instance profile
IAM Roles: EC2 instance role with permissions for ECR, CodeDeploy, SSM, and CloudWatch
Region 2 (eu-west-1)

VPC cmtr-msdta2zd-vpc-eu-west-1: VPC with CIDR 10.0.0.0/16
Subnets: Two public subnets in different availability zones
Security Groups: Security groups for ALB and EC2 instances (HTTP/8080 allowed)
Application Load Balancer cmtr-msdta2zd-alb-eu-west-1: Internet-facing ALB with health checks
Target Group cmtr-msdta2zd-app-eu-west-1: Target group for application instances (port 8080)
Auto Scaling Group cmtr-msdta2zd-asg-blue-eu-west-1: Blue environment ASG with 2 instances
Launch Template: Pre-configured with Docker, CodeDeploy agent, and IAM instance profile
IAM Roles: EC2 instance role with permissions for ECR, CodeDeploy, SSM, and CloudWatch
Pipeline Region (us-east-1)

CodeCommit Repository cmtr-msdta2zd-repo: Git repository containing application source code (Dockerfile, app.py, requirements.txt)
Test EC2 Instance cmtr-msdta2zd-test-us-east-1: Pre-deployed test instance for pipeline verification and functional testing
Pre-Deployed Infrastructure
Pipeline Region (us-east-1)
CodeCommit
(cmtr-msdta2zd-repo)
IAM Roles (EC2)
Region 1 (us-east-1) - Primary
VPC (cmtr-msdta2zd-vpc-us-east-1)
Internet Gateway
ALB (cmtr-msdta2zd-alb-us-east-1)
Target Group
(cmtr-msdta2zd-app-us-east-1)
🔒
Security Groups
Region 2 (eu-west-1) - Secondary
VPC (cmtr-msdta2zd-vpc-eu-west-1)
Internet Gateway
ALB (cmtr-msdta2zd-alb-eu-west-1)
Target Group
(cmtr-msdta2zd-app-eu-west-1)
🔒
Security Groups
AWS CodeCommit
## Resources You Will Create

Amazon ECR repository cmtr-msdta2zd-north-pole in us-east-1.
IAM roles: cmtr-msdta2zd-codebuild-role, cmtr-msdta2zd-codedeploy-role, cmtr-msdta2zd-pipeline-role.
S3 buckets for artifacts: cmtr-msdta2zd-artifacts-us-east-1 (in us-east-1), cmtr-msdta2zd-artifacts-eu-west-1 (in eu-west-1).
CodeBuild project cmtr-msdta2zd-docker-build.
CodeDeploy applications: cmtr-msdta2zd-app-us-east-1 (in us-east-1), cmtr-msdta2zd-app-eu-west-1 (in eu-west-1).
CodeDeploy deployment groups: cmtr-msdta2zd-dg-us-east-1 (in us-east-1), cmtr-msdta2zd-dg-eu-west-1 (in eu-west-1).
CodePipeline cmtr-msdta2zd-cicd-pipeline.
Route 53 private hosted zone cmtr-msdta2zd-zone with failover records and health checks.
## Objectives
In this lab, you will complete the following tasks to build a fully automated multi-regional CI/CD pipeline with blue/green deployment and automatic failover:

Prepare the CodeCommit Repository
The pipeline uses the CodeCommit repository cmtr-msdta2zd-repo in us-east-1. Ensure it contains the application code plus required deployment files for automated builds and deployments: buildspec.yml, appspec.yml, and the scripts/ directory with three lifecycle hook scripts used by CodeDeploy during blue/green deployment:

scripts/stop_container.sh — stops and removes the currently running application container named cmtr-msdta2zd-north-pole (if any) before the new version is installed, ensuring a clean state for the next deployment.
scripts/after_install.sh — runs after the deployment artifact is copied to the instance: authenticates to Amazon ECR and pulls the new Docker image so it is ready to start.
scripts/start_container.sh — starts the new application container named cmtr-msdta2zd-north-pole from the pulled image, binding it to port 8080, so the instance begins serving traffic.
Create an Amazon ECR Repository
Set up a Docker image registry in us-east-1 where CodeBuild will push the built container images. (ECR repository cmtr-msdta2zd-north-pole)

Create IAM Policies and Roles
Implement least-privilege IAM policies and create service roles for CodeBuild, CodeDeploy, and CodePipeline to securely interact with AWS services. Create three customer managed policies and attach them to the corresponding service roles:

Policy cmtr-CodeBuild-pipeline (attached to CodeBuild role cmtr-msdta2zd-codebuild-role): grants permissions for CloudWatch Logs (create log groups/streams, put log events), S3 (get/put objects in artifact buckets), ECR (authorization token, image push/pull), and CodeCommit (GitPull).
Policy cmtr-CodeDeploy-blue-green (attached to CodeDeploy role cmtr-msdta2zd-codedeploy-role): grants permissions for EC2 (RunInstances, CreateTags) and IAM PassRole to EC2 service, required for blue/green deployments with Auto Scaling Group copy; additionally attach the AWS managed policy AWSCodeDeployRole.
Policy cmtr-CodePipeline-artifacts (attached to CodePipeline role cmtr-msdta2zd-pipeline-role): grants permissions for S3 (get/put pipeline artifacts), CodeCommit (read branches, commits, and repository; upload archive), CodeBuild (start builds, get build status), and CodeDeploy (create deployments, register revisions, get deployment status).
Create S3 Artifact Buckets for CodePipeline
Provision S3 buckets in both regions to store pipeline artifacts, enabling parallel multi-region deployments. When creating each bucket, keep Block Public Access settings at defaults and enable versioning after creation. (Bucket cmtr-msdta2zd-artifacts-us-east-1 in us-east-1, Bucket cmtr-msdta2zd-artifacts-eu-west-1 in eu-west-1)

Create the CodeBuild Project
Configure CodeBuild to pull application code, build a Docker image using buildspec.yml, and push the image to ECR. (CodeBuild project cmtr-msdta2zd-docker-build) Use the following configuration when creating the project:

Source: provider AWS CodeCommit, repository cmtr-msdta2zd-repo, reference type Branch, branch main; leave source version at default (CodePipeline will override it at runtime).
Environment: Managed image, EC2 compute, Container running mode, Amazon Linux OS, Standard runtime, ARM (aarch64) architecture image (e.g. aws/codebuild/amazonlinux2-aarch64-standard:3.0); service role — existing role cmtr-msdta2zd-codebuild-role; enable Privileged mode (required for Docker build).
Environment variables: AWS_DEFAULT_REGION = us-east-1, AWS_ACCOUNT_ID = 600627326007, IMAGE_REPO_NAME = cmtr-msdta2zd-north-pole. These variables are required for ECR login, image tagging, and pushes — missing values will cause build failures.
Buildspec: Use a buildspec file, name buildspec.yml (repository root).
Blue/Green Deployment Flow region us-east-1
Step 1: Blue live
ALB + TG
100% traffic
Blue ASG (2)
cmtr-msdta2zd-asg-blue-us-east-1
Step 2: Create green
ALB + TG
100% traffic
Blue ASG
cmtr-msdta2zd-asg-blue-us-east-1
Green ASG
(build)
CodeDeploy copies
ASG config
Step 3: Test green
ALB + TG
100% traffic
Health checks
Blue ASG
cmtr-msdta2zd-asg-blue-us-east-1
Green ASG
(2) ✓
✓ Healthy instances
✓ Containers running
✓ Checks passing
Step 4: Shift traffic
ALB + TG
0% traffic
100% traffic
Blue ASG
No traffic
Green ASG
Active
✓ TG updated
✓ Traffic shifted
✓ Zero downtime
⏱ Wait for termination
Step 5: Green is blue
ALB + TG
100% traffic
Green ASG → Blue (2)
✓ Old blue removed
✓ Green becomes blue
✓ Deploy done
⏱ ~10-12 minutes per region
Create CodeDeploy Applications and Deployment Groups (Both Regions)
Set up CodeDeploy for blue/green deployment in both regions using pre-deployed Auto Scaling Groups and ALB target groups. Create one application and one deployment group per region:

Region 1 (us-east-1)

Application name: cmtr-msdta2zd-app-us-east-1, Compute platform: EC2/On-premises.
Deployment group name: cmtr-msdta2zd-dg-us-east-1; service role: cmtr-msdta2zd-codedeploy-role; deployment type: Blue/green.
Environment configuration: Automatically copy Amazon EC2 Auto Scaling group — choose cmtr-msdta2zd-asg-blue-us-east-1.
Deployment settings: Reroute traffic immediately; terminate original instances; set termination delay to 0 days, 0 hours, 0 minutes.
Load balancer: Application Load Balancer type, target group cmtr-msdta2zd-app-us-east-1.
Region 2 (eu-west-1)

Application name: cmtr-msdta2zd-app-eu-west-1, Compute platform: EC2/On-premises.
Deployment group name: cmtr-msdta2zd-dg-eu-west-1; service role: cmtr-msdta2zd-codedeploy-role; deployment type: Blue/green.
Environment configuration: Automatically copy Amazon EC2 Auto Scaling group — choose cmtr-msdta2zd-asg-blue-eu-west-1.
Deployment settings: Reroute traffic immediately; terminate original instances; set termination delay to 0 days, 0 hours, 0 minutes.
Load balancer: Application Load Balancer type, target group cmtr-msdta2zd-app-eu-west-1.
Create the CodePipeline (Source, Build, and Deploy)
Build an end-to-end CI/CD pipeline that orchestrates code commit detection, builds, and parallel deployments to both regions with multi-region artifact stores. (CodePipeline cmtr-msdta2zd-cicd-pipeline with Source → Build → Deploy stages for both regions)

Pipeline settings: name cmtr-msdta2zd-cicd-pipeline; execution mode: Queued; service role — existing role cmtr-msdta2zd-pipeline-role.

Source stage: provider AWS CodeCommit, repository cmtr-msdta2zd-repo, branch main; enable EventBridge rule for automatic change detection; output artifact format: CodePipeline default.

Build stage: provider AWS CodeBuild, project cmtr-msdta2zd-docker-build, build type: Single build, region us-east-1, input artifact: SourceArtifact.

Test stage: skip.

Deploy stage: skip during initial creation — the deploy stage will be added after updating the pipeline to use multi-region artifact stores.

After creating the pipeline, perform two additional steps:

Step 7.1 — Switch to multi-region artifact stores: The pipeline is created with a single artifactStore. To enable parallel deployments to both regions, export the pipeline configuration to a JSON file using the AWS CLI, replace the artifactStore key with artifactStores that maps each region to its artifact bucket (cmtr-msdta2zd-artifacts-us-east-1 for us-east-1, cmtr-msdta2zd-artifacts-eu-west-1 for eu-west-1), then upload the updated configuration back using the AWS CLI. Note: the JSON file must contain only the pipeline object (no metadata).

Step 7.2 — Add Deploy stage with parallel actions: Add a Deploy stage to the pipeline with two parallel CodeDeploy actions (both with runOrder: 1 so they execute simultaneously):

DeployRegion1: provider CodeDeploy, region us-east-1, application cmtr-msdta2zd-app-us-east-1, deployment group cmtr-msdta2zd-dg-us-east-1, input artifact: BuildArtifact.
DeployRegion2: provider CodeDeploy, region eu-west-1, application cmtr-msdta2zd-app-eu-west-1, deployment group cmtr-msdta2zd-dg-eu-west-1, input artifact: BuildArtifact.
The Deploy stage can be added via the AWS Console or by including the stage configuration directly in pipeline.json before uploading in Step 7.1. If adding via Console, you may see a warning "Application not found" for the Region 2 action — type the deployment group name manually, the warning will disappear after saving.

Trigger and Monitor the Pipeline
Verify the pipeline executes successfully from source detection through build and parallel deployment in both regions, confirming CodeDeploy performs blue/green updates without errors. (Successful pipeline execution with both regions deployed)

Create Route 53 Private Hosted Zone and Failover Routing
Configure DNS failover at app.cmtr-msdta2zd-zone with health checks for both regional ALBs, ensuring traffic automatically switches to the secondary region when the primary becomes unhealthy.

Step 9.1 — Create Private Hosted Zone: domain name cmtr-msdta2zd-zone, type: Private hosted zone, associated with both VPCs: cmtr-msdta2zd-vpc-us-east-1 in us-east-1 and cmtr-msdta2zd-vpc-eu-west-1 in eu-west-1.

Step 9.2 — Create Health Checks: Create two health checks monitoring each ALB endpoint by domain name:

Primary: domain name cmtr-msdta2zd-alb-us-east-1-490895504.us-east-1.elb.amazonaws.com (ALB in us-east-1), request interval: 10 seconds, failure threshold: 3.
Secondary: domain name cmtr-msdta2zd-alb-eu-west-1-537545617.eu-west-1.elb.amazonaws.com (ALB in eu-west-1), request interval: 10 seconds, failure threshold: 3.
Step 9.3 — Create Failover DNS Records: In the hosted zone cmtr-msdta2zd-zone, create two A alias records both with record name app:

Primary record: alias to ALB cmtr-msdta2zd-alb-us-east-1 in us-east-1, routing policy: Failover, failover type: Primary, health check: Region 1 ALB, evaluate target health: Yes, record ID: us-east-1.
Secondary record: alias to ALB cmtr-msdta2zd-alb-eu-west-1 in eu-west-1, routing policy: Failover, failover type: Secondary, health check: Region 2 ALB, evaluate target health: Yes, record ID: eu-west-1.
## Verification
Verify your implementation using the following steps and acceptance criteria.

Prerequisites: Test Instance (Pre-Deployed)

The test instance cmtr-msdta2zd-test-us-east-1 is pre-deployed in us-east-1 within VPC cmtr-msdta2zd-vpc-us-east-1. Use SSH or AWS Systems Manager Session Manager to connect and run verification commands.

Test 1: ECR Repository and Build Artifacts

In us-east-1, navigate to Amazon ECR → Repositories.
Confirm repository cmtr-msdta2zd-north-pole exists.
Run a test build from CodeBuild and confirm the Docker image is pushed to ECR.
Expected outcome: Docker image tags are visible in the ECR repository (e.g., latest and commit SHA tags).

Test 2: IAM Roles and Policies

In IAM → Roles, verify the three roles exist:
cmtr-msdta2zd-codebuild-role with CodeBuild-related permissions.
cmtr-msdta2zd-codedeploy-role with CodeDeploy permissions and AWSCodeDeployRole.
cmtr-msdta2zd-pipeline-role with S3, CodeCommit, CodeBuild, and CodeDeploy permissions.
Expected outcome: All three roles are present with correct trust relationships and policy attachments.

Test 3: S3 Artifact Buckets

In S3, verify two buckets exist:
cmtr-msdta2zd-artifacts-us-east-1 in us-east-1.
cmtr-msdta2zd-artifacts-eu-west-1 in eu-west-1.
Confirm versioning is enabled on both.
Expected outcome: Both buckets are present and versioning is active.

Test 4: CodeDeploy Applications and Deployment Groups

In CodeDeploy → Applications (in both us-east-1 and eu-west-1), verify:
Application cmtr-msdta2zd-app-us-east-1 in us-east-1 with deployment group cmtr-msdta2zd-dg-us-east-1.
Application cmtr-msdta2zd-app-eu-west-1 in eu-west-1 with deployment group cmtr-msdta2zd-dg-eu-west-1.
Confirm blue/green deployment type and ASG configuration.
Expected outcome: Both applications and deployment groups are configured with blue/green deployment and correct ASG references.

Test 5: CodePipeline Execution

In CodePipeline (region us-east-1), view pipeline cmtr-msdta2zd-cicd-pipeline.
Trigger a pipeline run by pushing a commit to the main branch of cmtr-msdta2zd-repo or manually start execution.
Monitor stages: Source → Build → Deploy (with parallel deployments to both regions).
Expected outcome: Pipeline completes successfully. Build stage shows Docker image built and pushed to ECR. Deploy stage shows both regions deploying in parallel (blue/green).

Test 6: Route 53 Failover and DNS Resolution

From the test instance cmtr-msdta2zd-test-us-east-1 (in VPC cmtr-msdta2zd-vpc-us-east-1), run:
dig app.cmtr-msdta2zd-zone
curl -s http://app.cmtr-msdta2zd-zone | grep -E "Region|Instance"

Expected outcome: DNS resolves to the ALB in the primary region (us-east-1), and the application responds with region/instance information.

Test 7: Failover to Secondary Region

From the AWS Console, stop all EC2 instances in ASG cmtr-msdta2zd-asg-blue-us-east-1 (Region 1).
Wait 2–3 minutes for Route 53 health check to mark the primary as unhealthy.
From the test instance, run:
dig app.cmtr-msdta2zd-zone
for i in {1..10}; do curl -s http://app.cmtr-msdta2zd-zone | grep Region; sleep 2; done

Expected outcome: DNS now resolves to the ALB in the secondary region (eu-west-1), and responses show the secondary region's instance information.

Test 8: Blue/Green Deployment Verification

Trigger a new deployment via CodePipeline (push a change to main branch).
While the deployment is in progress, from the test instance, run:
for i in {1..30}; do curl -s http://app.cmtr-msdta2zd-zone | grep -E "Region|Instance"; sleep 1; done

Expected outcome: No request failures. Instance IDs may change as traffic moves from blue to green instances, but the application remains responsive.

## Acceptance Criteria

✅ ECR repository cmtr-msdta2zd-north-pole contains Docker images pushed by CodeBuild.
✅ All three IAM roles exist with correct permissions.
✅ S3 artifact buckets exist in both regions with versioning enabled.
✅ CodeDeploy applications and deployment groups exist in both regions with blue/green configuration.
✅ CodePipeline executes successfully end-to-end (Source → Build → parallel Deploy to both regions).
✅ Route 53 health checks monitor both ALBs; DNS resolves to primary region when healthy.
✅ Failover occurs automatically when primary region becomes unhealthy; traffic switches to secondary region.
✅ Blue/green deployments occur without service interruption; no failed requests during deployment.
Deploy Time
Deployment of task resources takes up to 10 minutes to complete.

