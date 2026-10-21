#!/usr/bin/env python3
"""Hash the single CA certificate's DER bytes; Terraform PEM/string hashes differ."""

import base64
import hashlib
import json
import re
import sys


query = json.load(sys.stdin)
pem = base64.b64decode(query["pem_base64"], validate=True).decode("ascii")
certificates = re.findall(
    r"-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----",
    pem,
)
if len(certificates) != 1:
    raise SystemExit("EKS certificate_authority.data must contain exactly one PEM certificate")
der = base64.b64decode("".join(certificates[0].split()), validate=True)
json.dump({"sha256": hashlib.sha256(der).hexdigest()}, sys.stdout)
