# Angelia spec

Angelia event schema (CloudEvents types, JSON Schema) and OpenAPI specification.

**Status:** pre-alpha / Phase 0. Nothing here is usable yet.

Part of [Angelia](https://github.com/angelia-dev), the self-hosted release event bus. See the [core repository](https://github.com/angelia-dev/angelia) for the design docs.

## Layout

- `schemas/<type>/v<major>.json`: JSON Schema (2020-12) for each event type and major version.
- `examples/valid/<type>/v<major>/`: examples that must validate against their schema.
- `examples/invalid/<type>/v<major>/`: examples that must fail validation against their schema.
- `openapi/angelia.v1.yaml`: OpenAPI 3.1 specification of the REST API (`/v1`). Conventions: [docs/api.md](docs/api.md).
- `.spectral.yaml`: the Spectral ruleset the OpenAPI specification must pass; CI runs it on each pull request and push to `main`.
- `scripts/validate-examples.sh`: validates every example and every schema. CI runs it on each pull request and push to `main`.
- `webhooks/v1/vectors.json`: Standard Webhooks test vectors for Angelia's webhook sink, described by `schemas/webhooks/v1.json`. See [Webhook test vectors](#webhook-test-vectors).
- `scripts/check-webhook-vectors.py`: recomputes every signature and expected result in the vectors; `scripts/validate-examples.sh` runs it.
- `scripts/check-go-stubs.sh`: generates Go server stubs from the OpenAPI specification with oapi-codegen and compiles them in a throwaway module (nothing is written to the repository). CI runs it too.
- `docs/`: per-field documentation, API conventions and accepted proposals.

When several event types carry the same payload, they share one schema: the three release types `dev.angelia.release.published.v1`, `dev.angelia.release.yanked.v1` and `dev.angelia.release.prerelease.v1` all use `schemas/release/v1.json` for `data`, and `schemas/release/envelope/v1.json` profiles their CloudEvents envelope.

## Event types

| Type | `data` schema | Envelope schema | Docs |
| --- | --- | --- | --- |
| `dev.angelia.release.published.v1`, `dev.angelia.release.yanked.v1`, `dev.angelia.release.prerelease.v1` | [`schemas/release/v1.json`](schemas/release/v1.json) | [`schemas/release/envelope/v1.json`](schemas/release/envelope/v1.json) | [docs/release-event-v1.md](docs/release-event-v1.md) |

All three are **drafts** (see [Versioning](#versioning)).

## REST API

[`openapi/angelia.v1.yaml`](openapi/angelia.v1.yaml) specifies the REST API of an Angelia instance (draft): watches, their known versions, the event log (cursor pull and server-sent events), sinks, subscriptions, deliveries with the dead-letter view and replay, and plugins. Its event payload references the release event schemas above. Naming, pagination, errors, auth and versioning: [docs/api.md](docs/api.md).

Lint locally:

```sh
npx --yes @stoplight/spectral-cli@6.17.0 lint --fail-severity=hint openapi/angelia.v1.yaml
```

Validate locally:

```sh
python -m pip install "check-jsonschema==0.38.2"
scripts/validate-examples.sh
```

## Webhook test vectors

[`webhooks/v1/vectors.json`](webhooks/v1/vectors.json) holds [Standard Webhooks](https://www.standardwebhooks.com/) v1 test vectors shaped like the deliveries of Angelia's webhook sink, so a receiver in any language can check its verification against what Angelia sends. The file is described by [`schemas/webhooks/v1.json`](schemas/webhooks/v1.json) (draft, like the event schemas).

Each case gives the secrets that sign the message, the `webhook-id` (`<event ULID>:<subscription ULID>`), `webhook-timestamp` and `webhook-signature`, the exact body bytes, the receiver's secrets and clock (`now`), and the expected result. The cases cover one secret, three secrets during a rotation (a receiver holding any one of them accepts the message), a template body, a wrong secret, a tampered body, and timestamps exactly at the 5 minute tolerance (accepted, inclusive in both directions) and one second beyond it (rejected with `timestamp`). Bodies are the release events of [`examples/valid/`](examples/valid/release/envelope/v1) in CloudEvents structured mode. Secrets are synthetic: secret N is `whsec_` plus the base64 of the SHA-256 of `angelia-spec/webhooks/v1/secret/N`. Never use them for anything else.

The vectors file is licensed under [CC-BY-4.0](LICENSE-SCHEMAS), like the schemas.

## Versioning

**While the spec repository is at version 0.x, every schema here is a draft: it may still change, including in a breaking way, in any 0.x minor release before spec 1.0, without a new `.v<major>` type.** Breaking changes are listed in the release notes. The `v<major>` suffix names the major version that is frozen at spec 1.0.0; the rules below apply from then on.

Each event type is named `dev.angelia.<type>.v<major>`, and its schema lives at `schemas/<type>/v<major>.json`. The versioning follows SemVer:

- **Additive change** (for example a new optional field): minor version bump. The existing `v<major>` schema is extended.

Producers emit only the documented fields and, in v1, no CloudEvents extension attributes. Consumers **must ignore** unknown fields and extension attributes: the schemas accept them (in the envelope, any name matching the CloudEvents extension naming rule `^[a-z0-9]{1,20}$`), so that adding an optional field stays a minor change.
- **Breaking change** (removing or renaming a field, changing a type, making an optional field required, or changing an enum): major version bump. A new `dev.angelia.<type>.v<major+1>` schema is added, and the change needs an ADR in the core [angelia](https://github.com/angelia-dev/angelia) repository.

Published `v<major>` schemas are not edited in a breaking way.

## Open questions

[Proposal 0001](docs/proposals/0001-release-event-v1-fields.md) was accepted with its recommendation for every question. What is still open or provisional for the release events before spec 1.0:

- **`notes.body` size limit.** Set at 16,384 bytes of UTF-8. No source fills `notes` yet, so the notes enrichment story (PRD F12) may revise the limit; the fields `notes.body` and `notes.truncated` stay. JSON Schema can only check a character count, so the byte limit is enforced by producers.
- **`watch.labels` shape.** An object of string to string, as in the watch file and the subscription filter. To be revisited only if array-based consumers (SQL, BI tools) prove it necessary before 1.0.
- **`dataschema` and `$id` URLs.** Today `https://github.com/angelia-dev/spec/schemas/...`, an identifier that is not fetchable as JSON. Once the repository has release tags, `dataschema` names a tagged, versioned URL; whether to move to a domain the project owns is undecided.
- **Cooldown basis.** The rule for when a cooldown starts (`published_at` or `detected_at`, core ADR 0012 §6) is still pending in the core repository; it changes the value of `cooldown_satisfied_at`, not the schema. A field exposing the basis may be added later as an optional field.
- **OCI purl.** Until the `oci` source reports manifest digests, its `purl` is versionless with a `tag` qualifier.
- **GitLab purl.** A watch whose project is a numeric id has `purl: null` unless the source reports the project path.
- **Later additive changes.** The `partitionkey` extension attribute (with the NATS, MQTT and Kafka sinks), a `release.unyanked` type, and a `release.advisory` type (PRD F15) are not in v1.
- **Subscription filter on `bump: prerelease`.** The filter accepts only `major`, `minor`, `patch`; whether it should also accept `prerelease` is a watch-file question for the core repository.

### Follow-ups in the core repo

The accepted proposal changes things outside this repository. Each needs an issue in [angelia](https://github.com/angelia-dev/angelia):

- **`instance.name` config key** (proposal Q3): a new instance configuration key, default `angelia`, pattern `^[a-z0-9][a-z0-9.-]{0,62}$`, used as `<instance>` in the envelope `source`.
- **architecture.md §4 update**: rename `ecosystem` to `source`; the watch id is a bare ULID (not `w_123`) and the envelope `source` is `angelia://<instance>/watches/<watch_id>`; `time` is the emission time, not `detected_at`; add the new fields `normalized_version`, `backport` and `watch.name`.
- **Emission rules for angelia-dev/angelia#106**: when each type is emitted, every field always present (`null`, never omitted), no extension attributes, and the purl built per source kind as [docs/release-event-v1.md](docs/release-event-v1.md) describes (for `pypi`, from the project name as PyPI reports it, not the PEP 503 form).
- **Yank rules for angelia-dev/angelia#112**: `release.yanked` only for versions the watch has emitted, one event per watch per yank, repeating the stored classification with `cooldown_satisfied_at: null` and `detected_at` set to when the yank was seen; no un-yank event in v1.

## Licensing

This repository is dual-licensed:

- **Code** (scripts, CI configuration and tooling) is licensed under [Apache-2.0](LICENSE).
- **Schemas, examples and test vectors** (`schemas/`, `examples/`, `webhooks/`, and the OpenAPI specification under `openapi/`) are also licensed under [CC-BY-4.0](LICENSE-SCHEMAS). You may use them under either license.

The full CC-BY-4.0 legal code is in [LICENSE-SCHEMAS](LICENSE-SCHEMAS). Official text: <https://creativecommons.org/licenses/by/4.0/legalcode>.
