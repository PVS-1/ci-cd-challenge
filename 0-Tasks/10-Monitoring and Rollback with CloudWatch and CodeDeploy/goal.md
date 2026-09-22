# Task 10: Monitoring and Rollback with CloudWatch and CodeDeploy

## Task description
## Architecture
AWS Cloud (eu-west-1)
CI/CD Pipeline (cmtr-msdta2zd-codepipeline)
Source
Build
(cmtr-msdta2zd-codebuild-project)
Deploy
(cmtr-msdta2zd-codedeploy-application)
VPC (cmtr-msdta2zd-vpc)
ALB
cmtr-msdta2zd-alb
SG: cmtr-msdta2zd-alb-sg
Target Group
cmtr-msdta2zd-target-group
Auto Scaling Group (cmtr-msdta2zd-asg)
SG: cmtr-msdta2zd-sg
EC2 Instance
EC2 Instance
Monitoring & Rollback
CloudWatch Alarm
ALBUnhealthy
CloudWatch
Monitors
UnhealthyHostCount
Automatic
Rollback
triggers
alarm
state
Deployment Group
cmtr-msdta2zd-codedeploy-deployment-group
IAM Role
cmtr-msdta2zd-codedeploy-service-role
Developer
GitHub
Repository
webhook
deploys to
monitors
rollback
## The Goal of the Task
To implement a complete CI/CD pipeline with automatic monitoring and rollback capabilities by creating a CodePipeline that builds and deploys your application, configuring CloudWatch alarms to monitor application health, and enabling automatic rollback when deployments cause issues.

## Task Resources
Region-specific resources are created in the eu-west-1 region. For more details on regional services, see AWS Services by Region.

In this task, you will work with the following pre-created resources:

VPC cmtr-msdta2zd-vpc: Virtual Private Cloud with public and private subnets for network isolation
Security Group cmtr-msdta2zd-sg: Security group for EC2 instances
Security Group cmtr-msdta2zd-alb-sg: Security group for Application Load Balancer
Application Load Balancer cmtr-msdta2zd-alb: Load balancer for distributing traffic to application instances
Target Group cmtr-msdta2zd-target-group: Target group associated with the Application Load Balancer
Auto Scaling Group cmtr-msdta2zd-asg: Auto Scaling group managing EC2 instances
CodeDeploy Application cmtr-msdta2zd-codedeploy-application: Pre-configured CodeDeploy application
CodeDeploy Deployment Group cmtr-msdta2zd-codedeploy-deployment-group: Deployment group configured with the Auto Scaling group and Application Load Balancer
## Objectives
You must configure a complete CI/CD pipeline with monitoring and automatic rollback. The main steps include:

Create Flask Application and Configuration Files: Flask application with buildspec.yml for CodeBuild, appspec.yml for CodeDeploy, and lifecycle hooks scripts (start, stop, install dependencies)
Create GitHub Repository: that stores application code and deployment configuration
Create a CodePipeline that integrates GitHub as the source, CodeBuild for building, and CodeDeploy for deployment
Configure IAM permissions to allow pipeline components to communicate with each other
Trigger a new pipeline execution to verify the permissions are correctly configured
Create a CloudWatch alarm to monitor unhealthy hosts in the Application Load Balancer target group
Configure the CodeDeploy deployment group to retain old instances and enable automatic rollback based on the CloudWatch alarm
Deploy a new version of your application through the pipeline
Test automatic rollback by disrupting the application and observing the rollback process
Your application main page must contains the next string for verification:
Hello from the environment msdta2zd!

## Verification
To verify that the task is completed successfully:

Pipeline Execution: Confirm that the CodePipeline executes successfully through all stages (Source, Build, Deploy)
Application Accessibility: Verify that the application is accessible via the Application Load Balancer DNS name
CloudWatch Alarm: Confirm that the CloudWatch alarm named ALBUnhealthy is properly configured and monitoring the cmtr-msdta2zd-alb Application Load Balancer health
Rollback Configuration: Verify that the CodeDeploy deployment group has rollback enabled for alarm thresholds
Rollback Test: After disrupting the application, confirm that:
The CloudWatch alarm triggers when unhealthy hosts are detected
CodeDeploy automatically initiates a rollback deployment when alarm thresholds are met
The application returns to a healthy state with the last successfull deployment version
## Deployment Time
Deployment of task resources takes up to 5 minutes.
