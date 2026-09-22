import os
import socket
import urllib.error
import urllib.request

from flask import Flask, jsonify


app = Flask(__name__)


def get_instance_id():
    token_request = urllib.request.Request(
        "http://169.254.169.254/latest/api/token",
        method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
    )
    try:
        with urllib.request.urlopen(token_request, timeout=1) as response:
            token = response.read().decode("utf-8")
        instance_request = urllib.request.Request(
            "http://169.254.169.254/latest/meta-data/instance-id",
            headers={"X-aws-ec2-metadata-token": token},
        )
        with urllib.request.urlopen(instance_request, timeout=1) as response:
            return response.read().decode("utf-8")
    except (TimeoutError, urllib.error.URLError, OSError):
        return socket.gethostname()


@app.get("/")
def index():
    return jsonify(
        {
            "application": "cmtr-msdta2zd-north-pole",
            "region": os.getenv("AWS_REGION", os.getenv("AWS_DEFAULT_REGION", "unknown")),
            "instance": get_instance_id(),
        }
    )


@app.get("/health")
def health():
    return jsonify({"status": "healthy"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
