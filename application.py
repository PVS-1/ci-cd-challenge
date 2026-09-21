from flask import Flask

application = Flask(__name__)


@application.route("/")
def index():
    return "Hello from msdta2zd!"


@application.route("/health")
def health():
    return "OK", 200


if __name__ == "__main__":
    application.run(host="0.0.0.0", port=8000)
