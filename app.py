from flask import Flask


app = Flask(__name__)


@app.get("/")
def index():
    return "Hello from the environment msdta2zd!\n"


@app.get("/health")
def health():
    return {"status": "rollback-test"}, 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)