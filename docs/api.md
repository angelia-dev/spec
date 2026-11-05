# REST API v1 (draft)

The REST API of an Angelia instance is specified in [`openapi/angelia.v1.yaml`](../openapi/angelia.v1.yaml) (OpenAPI 3.1). This page explains the conventions the specification follows; the specification wins if they differ.

**Draft.** While the spec repository is at version 0.x, the API may still change, including in a breaking way, in any 0.x minor release (see [Versioning](#versioning)).

## Decisions for the maintainer

Each item names the option this draft takes, then the alternatives. Items marked **core** need a change or a decision in the [core repository](https://github.com/angelia-dev/angelia) as well.

1. **Resource paths.** Taken: `/v1/watches`, `/v1/watches/{name}/versions`, `/v1/events`, `/v1/events/stream`, `/v1/events/{id}`, `/v1/sinks`, `/v1/subscriptions`, `/v1/deliveries`, `/v1/deliveries/{id}/replay`, `/v1/replays`, `/v1/plugins`, `/v1/plugins/{interface}/{kind}`. Alternatives: `/v1/plugins/{kind}` (a source and a sink could not share a kind name); a `/v1/deliveries/replay` action path instead of `/v1/replays`.
2. **Names are the key, unique per resource type across owners (core).** Taken: watches, sinks and subscriptions are addressed by `name`, and a name is unique per resource type whoever manages the row. The core's migration 00004 has `UNIQUE (managed_by, name)`, so today a file row and an API row can share a name; the core must make the name unique per resource type before the API ships. Alternatives: address rows by `id` with `name` as a filter; add the owner to the path.
3. **File-managed rows are read-only through the API.** Taken: rows loaded by `angelia serve --watches` have `managed_by: file`; the API reads them and refuses writes with `409 managed-by-file`. Alternative: let the API take rows over (the next file apply would then fight the API).
4. **No references across owners.** Taken: an API subscription cannot use a file sink, and the reverse is impossible by construction; refused with `409 cross-owner-reference`. Reason: the file's apply refuses to remove a sink that a kept subscription uses, so removing that sink from the file would make the startup apply fail and the process exit. Alternative: allow it and make file apply dead-letter or detach API subscriptions.
5. **Apply is ordered per-object `PUT`s.** Taken: `angelia apply` sends sinks, then watches, then subscriptions with `PUT`, and deletes in reverse order (subscriptions, watches, sinks). It is not atomic and the API has no prune. **Recommended follow-up, not specified here:** a bulk, atomic `POST /v1/apply` taking a whole file, with a dry-run plan and label-scoped prune (core #73).
6. **`PUT` semantics.** Taken: full replacement, defaults filled in responses, `201` created or `200` existed, an `Angelia-Change: created|updated|unchanged|deleted` header, and `?dry_run=true` on `PUT` and `DELETE`. Alternatives: no header (the client compares before and after); a `Prefer: return=minimal` option.
7. **`DELETE` of a missing resource.** Taken: `404`. Alternative: `204` every time (idempotent in its status too, which suits prune loops).
8. **No optimistic concurrency in v0.** Taken: last write wins. Alternative: `ETag` on reads and `If-Match` on `PUT`/`DELETE` (`412` on mismatch); additive later.
9. **Request and response schemas are split.** Taken: `WatchWrite`, `SinkWrite`, `SubscriptionWrite` are the `PUT` bodies (closed, no response-only fields); `Watch`, `Sink`, `Subscription` are responses with every field required. Alternative: one schema with `readOnly` fields.
10. **Requested vs effective interval (core).** Taken: `interval` is the value the client asked for; `status.effective_interval` is the smallest interval among the watches on the target. The core stores only `target.interval_ms`; to return the requested value faithfully it needs a per-watch interval column (additive migration).
11. **Event cursor.** Taken: `after` is the event's `seq`; `next_after` is the highest `seq` scanned, not the last item; the scan per request is bounded, so a page may be empty with `has_more: true`. Alternatives: `next_after` = last returned item (filtered consumers rescan); an opaque cursor.
12. **Expired cursor (core).** Taken: a non-zero `after` below the highest pruned `seq` gets `410 cursor-expired` with `oldest_seq`; `after=0` starts at the oldest event kept. The core must record the highest pruned `seq`. Alternative: silently resume at the oldest event kept.
13. **Event filters.** Taken: `watch` (name or id), `type` (short types), `source` (source kinds), the keys of the subscription filter. Alternative: architecture.md's `kind=`, which is ambiguous between the event type and the source kind.
14. **`EventRecord` wrapper.** Taken: `{seq, event, ref_event_id}`, with the CloudEvents envelope untouched in `event` and the yank reference of core ADR 0018 in `ref_event_id`. Alternatives: return bare envelopes with `seq` only in a header; drop `ref_event_id`.
15. **SSE format.** Taken: `retry: 5000` first; `id` is the `seq`; `data` is the same `EventRecord` as the pull API; no `event` field; a `: keep-alive` comment after 15 idle seconds; an expired cursor is a `410` before the stream starts; bearer token in the header only; the token is checked again at least every 60 seconds and a revoked token closes the stream. Alternatives: `event: <type>` per message; a token in a query parameter so the browser `EventSource` works (it leaks into logs).
16. **No consumer cursors or `ack` in v0.** Taken: clients keep their own `next_after`. Server-side durable cursors and the MCP `ack_event` are core #79 (Phase 2) and additive. Alternative: specify `/v1/consumers/{name}` now.
17. **Pagination of resource lists.** Taken: opaque `cursor` and `next_cursor` (`null` on the last page), `limit` default 100 and at most 500 (events: at most 1,000). Alternative: offset paging.
18. **Problem `type` URIs.** Taken: `https://github.com/angelia-dev/spec/blob/main/docs/api.md#problem-<slug>`, which resolves to the [list below](#problem-types). Alternatives: `urn:angelia:problem:<slug>`; a URL on a project domain once there is one; a tagged URL instead of `main`.
19. **Problem types and members.** Taken: the [list below](#problem-types), with the extension members `errors[{pointer, detail}]`, `required_scope` and `oldest_seq`. `about:blank` is never used.
20. **No `429` in v0.** Taken: the API has no rate limit yet, so `429` is not specified. Alternative: add `429 rate-limited` with `Retry-After` now so clients handle it from the start.
21. **Body size.** Taken: `413 payload-too-large` above 1 MiB. Alternative: another limit, or one per resource.
22. **Scopes.** Taken: one scope per operation, ordered `read` < `write` < `admin`; `read` for every `GET`, `write` for watches, subscriptions and replay, `admin` for sink writes (a sink names secrets and decides where requests go). Alternatives: `write` for sinks too; unordered scopes.
23. **Auth before existence.** Taken: `401` and `403` are decided before `404`, so a token without the scope cannot probe which names exist.
24. **No secret values in the v0 API.** Taken: the API accepts only references to environment variables (`*_env` keys), as the watch file does; it carries no secret value at all, so nothing is returned that could leak. Spectral rules forbid secret-named properties in responses and require `writeOnly` on any secret-named property. Write-only stored secrets came with core #75 as named secrets instead (items 33 to 37). Please confirm this meets the issue's criterion "secrets are write-only in the schema".
25. **Allowlist of environment variables (core, new instance config key).** Taken: a `*_env` name set through the API must be listed in a new instance configuration key, proposed as `api.allowed_env` (a list of exact variable names, default empty: the API cannot set any `*_env` key, and sinks that need a secret come from the watch file). Names starting with `ANGELIA_` are always refused. Refused names get `422 env-not-allowed`. The key name, and whether it accepts patterns such as `CI_*`, are a public contract of the instance configuration. Alternatives: no allowlist (any API writer with `admin` could make the instance send any of its environment variables to a sink URL); a prefix such as `ANGELIA_SINK_` reserved for sink secrets.
26. **Sink redaction.** Taken: below `admin`, every URL in a sink's `config` is cut to `scheme://host` and `url_redacted` is true (chat webhook URLs carry their secret in the path, core ADR 0017 §7). A key a kind's `config_schema` marks `x-angelia-secret: true` is replaced by `[REDACTED]` for every caller, listed in `masked_fields`, and cannot be set through the API. A Spectral rule for `x-angelia-secret` is not feasible: config schemas come from the kinds at run time, not from this document. Alternatives: hide sink `config` from `read` entirely; return `null` instead of `[REDACTED]`.
27. **Sink `config` is free-form.** Taken: `SinkConfig` is an open object validated against the kind's `config_schema`; the built-in kinds' configurations are documented as schemas (`WebhookSinkConfig`) listed in `x-angelia-kind-config`. Alternative: `oneOf` with a `kind` discriminator (closed to plugin kinds).
28. **Replay (core).** Taken: replay queues the existing delivery again (same id, same idempotency key); `attempts` keeps counting and the retry budget starts again from the replay; allowed from `dead` or `delivered`; bulk replay selects by event, or by subscription and an event-time range, and defaults to `dead`. Core #115 says replay "creates new deliveries with the same idempotency key", which the core's `UNIQUE (event_id, subscription_id)` forbids; the two must be reconciled. Alternatives: new delivery rows (needs the unique index changed); reset `attempts`.
29. **Plugins list includes built-ins.** Taken: `GET /v1/plugins` lists every usable kind (`runtime: builtin` or `wasm`), so clients can discover valid `source` and `kind` values. Alternative: third-party plugins only.
30. **Durations.** Taken: whole seconds are kept and fractions cut; a negative subscription `policy.cooldown` is clamped to `0` as in the watch file; a negative watch `policy.cooldown` is an error. Alternative: reject negative values everywhere.
31. **Code-generation hint.** Taken: `EventRecord.event` carries `x-go-type: json.RawMessage` because oapi-codegen cannot generate a type from the external envelope schema. Alternative: bundle the schema into the document before generation.
32. **Versioning and licence.** Taken: `/v1` in the path, `info.version` following spec releases (0.1.0); `info.license` is `Apache-2.0 OR CC-BY-4.0`, as the README says for `openapi/`.
33. **Stored secrets (core #75, ADR 0024).** Taken: `/v1/secrets/{name}` stores a value encrypted at rest under a name; `PUT` takes `value` (text) or `value_base64` (any bytes), at most 64 KiB, both `writeOnly`, and optional `hosts`; `GET` returns `name`, `hosts`, `key_id`, the times and `referenced_by`, never the value; `DELETE` is refused with `409 secret-in-use` while a reference exists. Every operation, reads included, needs `admin`: names, hosts and referrers map the instance's credentials. Alternatives: a per-sink `secrets` member (one value could not serve several sinks, and rotation would touch every sink); `read` for the metadata.
34. **References are `*_ref` keys.** Taken: a configuration key whose name ends in `_ref` holds the name of a stored secret, as a key ending in `_env` holds the name of an environment variable (`secret_ref` for the webhook signing secret, at most one of `secret_ref` and `secret_env`). It is a name, never a value, and is returned as written. A reference to a secret that does not exist is accepted (deliveries fail, retried, until it is stored). Alternatives: a structured `{"$secret": name}` value; interpolation in strings.
35. **Admin scope for references.** Taken: a write that adds, removes or changes a `*_ref` key needs `admin`, on any endpoint (watches and subscriptions too); a `write` token gets `403` with `required_scope: admin`. Writes that leave every `*_ref` unchanged keep the endpoint's scope. Alternative: an allowlist like `api.allowed_env` (it limits which secrets, not where they go).
36. **Host binding.** Taken: a secret's `hosts` (`host` or `host:port`, exact match, no wildcards) limits where it is sent; a source or registry credential may only reference a bound secret (`422 secret-host-binding-required`). A kind's `config_schema` marks the URL a sink sends to with `x-angelia-destination: true`. Alternative: wildcards such as `*.example.com` (later, additive).
37. **Explicit lint for secret values.** Taken: the secret-name rules do not match `value`, so Spectral rules name `SecretWrite.value` and `value_base64`: both must be `writeOnly`, and no 2xx response schema or example may have a member of either name.

Core follow-ups found while writing this specification (not decisions on the API):

- **`last_error` wording.** The watch file doc says deliveries of a removed subscription become dead with `subscription removed`; ADR 0017 says `subscription deleted`. One string should win; the examples here use `subscription removed`.
- **architecture.md §3.1** says `GET /v1/events?after=<cursor>&watch=…&kind=…`; it should say `source=` and `type=` (item 13).
- **Postgres ordering of `seq`.** Commit-ordered `seq` on Postgres is still an open question of core ADR 0008; the guarantee below holds on SQLite today.
- The core changes of items 2, 10, 12, 25 and 28.

## Resources

| Resource | Paths | Scope to read | Scope to write |
| --- | --- | --- | --- |
| Watches | `/v1/watches`, `/v1/watches/{name}` | `read` | `write` (`PUT`, `DELETE`) |
| Versions (per watch, read-only) | `/v1/watches/{name}/versions` | `read` | none |
| Events (read-only) | `/v1/events`, `/v1/events/stream`, `/v1/events/{id}` | `read` | none |
| Sinks | `/v1/sinks`, `/v1/sinks/{name}` | `read` (redacted) | `admin` (`PUT`, `DELETE`) |
| Secrets (values write-only) | `/v1/secrets`, `/v1/secrets/{name}` | `admin` (metadata only) | `admin` (`PUT`, `DELETE`) |
| Subscriptions | `/v1/subscriptions`, `/v1/subscriptions/{name}` | `read` | `write` (`PUT`, `DELETE`) |
| Deliveries | `/v1/deliveries`, `/v1/deliveries/{id}` | `read` | none |
| Replay | `/v1/deliveries/{id}/replay`, `/v1/replays` (`POST`) | none | `write` |
| Plugins (read-only) | `/v1/plugins`, `/v1/plugins/{interface}/{kind}` | `read` | none |

`/healthz`, `/readyz` and `/metrics` are served on the same address but are not part of this API (see the core repository's [configuration.md](https://github.com/angelia-dev/angelia/blob/main/docs/configuration.md)).

## Naming

- **Paths:** `/v1/` followed by plural resource nouns in lower case, with words joined by hyphens. Actions that are not a create, read, update or delete are a sub-resource with a verb (`/replay`) or a resource of their own (`/v1/replays`).
- **Fields and query parameters:** `snake_case`, like the release event schema and the watch file. A resource uses the same key as the watch file wherever the watch file has one (`source`, `coordinates`, `interval`, `scheme`, `labels`, `policy`, `kind`, `config`, `sink`, `filter`, `template`).
- **Keys:** watches, sinks and subscriptions are addressed by their `name` (pattern `^[a-z0-9][a-z0-9._-]{0,62}$`), unique per resource type whoever manages the resource. Each also has a response-only `id`, a ULID generated on creation and kept across updates. Events and deliveries are addressed by their ULID `id`. Where a parameter accepts either (`watch`, `subscription`), the two never overlap: names are lower case, ULIDs upper case.
- **Event types** in filters are the short types of subscription filters (`release.published`, `release.yanked`, `release.prerelease`).
- **Timestamps** are RFC 3339 in UTC with a `Z` suffix; the server always sends millisecond precision (`2026-10-30T17:00:02.512Z`) and accepts at most milliseconds.
- **Durations** use Go syntax (`30m`, `72h`). The server keeps whole seconds and cuts any fraction.
- **Null:** in a response, a documented field with no value is sent as `null`, never omitted. Request bodies may omit optional keys.

## Writing resources (apply)

Watches, sinks and subscriptions are written with `PUT /v1/<resource>/{name}`, an idempotent upsert keyed by name. The `PUT` body is the `*Write` schema (`WatchWrite`, `SinkWrite`, `SubscriptionWrite`): the keys of the object in the watch file. The response is the full resource.

- `name` may be omitted from the body; if present it must equal the name in the path.
- `PUT` replaces the whole resource: omitted optional keys take their defaults.
- Responses show the resource with **every default filled in**, the coordinates in the source's canonical form (`Requests` becomes `requests` on PyPI) and the effective `scheme`. Sending the write keys of a response back with `PUT` changes nothing.
- `201` means created, `200` means it existed. The `Angelia-Change` header says what happened: `created`, `updated`, `unchanged` or `deleted`. A second identical `PUT` returns `200` with `unchanged`.
- `?dry_run=true` on `PUT` and `DELETE` validates the request and returns the response it would get, without writing anything. `angelia apply --dry-run` uses it to show a plan.
- `DELETE` returns `204`, or `404` if the resource does not exist.
- The body is validated as a whole: a `422` lists every error found, each with a JSON Pointer to the offending member.
- **Owners.** Resources loaded from a watch file by `angelia serve --watches` have `managed_by: file`. The API reads them but refuses to change or delete them (`409 managed-by-file`), and an API resource cannot reference a file resource (`409 cross-owner-reference`): if it could, removing the file resource would make the next startup apply fail. Resources written through the API have `managed_by: api`.
- **`angelia apply`** sends one `PUT` per object, in dependency order: sinks, then watches, then subscriptions; deletions go in reverse order (subscriptions, watches, sinks). The sequence is **not atomic**: a failure leaves the objects before it applied. The API has no prune; a client that prunes lists and deletes.

## Pagination

**Lists of resources** (`watches`, `versions`, `sinks`, `subscriptions`, `deliveries`, `plugins`) use opaque cursors:

```http
GET /v1/watches?limit=100
GET /v1/watches?limit=100&cursor=eyJuIjoicmVxdWVzdHMifQ
```

The response is `{"items": [...], "next_cursor": "..."}`; `next_cursor` is `null` on the last page. Clients pass the cursor back unchanged and must not parse it. `limit` defaults to 100 (at most 500).

**Events** use the event's position in the log, `seq`, as an integer cursor ([core ADR 0008](https://github.com/angelia-dev/angelia/blob/main/docs/adr/0008-store-history-rows-and-event-cursor.md)):

```http
GET /v1/events?after=4180&type=release.published&watch=requests
```

The response is `{"items": [{"seq": 4182, "event": {...}, "ref_event_id": null}, ...], "next_after": 4190, "has_more": false}`.

- `seq` is assigned in commit order, so a consumer that stores `next_after` and resumes from it never skips a committed event. `seq` values increase strictly but may have gaps. On Postgres, commit-ordered `seq` is still an open question of core ADR 0008.
- `next_after` is the highest `seq` the server scanned, which can be beyond the last item when filters skipped events. The scan per request is bounded, so a page can be empty with `has_more: true`; ask again with `next_after`.
- `event` is the CloudEvents envelope exactly as it was delivered ([schemas/release/envelope/v1.json](../schemas/release/envelope/v1.json)); `ref_event_id` is the event a `release.yanked` refers to.
- `limit` defaults to 100 (at most 1,000).
- Events older than the retention period (90 days by default) are pruned. A non-zero `after` below the highest pruned `seq` gets `410 cursor-expired` with `oldest_seq`; `after=0` always starts at the oldest event kept.

**The event stream** `GET /v1/events/stream` takes the same filters and sends [server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html):

- The stream starts with `retry: 5000`. Each message has `id` (the `seq`) and `data` (the same `EventRecord` as the pull API, one line of JSON), and no `event` field.
- A reconnecting client sends `Last-Event-ID`, which takes precedence over `after`. An expired cursor gets a `410 cursor-expired` problem response before any stream starts.
- A `: keep-alive` comment is sent when the stream has been idle for 15 seconds.
- The token goes in the `Authorization` header. The browser `EventSource` API cannot set headers, so it cannot use this endpoint; use a fetch-based SSE client. The server checks the token again at least every 60 seconds and closes the stream once it is revoked.

## Errors

Errors are [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem details with the media type `application/problem+json`:

```json
{
  "type": "https://github.com/angelia-dev/spec/blob/main/docs/api.md#problem-validation-failed",
  "title": "Validation failed",
  "status": 422,
  "detail": "the watch has 2 errors",
  "instance": "/v1/watches/requests",
  "errors": [
    { "pointer": "/policy/prerelease", "detail": "must be one of none, only, include" },
    { "pointer": "/interval", "detail": "must be at least 5m" }
  ]
}
```

Clients switch on `type`, never on `title` or `detail`, and ignore members they do not know. `detail` never contains a secret or a full sink URL. Authentication and scope are checked before anything else, so a `401` or `403` never reveals whether a resource exists (`404`).

### Problem types

Each `type` is `https://github.com/angelia-dev/spec/blob/main/docs/api.md#problem-<slug>` and points at its entry here.

#### Problem: bad-request

`400`. Malformed JSON, an unknown or invalid query parameter, or a cursor the server did not issue.

#### Problem: unauthorized

`401`. No token, or an unknown, revoked or malformed one. The response carries `WWW-Authenticate: Bearer`.

#### Problem: forbidden

`403`. The token's scope is below the operation's; `required_scope` names it.

#### Problem: not-found

`404`. No resource with this name or id.

#### Problem: managed-by-file

`409`. A write to a resource loaded from the watch file. Change the file instead.

#### Problem: cross-owner-reference

`409`. An API resource that would reference a resource from the watch file (an API subscription on a file sink).

#### Problem: sink-in-use

`409`. Deleting a sink that a subscription uses.

#### Problem: secret-in-use

`409`. Deleting a stored secret that configuration still references with a `*_ref` key; `detail` names the referrers.

#### Problem: not-replayable

`409`. Replaying a `pending` or `in_flight` delivery, or one whose subscription or sink is gone.

#### Problem: cursor-expired

`410`. The event cursor points into pruned events; `oldest_seq` is the oldest event kept.

#### Problem: payload-too-large

`413`. The request body is over 1 MiB.

#### Problem: unsupported-media-type

`415`. A request body that is not `application/json`.

#### Problem: env-not-allowed

`422`. A `*_env` key names an environment variable the instance configuration does not allow, or one starting with `ANGELIA_`.

#### Problem: secrets-key-missing

`422`. Storing a secret on an instance that has no secrets key configured (`secrets.key_file`). Nothing is stored.

#### Problem: secret-host-binding-required

`422`. A source or registry credential references a stored secret that has no `hosts`: such a secret must be bound to the hosts it is sent to.

#### Problem: validation-failed

`422`. A well-formed body that breaks the resource's rules; `errors` lists each one.

#### Problem: internal-error

`500`. Anything unexpected.

#### Problem: unavailable

`503`. The instance is starting, shutting down or draining, or its database is unreachable. `Retry-After` says when to retry.

## Auth

Every request carries an API token: `Authorization: Bearer <token>`. A token has one scope, and the scopes are ordered: `read` < `write` < `admin`. A token can call every operation whose scope is at or below its own.

| Scope | Allows |
| --- | --- |
| `read` | every `GET`, including the event stream; sink URLs are cut to `scheme://host` |
| `write` | `PUT` and `DELETE` of watches and subscriptions, replay of deliveries |
| `admin` | `PUT` and `DELETE` of sinks, which name secrets and decide where the instance sends requests; full sink URLs; every operation on `/v1/secrets`; any write that adds, removes or changes a `*_ref` key |

Each operation in the specification declares the scope it needs in its `security` requirement (OpenAPI 3.1 allows role names for a non-OAuth scheme). How tokens are created, stored and revoked is the core repository's API tokens story; OIDC may come later.

## Secrets

Secret values are stored through the API, **write-only** and encrypted at rest by the instance ([core ADR 0024](https://github.com/angelia-dev/angelia/blob/main/docs/adr/0024-secrets-encrypted-at-rest.md)). No response carries a value.

- `PUT /v1/secrets/{name}` stores `value` (text, stored as its UTF-8 bytes exactly) or `value_base64` (any bytes), at most 64 KiB, with optional `hosts`. Both value members are `writeOnly`; they never appear in a response, a log, an audit record or a problem detail (a value that is too large reports its size only). The instance needs a key (`422 secrets-key-missing` otherwise).
- `GET /v1/secrets[/{name}]` returns the name, `hosts`, `key_id`, `created_at`, `updated_at` and `referenced_by`. Every operation on `/v1/secrets` needs `admin`.
- Configuration names a stored secret with a key ending in `_ref` (`secret_ref` for the webhook signing secret), or an environment variable of the instance with a key ending in `_env` (`secret_env`). Both are names, not secrets, and are returned as written. A write that adds, removes or changes a `*_ref` key needs `admin`, whatever the endpoint's scope.
- A `*_env` name set through the API must be allowed by the instance configuration (`api.allowed_env`, default empty); names starting with `ANGELIA_` are always refused (`422 env-not-allowed`).
- `hosts` binds a secret to the hosts it may be sent to (`host` or `host:port`, exact match). A bound secret is resolved only for such a destination, and every request carrying it is checked again, redirects included. A source or registry credential may only reference a bound secret (`422 secret-host-binding-required`).
- `DELETE /v1/secrets/{name}` is refused with `409 secret-in-use` while a reference exists.
- Below the `admin` scope, URLs in a sink's `config` are cut to `scheme://host` (`url_redacted: true`), because chat webhook URLs carry a secret in their path.
- A kind can mark a configuration key as a secret value with `x-angelia-secret: true` in its `config_schema`. The server masks such a key as `[REDACTED]` in every response (listed in `masked_fields`) and refuses it in API writes; kinds use `*_ref` keys instead. `x-angelia-destination: true` marks the URL a sink sends to, which a referenced secret's `hosts` must allow.

## Versioning

- The major version is in the path (`/v1`). Within a major version, changes are additive: new operations, new optional request fields, new response fields, new enum values in open sets, new problem types. Clients must ignore response fields they do not know.
- Removing or renaming a path, a field or a parameter, changing a type, or making an optional request field required is a breaking change: a new major version (`/v2`) served next to the old one for a deprecation period, and an ADR in the core repository.
- `info.version` follows the spec repository release. While it is 0.x, the rules above are a goal, not a promise: any 0.x minor release may still break `/v1` before spec 1.0.0 freezes it.

## Code generation

The server and the CLI use code generated by [oapi-codegen](https://github.com/oapi-codegen/oapi-codegen). The event envelope is referenced from [schemas/release/envelope/v1.json](../schemas/release/envelope/v1.json) rather than copied. oapi-codegen cannot generate a type from that external JSON Schema, and the server returns stored events byte for byte, so `EventRecord.event` carries `x-go-type: json.RawMessage`. Other generators ignore the extension.

CI checks that the stubs generate and compile: [`scripts/check-go-stubs.sh`](../scripts/check-go-stubs.sh) runs oapi-codegen v2.8.2 (models, chi server, strict server, embedded spec) in a throwaway module and runs `go build` and `go vet`. The stubs are not committed here.

## Lint

CI lints the specification with [Spectral](https://github.com/stoplightio/spectral) and the ruleset in [`.spectral.yaml`](../.spectral.yaml): `spectral:oas` plus rules for the conventions above (paths under `/v1`, `snake_case` properties, one scope per operation, problem details for errors, no secret-named property in a response schema or example and `writeOnly` on any secret-named property, `writeOnly` on the stored-secret members `value` and `value_base64` and neither of them in any response schema or example, an example for every request, response and parameter). Run it locally:

```sh
npx --yes @stoplight/spectral-cli@6.17.0 lint --fail-severity=hint openapi/angelia.v1.yaml
```
