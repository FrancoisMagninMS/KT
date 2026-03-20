from flask import Flask
import os

app = Flask(__name__)


@app.route("/")
def hello():
    revision = os.getenv("CONTAINER_APP_REVISION", "unknown")
    return (
        f"<h1>Hello Korea! 🇰🇷</h1>"
        f"<p>Running on <b>Azure Container Apps</b></p>"
        f"<p>Revision: {revision}</p>"
    )


@app.route("/health")
def health():
    return "OK", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
