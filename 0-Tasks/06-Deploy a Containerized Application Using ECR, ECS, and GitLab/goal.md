# Task 06: Container Deployment with ECR, ECS and GitLab CI

## Task description
## The Goal of the Task
To build a fully automated CI/CD pipeline in GitLab that deploys a containerized website to Amazon ECS (Fargate) on each commit. An example application is available here: https://gitlab.com/cmtr/module_aws_typ2_gitlab-cicd.

The diagram below illustrates the expected flow:

diagram
## Task Resources
Region-specific resources must be created in the eu-west-1 region. For more details about regional services, see AWS Services by Region.

In this task, you will work with the following resources:

Amazon ECR cmtr-msdta2zd-static: Container registry to store your Docker images. Learn more about ECR, including how to create repositories, push and pull images, and manage container images.

Amazon ECS cmtr-msdta2zd-cluster (Fargate): Compute environment that runs your containerized application. Learn more about ECS, and see Fargate launch type documentation for details on serverless container deployment.

AWS Lambda cmtr-msdta2zd-function: Orchestrates deployments to ECS when images change. Learn more about Lambda, including how to create functions, manage environment variables, and set up event-driven triggers.

Amazon EventBridge Rule: Triggers the Lambda function on new image pushes to ECR. Learn more about EventBridge, and see ECR events documentation for details on how ECR integrates with EventBridge.

GitLab Project (Fork): Fork of the sample repository that hosts your pipeline and application code.



## Objectives
You must complete the following steps:

## Create an Amazon ECR repository named cmtr-msdta2zd-static.
Fork the repository https://gitlab.com/cmtr/module_aws_typ2_gitlab-cicd to your personal GitLab account.
In your fork, create a GitLab pipeline (.gitlab-ci.yml) that builds and pushes the Docker image to cmtr-msdta2zd-static.

## Create an Amazon ECS cluster cmtr-msdta2zd-cluster using the Fargate launch type.

## Create a Lambda function cmtr-msdta2zd-function that deploys the latest image from cmtr-msdta2zd-static to cmtr-msdta2zd-cluster upon EventBridge trigger.

## Create an EventBridge rule cmtr-msdta2zd-rule that invokes cmtr-msdta2zd-function when a new image is pushed to cmtr-msdta2zd-static.
Create IAM Policies and Roles with least privilege permissions for Lambda function execution, EventBridge rule and ECS task execution
Important: When authenticating to Amazon ECR in your GitLab pipeline, always use docker login with an ECR authentication token. Do not use direct aws ecr CLI commands with AWS credentials to push images. Follow best practices and place the ECR password into a pipeline environment variable. The recommended approach is:
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY_URL}

TThis ensures proper authentication and follows Docker best practices for CI/CD pipelines.

Manual Testing
Before submitting for automated verification, you should manually test your entire pipeline to ensure everything works as expected.

### Test 1: Verify Pipeline Execution

## Trigger the pipeline:

Go to your GitLab repository.
Click CI/CD → Pipelines in the left sidebar.
Click Run pipeline button.
Select branch: main
Click Run pipeline.
Monitor pipeline execution:

Click on the running pipeline to view progress.
Watch the build stage:
Docker image should build successfully
Look for "Docker image built successfully" message
Watch the push stage:
Image should authenticate with ECR
Image should push with two tags: latest and commit SHA
Look for "Successfully pushed image to ECR" message
Check for success:

Both stages should show green checkmarks (✓)
Pipeline status should be passed
Total execution time: typically 2-5 minutes

### Test 2: Verify ECR Repository
Navigate to ECR:

Go to AWS Console → ECR.
Click on your repository cmtr-msdta2zd-static.
Verify images exist:

You should see at image tag latest - Most recent image
Check image details:

Click on an image to view details.
Verify:
Image URI: Should match your repository
Pushed at: Recent timestamp
Image size: Appropriate size for your application
Vulnerability scan: May show scan results if enabled

### Test 3: Verify EventBridge and Lambda
Check EventBridge rule:

Go to AWS Console → EventBridge.
Click Rules in the left menu.
Find rule with name you used eg. cmtr-msdta2zd-rule
Verify State: Should be Enabled
Check Lambda function logs (optional) :

Go to AWS Console → CloudWatch.
Click Log groups in the left menu.
Find log group: /aws/lambda/cmtr-msdta2zd-function
Click on the log group to view log streams.
Review latest log stream (optional) :

Click on the most recent log stream (sorted by "Last Event Time").
Look for successful execution messages:
Event received: - Lambda received ECR event
Repository: cmtr-msdta2zd-static, Tag: latest, Action: PUSH
Registered task definition: - New task definition created
Updated service: - ECS service updated successfully
Verify no errors:

Logs should not contain error messages
Status code should be 200
Look for: "message": "Service updated successfully"

