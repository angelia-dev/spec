#!/usr/bin/env python3
"""Recomputes every signature and expected result in webhooks/v1/vectors.json.

Independent of the Go generator: HMAC-SHA256 over "<id>.<timestamp>.<body>",
base64, one "v1,<sig>" entry per signing secret. Also checks the Standard
Webhooks reference vector, so a bug in this checker cannot hide a bad file.
"""
import base64, hashlib, hmac, json, sys

path = sys.argv[1] if len(sys.argv) > 1 else "webhooks/v1/vectors.json"


def sign(secrets, msg_id, ts, body):
    out = []
    for s in secrets:
        key = base64.b64decode(s.removeprefix("whsec_"), validate=True)
        mac = hmac.new(key, f"{msg_id}.{ts}.{body}".encode(), hashlib.sha256).digest()
        out.append("v1," + base64.b64encode(mac).decode())
    return " ".join(out)


def verify(secrets, headers, body, now, tol):
    ts = headers["webhook-timestamp"]
    if abs(now - int(ts)) > tol:
        return "timestamp"
    want = sign(secrets, headers["webhook-id"], ts, body).split(" ")
    got = headers["webhook-signature"].split(" ")
    return None if any(hmac.compare_digest(g, w) for g in got for w in want) else "no_matching_signature"


errors = []
ref = sign(["whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"], "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", '{"test": 2432232314}')
if ref != "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=":
    errors.append("checker does not reproduce the Standard Webhooks reference vector")

doc = json.load(open(path, encoding="utf-8"))
for c in doc["cases"]:
    h = c["headers"]
    if c["name"] != "tampered-body":
        exp_sig = sign(c["sign_secrets"], h["webhook-id"], h["webhook-timestamp"], c["body"])
        if exp_sig != h["webhook-signature"]:
            errors.append(f"{c['name']}: signature does not match sign_secrets")
    err = verify(c["receiver_secrets"], h, c["body"], c["now"], doc["tolerance_seconds"])
    if (err is None) != c["expected"]["valid"] or err != c["expected"].get("error"):
        errors.append(f"{c['name']}: expected {c['expected']}, recomputed error={err}")

if errors:
    print("\n".join("FAIL " + e for e in errors))
    sys.exit(1)
print(f"check-webhook-vectors: {len(doc['cases'])} case(s) recomputed and match")
