# AGENTS.md — how to work in `spec`

This repository is part of [Angelia](https://github.com/angelia-dev/angelia), built mostly by **AI coding agents** working with a human maintainer. It holds the **public contract**: the CloudEvents types, their JSON Schemas and the OpenAPI specification.

The rules of the core repository apply here: read [angelia/AGENTS.md](https://github.com/angelia-dev/angelia/blob/main/AGENTS.md) (picking issues, when to stop and ask a human, Graft trailers, definition of done) and [docs/ESTIMATION.md](https://github.com/angelia-dev/angelia/blob/main/docs/ESTIMATION.md) (executor, complexity and model).

## Specific to this repository

- Everything here is a public contract. **Any** change to a field name, type, required-ness or enum is `Human-led`: open a draft PR and add `human-needed`.
- Schemas: JSON Schema 2020-12 under `schemas/<type>/v<major>.json`, with valid and invalid examples under `examples/`; CI validates every example.
- Versioning: SemVer. Additive changes are minor; removals and renames are major and need an ADR in the core repository.
- Licence: the schemas are also published under CC-BY-4.0 (see the PRD).
