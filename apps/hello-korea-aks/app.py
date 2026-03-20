from flask import Flask
import os

app = Flask(__name__)


@app.route("/")
def hello():
    hostname = os.getenv("HOSTNAME", "unknown")
    return (
        f"<h1>Hello Korea! 🇰🇷</h1>"
        f"<p>Running on <b>AKS</b></p>"
        f"<p>Pod: {hostname}</p>"
    )


@app.route("/health")
def health():
    return "OK", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
