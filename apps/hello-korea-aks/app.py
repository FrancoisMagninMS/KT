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


@app.route("/dbinfo")
def dbinfo():
    pg_host = "set" if os.getenv("PG_HOST") else "not-set"
    pg_user = "set" if os.getenv("PG_USERNAME") else "not-set"
    pg_pass = "set" if os.getenv("PG_PASSWORD") else "not-set"
    return (
        f"<h1>Database Configuration</h1>"
        f"<p>PG_HOST: {pg_host}</p>"
        f"<p>PG_USERNAME: {pg_user}</p>"
        f"<p>PG_PASSWORD: {pg_pass}</p>"
        f"<p><i>Sourced from Azure Key Vault via CSI driver</i></p>"
    )


@app.route("/health")
def health():
    return "OK", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
