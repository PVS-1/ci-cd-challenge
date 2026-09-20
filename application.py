from flask import Flask

application = Flask(__name__)


@application.route("/")
def index():
    return "Hello from msdta2zd Elastic Beanstalk CI-CD"
