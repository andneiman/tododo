#!/usr/bin/env python3
"""Revoke the throwaway Apple Development certificates that earlier CI runs created.

Every cloud runner starts with an empty keychain, so `xcodebuild -allowProvisioningUpdates`
mints a new development certificate each run; Apple allows only a few. Only certificates
created through the API ("Created via API") are revoked — never ones made in Xcode by hand.
Needs ASC_ISSUER_ID, ASC_KEY_ID, ASC_KEY_P8 in the environment.
"""
import json, os, time, urllib.request
import jwt  # PyJWT

key = os.environ["ASC_KEY_P8"]
token = jwt.encode(
    {"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
    key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
)

def call(method, path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req) as r:
        body = r.read()
        return json.loads(body) if body else None

kinds = "DEVELOPMENT,IOS_DEVELOPMENT,MAC_APP_DEVELOPMENT"
certs = call("GET", f"/v1/certificates?limit=200&filter[certificateType]={kinds}")["data"]
for c in certs:
    a = c["attributes"]
    name = a.get("name") or a.get("displayName") or ""
    print("found", a.get("certificateType"), repr(name))
    if "Created via API" in name:
        call("DELETE", f"/v1/certificates/{c['id']}")
        print(f"revoked {a.get('certificateType')} {c['id']} ({name})")
print(f"checked {len(certs)} development certificates")
