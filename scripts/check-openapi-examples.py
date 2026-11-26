#!/usr/bin/env python3
"""Check example bodies against the schemas of openapi/angelia.v1.yaml.

scripts/validate-examples.sh covers the event schemas and scripts/check-mcp-tools.py the MCP
tools; this covers the API schemas that carry a secret (API tokens, core ADR 0030), those of
browser sessions (core ADR 0033), those the admin UI added in spec 0.9.0 (the access list and
the template preview, core #274), the adoption of watch-file resources (spec 0.10.0), the
`gitlab-pipeline-trigger` sink configuration (spec 0.11.0), the `mqtt` sink configuration
(spec 0.13.0) and the exec sink's configuration (spec 0.14.0).

Layout: examples/openapi/v1/<valid|invalid>/<Schema>/<name>.json, where <Schema> is a key of
components.schemas.

Fails if:
  - a valid example does not validate against its schema, or an invalid one does;
  - a schema in SCHEMAS has no valid or no invalid example, or a directory names a schema that
    is not in SCHEMAS;
  - an example is not a .json file or is not parseable JSON;
  - a valid example's `token` member is not the token of its own `id` (`ang_<id>_...`), or its
    last 7 characters are not the check value (CRC-32 of the rest, big-endian, base32, lower case)
  - an inline example of the token schemas in the document (components.examples) does not
    validate against its schema, or the document's `TokenCreated` example uses a token that does
    not belong to its `id`.

The schemas are checked as JSON Schema 2020-12, the dialect of OpenAPI 3.1. `format` is not
asserted (the schemas carry a `pattern` where the format matters).

Needs the jsonschema and ruamel.yaml packages, which check-jsonschema (installed by CI for
scripts/validate-examples.sh) depends on.
"""

import base64
import json
import pathlib
import sys
import zlib

from jsonschema import Draft202012Validator
from ruamel.yaml import YAML

ROOT = pathlib.Path(__file__).resolve().parent.parent
OPENAPI = ROOT / "openapi" / "angelia.v1.yaml"
EXAMPLES = ROOT / "examples" / "openapi" / "v1"

# Schemas with example files, and the components.examples checked against each.
SCHEMAS = {
    "TokenCreate": ["TokenCreate", "TokenCreateExpiring"],
    "Token": ["Token"],
    "TokenCreated": ["TokenCreated"],
    "TokenPage": ["TokenPage"],
    "Me": ["MeToken", "MeSession"],
    "Session": [],
    "SessionPage": ["SessionPage"],
    "AccessEntry": [],
    "AccessList": ["AccessList"],
    "TemplatePreviewRequest": ["TemplatePreviewSample", "TemplatePreviewStoredEvent"],
    "TemplatePreview": ["TemplatePreviewRendered", "TemplatePreviewFailed"],
    "AdoptionRequest": ["AdoptionRequest"],
    "AdoptionResult": ["AdoptionResult"],
    "GitlabPipelineTriggerSinkConfig": [],
    "MqttSinkConfig": [],
    "ExecSinkConfig": [],
}

errors = []


def fail(msg):
    errors.append(msg)


def validator(doc, name):
    schema = {"$ref": f"#/components/schemas/{name}", "components": doc["components"]}
    return Draft202012Validator(schema)


def check_token_belongs_to_id(where, value):
    token = value.get("token") if isinstance(value, dict) else None
    if token is None:
        return
    if not token.startswith(f"ang_{value.get('id')}_"):
        fail(f"{where}: token does not carry the member id {value.get('id')!r}")
    # check = CRC-32 (IEEE) of everything before it, 4 big-endian bytes, lower-case base32, no padding.
    body, check = token[:-7], token[-7:]
    want = base64.b32encode(zlib.crc32(body.encode("ascii")).to_bytes(4, "big")).decode().rstrip("=").lower()
    if check != want:
        fail(f"{where}: token check is {check!r}, want {want!r}")


def main():
    with open(OPENAPI, encoding="utf-8") as f:
        doc = YAML(typ="safe").load(f)
    schemas = doc["components"]["schemas"]

    for name in SCHEMAS:
        if name not in schemas:
            fail(f"components.schemas.{name} is missing")
    if errors:
        return

    for group, expect_valid in (("valid", True), ("invalid", False)):
        root = EXAMPLES / group
        found = set()
        for path in sorted(root.rglob("*")):
            if path.is_dir():
                continue
            rel = path.relative_to(ROOT)
            if path.suffix != ".json" or path.parent.parent != root:
                fail(f"{rel}: must be {root.relative_to(ROOT)}/<Schema>/<name>.json")
                continue
            schema_name = path.parent.name
            if schema_name not in SCHEMAS:
                fail(f"{rel}: no schema {schema_name} in scripts/check-openapi-examples.py")
                continue
            found.add(schema_name)
            try:
                instance = json.loads(path.read_text(encoding="utf-8"))
            except ValueError as e:
                fail(f"{rel}: not valid JSON: {e}")
                continue
            problems = list(validator(doc, schema_name).iter_errors(instance))
            if expect_valid and problems:
                fail(f"{rel}: must validate against {schema_name}: {problems[0].message}")
            elif not expect_valid and not problems:
                fail(f"{rel}: must fail against {schema_name} but validates")
            if expect_valid and not problems:
                check_token_belongs_to_id(str(rel), instance)
        for name in SCHEMAS:
            if name not in found:
                fail(f"no {group} example for {name} under {root.relative_to(ROOT)}")

    for schema_name, example_names in SCHEMAS.items():
        for ex in example_names:
            entry = doc["components"]["examples"].get(ex)
            if entry is None:
                fail(f"components.examples.{ex} is missing")
                continue
            problems = list(validator(doc, schema_name).iter_errors(entry["value"]))
            if problems:
                fail(f"components.examples.{ex} must validate against {schema_name}: {problems[0].message}")
            check_token_belongs_to_id(f"components.examples.{ex}", entry["value"])


main()
if errors:
    for e in errors:
        print(f"FAIL {e}")
    print(f"check-openapi-examples: {len(errors)} failure(s)")
    sys.exit(1)
count = sum(1 for p in EXAMPLES.rglob("*.json"))
print(f"check-openapi-examples: {count} example file(s) and the inline examples behaved as expected")
