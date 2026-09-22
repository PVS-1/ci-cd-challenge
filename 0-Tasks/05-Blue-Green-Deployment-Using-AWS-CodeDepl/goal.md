# Task 05: Blue/Green Deployment with AWS CodeDeploy

## The Goal of the Task
To implement a blue/green deployment pipeline using AWS CodeDeploy and deploy a Python Flask application to production EC2 instances using automated deployment with zero downtime.

You will learn:

Blue/Green Deployment Strategy: Deploy new application versions alongside the current version, then switch traffic with minimal downtime
AWS CodeDeploy: Automate application deployment lifecycle management
Infrastructure as Code: Work with pre-configured EC2 Auto Scaling Groups and Application Load Balancers
CI/CD Pipeline Integration: Connect GitHub repository to AWS for automated deployments
Deployment Validation: Implement health checks and service validation
Focus Tool
Blue/Green deployment is a release technique that reduces downtime and risk by running two identical production environments:

Blue Environment: Current production version (existing)
Green Environment: New version (created during deployment)
Traffic Shift: Once Green is validated, traffic switches from Blue to Green
Automatic Cleanup: Blue environment is terminated after successful validation
For more information, see AWS CodeDeploy Blue/Green Deployments.

## Task Resources
Region-specific resources must be created in the eu-west-1 region.

## Pre-Created Infrastructure

The following AWS resources are automatically provisioned for your task:

VPC cmtr-msdta2zd-vpc: Virtual network for deployment environment
EC2 Launch Template cmtr-msdta2zd-lt: Preconfigured with Python runtime and CodeDeploy agent
EC2 Auto Scaling Group cmtr-msdta2zd-asg: Manages instance scaling for deployment
Application Load Balancer cmtr-msdta2zd-alb: Routes traffic to EC2 instances
Target Group cmtr-msdta2zd-tg: Health check configuration on port 8000 /health endpoint
## Resources You Will Create

Flask Application: Simple Python web application returning custom greeting
GitHub Repository: Store application code and deployment configuration
IAM Service Role: cmtr-msdta2zd-codedeploy-role - grants CodeDeploy permissions to manage AWS resources
CodeDeploy Application: cmtr-msdta2zd-app - deployment orchestration service
Deployment Group: cmtr-msdta2zd-dg - blue/green deployment configuration
Deployment Configuration: appspec.yml + lifecycle scripts
## Objectives
Complete the following steps in order:

Create Flask Application

Implement Python web server on port 8000
Return greeting message containing msdta2zd on / endpoint
Expose /health endpoint for load balancer health checks
Create Deployment Configuration

Write appspec.yml - CodeDeploy configuration file
Create 3 lifecycle scripts: install dependencies, stop/start application
Push to GitHub

Create GitHub repository with application files and appspec.yml
Push code to main branch

## Configure AWS CodeDeploy

Create IAM service role with appropriate permissions
Create CodeDeploy application and deployment group

## Configure blue/green deployment settings

## Deploy Application

Create deployment in CodeDeploy
Monitor all 4 deployment stages
Validate application is accessible through ALB
## Verification
Your task is complete when:

✅ CodeDeploy application cmtr-msdta2zd-app exists
✅ Deployment group cmtr-msdta2zd-dg is configured for blue/green deployment in pre-created infrastructure
✅ Latest deployment status shows Succeeded
✅ Application is accessible via ALB DNS endpoint
✅ / endpoint returns message containing msdta2zd
Verification Steps
To verify everything has been configured correctly, open a new browser tab and navigate to the ALB DNS name from the AWS Console. The page should display Hello from msdta2zd!.

Alternatively, you can verify your deployment using the following commands:

# Replace with your ALB DNS name from AWS Console
ALB_DNS="${alb}-XXXXXXXXXX.${aws_region}.elb.amazonaws.com"

# Test the application endpoint
curl http://$ALB_DNS/

# Expected output: Hello from ${custom_identifier}!

Key Documentation References
AWS CodeDeploy User Guide
AppSpec File Reference
AppSpec Lifecycle Hooks Reference
CodeDeploy Blue/Green Deployments
AWS IAM Service Roles
Flask Documentation

## Deploy Time
Deployment of task resources takes approximately 5 minutes.

## Theory: components and purpose

### AWS components

| Component | What it does | Why it is needed |
|---|---|---|
| VPC | Isolated AWS network | Keeps EC2 instances and load balancer inside a controlled network |
| Launch Template | Defines how EC2 instances are created | Provides the AMI, instance type, security settings and CodeDeploy agent |
| Auto Scaling Group | Manages EC2 instances | Provides the blue fleet and allows CodeDeploy to create the green fleet |
| Application Load Balancer | Receives user traffic | Lets the deployment switch traffic between blue and green instances |
| Target Group | Contains healthy EC2 targets | Provides health checks through `/health` on port `8000` |
| Flask application | The application being deployed | Serves `/` and `/health` |
| AppSpec file | Describes CodeDeploy deployment files and hooks | Tells CodeDeploy where to copy files and which lifecycle scripts to run |
| Lifecycle scripts | Stop, install and start the application | Automates application replacement on each EC2 instance |
| IAM service role | Gives CodeDeploy AWS permissions | Allows CodeDeploy to manage Auto Scaling, EC2 and load balancer resources |
| CodeDeploy application | Logical deployment container | Groups deployments for this application |
| Deployment group | Defines where and how to deploy | Configures blue/green behavior, ASG and target group |
| GitHub repository | Stores source and deployment configuration | Provides the revision that CodeDeploy deploys |

### Why blue/green deployment is used

In a traditional deployment, the application on the current instances is replaced in place. Users may see downtime or errors while the new version starts.

With blue/green deployment:

1. Blue is the currently running fleet.
2. CodeDeploy creates a green fleet from the Auto Scaling Group configuration.
3. The application and lifecycle scripts are installed on green instances.
4. The target group checks `/health` and confirms that green instances are healthy.
5. The load balancer shifts traffic from blue to green.
6. After successful validation, CodeDeploy terminates the old blue instances.

The result is lower downtime and a safer rollback point during deployment.

### Azure equivalent

| AWS | Similar Azure concept |
|---|---|
| VPC | Azure VNet |
| EC2 | Azure Virtual Machine |
| Launch Template | VM image/configuration or VM Scale Set model |
| Auto Scaling Group | Azure Virtual Machine Scale Set |
| Application Load Balancer | Azure Application Gateway or Load Balancer |
| Target Group | Application Gateway backend pool or Load Balancer backend pool |
| IAM role | Managed Identity with Azure RBAC roles |
| CodeDeploy application/deployment group | Azure DevOps deployment target/stage or an Azure deployment workflow |
| AppSpec lifecycle hooks | Azure DevOps deployment scripts, cloud-init or VMSS extension scripts |
| GitHub Actions | Azure DevOps Pipelines or GitHub Actions using Azure login |
| Blue/green fleet | App Service deployment slots, VMSS replacement set, or two isolated environments behind a gateway |

Azure App Service deployment slots are the closest managed equivalent to blue/green: deploy to a staging slot, validate it, then swap staging and production traffic. For VM-based workloads, the closer equivalent is two VMSS or two backend pools behind Application Gateway, followed by a traffic switch.
