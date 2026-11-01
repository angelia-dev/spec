# Angelia spec

Angelia event schema (CloudEvents types, JSON Schema) and OpenAPI specification.

**Status:** pre-alpha / Phase 0. Nothing here is usable yet.

Part of [Angelia](https://github.com/angelia-dev), the self-hosted release event bus. See the [core repository](https://github.com/angelia-dev/angelia) for the design docs.

## Layout

- `schemas/<type>/v<major>.json`: JSON Schema (2020-12) for each event type and major version.
- `examples/valid/<type>/v<major>/`: examples that must validate against their schema.
- `examples/invalid/<type>/v<major>/`: examples that must fail validation against their schema.
- `openapi/`: OpenAPI specification (not yet populated).
- `scripts/validate-examples.sh`: validates every example and every schema. CI runs it on each pull request and push to `main`.

`schemas/placeholder/v0.json` is a PLACEHOLDER that only proves the pipeline. It is not an Angelia contract.

Validate locally:

```sh
python -m pip install "check-jsonschema==0.38.2"
scripts/validate-examples.sh
```

## Versioning

Each event type is named `dev.angelia.<type>.v<major>`, and its schema lives at `schemas/<type>/v<major>.json`. The versioning follows SemVer:

- **Additive change** (for example a new optional field): minor version bump. The existing `v<major>` schema is extended.
- **Breaking change** (removing or renaming a field, changing a type, making an optional field required, or changing an enum): major version bump. A new `dev.angelia.<type>.v<major+1>` schema is added, and the change needs an ADR in the core [angelia](https://github.com/angelia-dev/angelia) repository.

Published `v<major>` schemas are not edited in a breaking way.

## Licensing

This repository is dual-licensed:

- **Code** (scripts, CI configuration and tooling) is licensed under [Apache-2.0](LICENSE).
- **Schemas and examples** (`schemas/`, `examples/`, and the OpenAPI specification under `openapi/`) are also licensed under [CC-BY-4.0](LICENSE-SCHEMAS). You may use them under either license.

The full CC-BY-4.0 legal code is in [LICENSE-SCHEMAS](LICENSE-SCHEMAS). Official text: <https://creativecommons.org/licenses/by/4.0/legalcode>.
