#!/usr/bin/env python3
"""Set one password (no forced change) for all Terraform-managed ZITADEL users on platform.

Logs in as the machine user `terraform` (JWT profile key), then
POST /v2/users/{id}/password with changeRequired=false.
User IDs come from `terraform show -json` (clusters/platform/zitadel-config).
"""
import getpass, json, os, ssl, subprocess, sys, time, urllib.parse, urllib.request

import jwt

ISSUER = "https://zitadel.platform.sthings.lab"
KEY = os.path.expanduser("~/.config/zitadel/terraform-key-harvester.json")
CA = os.path.expanduser("~/.config/zitadel/ca-harvester.pem")
TF_DIR = os.path.dirname(os.path.abspath(__file__))
CTX = ssl.create_default_context(cafile=CA)


def call(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, context=CTX) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"{url}: {e.code} {e.read().decode()}")


def token():
    k = json.load(open(KEY))
    now = int(time.time())
    assertion = jwt.encode(
        {"iss": k["userId"], "sub": k["userId"], "aud": ISSUER, "iat": now, "exp": now + 300},
        k["key"], algorithm="RS256", headers={"kid": k["keyId"]})
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "scope": "openid urn:zitadel:iam:org:project:id:zitadel:aud",
        "assertion": assertion,
    }).encode()
    return call(f"{ISSUER}/oauth/v2/token", body,
                {"Content-Type": "application/x-www-form-urlencoded"})["access_token"]


def users():
    env = dict(os.environ, KUBECONFIG=os.path.expanduser("~/.kube/platform.sthings.lab"))
    state = json.loads(subprocess.run(["terraform", "show", "-json"], cwd=TF_DIR, env=env,
                                      check=True, capture_output=True).stdout)
    out = {}
    def walk(m):
        for r in m.get("resources", []):
            if r["type"] == "zitadel_human_user":
                out[r["index"]] = r["values"]["id"]
        for c in m.get("child_modules", []):
            walk(c)
    walk(state["values"]["root_module"])
    return out


def main():
    ids = users()
    print("users:", ", ".join(sorted(ids)))
    pw = getpass.getpass("New password for all users: ")
    if not pw or pw != getpass.getpass("Again: "):
        sys.exit("passwords differ or empty")
    tok = token()
    for name, uid in sorted(ids.items()):
        call(f"{ISSUER}/v2/users/{uid}/password",
             json.dumps({"newPassword": {"password": pw, "changeRequired": False}}).encode(),
             {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
        print(f"{name}: ok")


if __name__ == "__main__":
    main()
