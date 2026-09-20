import json
import os

import boto3


codebuild = boto3.client("codebuild")


def lambda_handler(event, context):
    project_name = os.environ["CODEBUILD_PROJECT_NAME"]
    build = codebuild.start_build(projectName=project_name)

    return {
        "statusCode": 202,
        "body": json.dumps({"buildId": build["build"]["id"]}),
    }