### Test 4: Verify ECS Deployment
Navigate to ECS cluster:

Go to AWS Console → ECS.
Click Clusters → cmtr-msdta2zd-cluster.
Check service status:

Click Services tab.
Click on service cmtr-msdta2zd-service.
Verify Status: Should be ACTIVE
Verify Desired tasks: Should be 1
Verify Running tasks: Should be 1
Check deployments:

Click on the Deployments tab.
You should see recent deployment:
Status: PRIMARY (successful)
Running count: 1
Updated at: Recent timestamp
Rollout state: COMPLETED
Verify task is running:

Click on the Tasks tab.
You should see 1 running task.
Task Status: Should be RUNNING
Click on the task to view details.
Check task definition:

In the task details, verify:
Task Definition: Should show latest revision
Image: Should match your ECR repository URI with recent tag
Last status: Should be RUNNING

### Test 5: Access the Deployed Application
Get the public IP address:

In the ECS task details, find the Public IP address.
Example: 54.123.45.67
Access the application:

Open a web browser.
Navigate to: http://<public-ip>
Replace <public-ip> with the actual IP address.
Verify application loads:

Your static website should display correctly.
The page should show the content from content/index.html.
If you made changes in Test 1, those changes should be visible.
Troubleshoot if not accessible:

Wait 1-2 minutes for the task to fully start.
Check security group allows HTTP (port 80) from 0.0.0.0/0.
Verify the task is in RUNNING state.
Check CloudWatch logs for container errors.
Automated Verification
For solution verification, Cloud Mentor will add one file containing a verification code to the content directory of your repository. The expected behavior is that the commit starts the pipeline and the updated image reaches production in under 5 minutes. To enable verification, you should provide your GitLab project ID:

diagram
and a Personal Access Token (PAT) for the project with the following permissions: Read/Write API and Maintaitainer role. Please ensure the provided PAT belongs only to the forked repository. During verification a small file will be added/updated to content directory with verification code.

Verification initiates the pipeline and waits for the verification code to become available online. It will also check your infrastructure setup; if the names of the deployed resources do not match the expected values, verification will fail.

## Prerequisites for Verification
Ensure you have the following information ready:

GitLab Project ID:

From Step 1.3
Example: 12345678
GitLab Personal Access Token:

From Step 12.4
Example: glpat-xxxxxxxxxxxxxxxxxxxx
What the Verification System Checks
The automated verification system will:

Add a verification file to your repository:

## Create a file with a unique verification code
Commit the file to trigger your pipeline
Wait for pipeline completion:

Monitor pipeline execution
Verify build and push stages succeed
Confirm image is pushed to ECR
Verify AWS resources:

ECR repository: Check that cmtr-msdta2zd-static exists
ECS cluster: Verify cmtr-msdta2zd-cluster is active
ECS service: Confirm cmtr-msdta2zd-service is running
Lambda function: Verify cmtr-msdta2zd-function exists
Verify application accessibility:

Access the deployed application via public IP
Check that verification code appears on the website
Verification Checklist
Before submitting, ensure all items are complete:

✅ GitLab repository forked successfully
✅ .gitlab-ci.yml file created and committed
✅ GitLab CI/CD variables configured (3 variables)
✅ Pipeline runs successfully (both stages pass)
✅ ECR repository cmtr-msdta2zd-static created
✅ Images pushed to ECR with correct tags
✅ ECS cluster cmtr-msdta2zd-cluster created
✅ ECS service cmtr-msdta2zd-service running
✅ ECS task definition cmtr-msdta2zd-task exists
✅ Lambda function cmtr-msdta2zd-function created
✅ Lambda environment variables configured (5 variables)
✅ EventBridge rule created and enabled
✅ Application accessible via public IP
✅ Personal Access Token generated with correct scopes
Submit for Verification
Start verification:

Click Verify.
The verification process will begin.
Wait for results:

Verification typically takes 5-10 minutes.
Do not close the browser window.
You'll see real-time progress updates.
Review results:

Success: All checks passed ✅
Failure: Review error messages and fix issues
If Verification Fails
If the automated verification fails, review the error messages and check:

Common issues:

ECR password expired (regenerate token)
Resource names don't match expected format
Pipeline not running on main branch
Security group blocking HTTP access
Lambda function timeout or permissions issues
Re-run manual tests:

Go through the manual testing section again
Fix any issues found
Ensure all resources are properly configured
Retry verification:

After fixing issues, submit again for verification
You can retry as many times as needed
Important Notes
When providing GitLab instance URL, use only the base URL format such as https://gitlab.com or https://gitbud.epam.com.
Do NOT include the full project path like https://gitlab.com/username/projectname.
## Deployment Time
It takes up to 5 minutes to deploy task resources and propagate updates after a commit.
