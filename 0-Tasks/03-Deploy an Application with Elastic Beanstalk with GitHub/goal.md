# Task 03: Elastic Beanstalk Deployment with GitHub

## Task description
## The Goal of the Task
To configure a pipeline to automate the deployment of application updates to AWS Elastic Beanstalk when code changes are made in the GitHub or GitLab repository.

## Task Resources
Region-specific resources must be created in the ${aws_region} region. For more details about regional services, see AWS Services by Region.

In this task, you will work with the following resources:

VPC ${vpc} automatically created for AWS Elastic Beanstalk environment.
ElasticBeanstalkInstanceProfileRole an EC2 instance profile.
ElasticBeanstalkServiceRole a service role for Beanstalk with necessary permissions.
Beanstalk environment ${env} the environment for web application.
Beanstalk application ${app} a sample web application.
S3 Bucket ${s3_name} an automatically created bucket for Beanstalk environment.
Create a Flask Application for Your Repository
Simple Flask application to be deployed must follow the required directory structure.
Example: The following shows the recommended Git repository directory structure for the Flask application:
Repo_name/
├── application.py
├── requirements.txt
└── .gitlab-ci.yml

application.py
from flask import Flask

application = Flask(__name__)

@application.route("/")
def index():
    return "Hello from ${custom_identifier} Elastic Beanstalk CI-CD"

requirements.txt
Flask==3.1.2

Application Greetings Message

Flask application must provide the next greetings string:
Hello from ${custom_identifier} Elastic Beanstalk CI-CD

## Objectives
You must complete the following steps:

Create AWS Elastic Beanstalk environment for web application, named ${env}.
Create a sample web application, named ${app}.
Create a simple Flask application that runs on the Python platform.
Create a Github or Gitlab repository and push simple Flask repo to it.
Create a Github or Gitlab Access Token with read/write permissions to your repository.
Set up a Github or Gitlab pipeline that will deploy your website to AWS Elastic Beanstalk.
## Verification
To verify that you have successfully completed the task:

Ensure all resources are created with the correct configuration.
Open a web browser and navigate to the environment's entrypoint address to check if the website is accessible and displays correctly. You should see Flask hello page with preconfigured message.
Alternatively, use a command-line tool such as curl or wget to send an HTTP request to the environment's entrypoint address. Ensure the web server responds with a 200 OK status code, confirming the successful page load.

Example curl command:
curl http://<ENTRYPOINT>

The Flask hello message output should include verification greeting.

Task verification step will update your application hello message with the verification string. Ensure that the created access token has permission to commit to the main branch.
Attention! If you use GitHub to complete the task, don’t forget to delete the access_token that was created on GitHub for this task after you finish.

## Deployment Time
It takes up to 5 minutes to deploy task resources.,


VPC cmtr-msdta2zd-vpc automatically created for AWS Elastic Beanstalk environment.
ElasticBeanstalkInstanceProfileRole an EC2 instance profile.
ElasticBeanstalkServiceRole a service role for Beanstalk with necessary permissions.
Beanstalk environment cmtr-msdta2zd-env the environment for web application.
Beanstalk application cmtr-msdta2zd-app a sample web application.
S3 Bucket elasticbeanstalk- an automatically created bucket for Beanstalk environment.


## Objectives
You must complete the following steps:

1 Create AWS Elastic Beanstalk environment for web application, named cmtr-msdta2zd-env.
2 Create a sample web application, named cmtr-msdta2zd-app.
3 Create a simple Flask application that runs on the Python platform.
4 Create a Github or Gitlab repository and push simple Flask repo to it.
5 Create a Github or Gitlab Access Token with read/write permissions to your repository.
6 Set up a Github or Gitlab pipeline that will deploy your website to AWS Elastic Beanstalk.
