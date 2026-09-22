# Task 07: Private Route 53 DNS Failover

## Task description
## The Goal of the Task
To implement a CI/CD pipeline for multi-region DNS failover within a private network, using AWS CodeCommit as the source control system and AWS CodeBuild to automate the deployment process.

As part of the pipeline, AWS CodeBuild will execute the deployment of an AWS CloudFormation stack to provision an Amazon Route 53 private hosted zone associated with a VPC and configure primary and secondary DNS failover records.

This failover configuration routes traffic between resources deployed in multiple AWS regions based on health check evaluations, ensuring high availability and resilience for services operating within the private network.

You will learn:

DNS Failover Routing: Implement high availability using Amazon Route 53 failover routing policy
Infrastructure as Code (IaC): Deploy private hosted zones using AWS CloudFormation templates
Native AWS CI/CD: Orchestrate deployments with AWS CodeCommit, AWS CodeBuild, and AWS CodePipeline
Cross-Region Infrastructure: Manage and reference resources across multiple AWS regions
Parameter Management: Retrieve hosted zone names and record values from AWS Systems Manager Parameter Store
Focus Tool
Multi-region failover architecture ensures application continuity by dynamically routing traffic based on the health of endpoints:

### Primary Region: Active environment associated with the primary failover record

### Secondary Region: Standby environment associated with the secondary failover record, used when the primary endpoint is unhealthy
Private Hosted Zone: Limits DNS resolution to resources within the associated VPC
Health Checks: Evaluate endpoint availability and control DNS failover based on health check status
## Task Resources
Region-specific resources are distributed across your primary region eu-west-1 and secondary region ap-south-1.

## Pre-Created Infrastructure

The following resources are already provisioned in both regions:

Region	Resource	Name
Primary	VPC	cmtr-msdta2zd-vpc-primary (including public subnets and SGs)
Primary	EC2 Web Server	cmtr-msdta2zd-ec2-primary (with custom web-page)
Primary	EC2 Test Instance	cmtr-msdta2zd-ec2-test (for SSM verification)
Secondary	VPC	cmtr-msdta2zd-vpc-secondary (including public subnets and SGs)
Secondary	EC2 Web Server	cmtr-msdta2zd-ec2-secondary (with custom web-page)
SSM Parameter Store Values

/cmtr-msdta2zd/zone_name: Private hosted zone name (stored in primary region)
/cmtr-msdta2zd/app_name: Application DNS record name (stored in primary region)
/cmtr-msdta2zd/ec2_ip_primary: Public IP of the primary EC2 server (stored in primary region)
/cmtr-msdta2zd/ec2_ip_secondary: Public IP of the secondary EC2 server (stored in secondary region)
## Resources You Will Create

CodeCommit Repository: cmtr-msdta2zd-repo — stores template.yml and buildspec.yml
CloudFormation Template: template.yml — defines the Route 53 private hosted zone, HTTP health check, and failover A-records
CodeBuild Project: cmtr-msdta2zd-codebuild — reads SSM parameters and deploys the CloudFormation stack
IAM Service Role: cmtr-msdta2zd-codebuild-role — grants CodeBuild least-privilege permissions
CodePipeline Pipeline: cmtr-msdta2zd-pipeline — connects cmtr-msdta2zd-repo (Source) with cmtr-msdta2zd-codebuild (Build) to automate deployments on commit
## Objectives
Complete the following steps in order:

Initialize Source Control

## Create the CodeCommit repository cmtr-msdta2zd-repo

## Prepare and push template.yml and buildspec.yml to the main branch
Develop CloudFormation Template

Define a Private Hosted Zone associated with cmtr-msdta2zd-vpc-primary

## Configure an HTTP Health Check for the primary EC2 endpoint
Implement Failover A-records for Primary and Secondary servers

## Configure Build Orchestration

Write buildspec.yml to retrieve SSM parameters from both regions (zone name, record name, EC2 IPs, VPC ID)
Use aws cloudformation deploy to create or update the stack
Establish Security & Build

## Create an IAM role with least-privilege permissions (no AdministratorAccess)

## Configure and run the CodeBuild project cmtr-msdta2zd-codebuild

## Create a CI/CD Pipeline

## Create an AWS CodePipeline cmtr-msdta2zd-pipeline that:
Uses cmtr-msdta2zd-repo (branch main) as the Source stage
Uses cmtr-msdta2zd-codebuild as the Build stage
Verify that a new commit to main automatically triggers the pipeline
Verify Failover Readiness

Validate CloudFormation stack status
Confirm DNS resolution to the primary IP from the test instance
## Verification
Your task is complete when:

✅ CodeCommit repository cmtr-msdta2zd-repo contains all required deployment files
✅ CodeBuild project cmtr-msdta2zd-codebuild successfully deploys the infrastructure
✅ A CodePipeline pipeline cmtr-msdta2zd-pipeline is configured with Source (CodeCommit) and Build (CodeBuild) stages
✅ IAM role cmtr-msdta2zd-codebuild-role is configured without AdministratorAccess
✅ CloudFormation stack cmtr-msdta2zd-r53-stack is in CREATE_COMPLETE state
✅ Route 53 records are correctly resolving to the primary IP address
Verification Steps
To verify the configuration, connect to the EC2 Test Instance via SSM Session Manager and run:
# Verify DNS resolution
dig +short app.cmtr-msdta2zd.internal

# Expected output: ${ec2_ip_primary}
