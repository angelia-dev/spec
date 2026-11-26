# REST API v1 (draft)

The REST API of an Angelia instance is specified in [`openapi/angelia.v1.yaml`](../openapi/angelia.v1.yaml) (OpenAPI 3.1). This page explains the conventions the specification follows; the specification wins if they differ.

**Draft.** While the spec repository is at version 0.x, the API may still change, including in a breaking way, in any 0.x minor release (see [Versioning](#versioning)).

## Decisions for the maintainer

Each item names the option this draft takes, then the alternatives. Items marked **core** need a change or a decision in the [core repository](https://github.com/angelia-dev/angelia) as well.

1. **Resource paths.** Taken: `/v1/watches`, `/v1/watches/{name}/versions`, `/v1/events`, `/v1/events/stream`, `/v1/events/{id}`, `/v1/sinks`, `/v1/subscriptions`, `/v1/deliveries`, `/v1/deliveries/{id}/replay`, `/v1/replays`, `/v1/plugins`, `/v1/plugins/{interface}/{kind}`, `/v1/consumers`, `/v1/consumers/{name}/ack` (item 16), `/v1/tokens`, `/v1/tokens/{id}` (items 41 to 43), `/v1/me`, `/v1/sessions`, `/v1/sessions/{id}` (items 44 to 46), `/v1/access` (item 50), `/v1/template-previews` (item 53), `/v1/adoptions` (item 55). Alternatives: `/v1/plugins/{kind}` (a source and a sink could not share a kind name); a `/v1/deliveries/replay` action path instead of `/v1/replays`.
2. **Names are the key, unique per resource type across owners (core).** Taken: watches, sinks and subscriptions are addressed by `name`, and a name is unique per resource type whoever manages the row. The core's migration 00004 has `UNIQUE (managed_by, name)`, so today a file row and an API row can share a name; the core must make the name unique per resource type before the API ships. Alternatives: address rows by `id` with `name` as a filter; add the owner to the path.
3. **File-managed rows are read-only through the API.** Taken: rows loaded by `angelia serve --watches` have `managed_by: file`; the API reads them and refuses writes with `409 managed-by-file`. Since spec 0.10.0 an admin can hand them over explicitly with `POST /v1/adoptions` (item 55); the file apply then skips the adopted names instead of fighting the API. Alternative: let any API write take rows over silently (the next file apply would then fight the API).
4. **No references across owners.** Taken: an API subscription cannot use a file sink, and the reverse is impossible by construction; refused with `409 cross-owner-reference`. Reason: the file's apply refuses to remove a sink that a kept subscription uses, so removing that sink from the file would make the startup apply fail and the process exit. Alternative: allow it and make file apply dead-letter or detach API subscriptions.
5. **Apply is ordered per-object `PUT`s.** Taken: `angelia apply` sends sinks, then watches, then subscriptions with `PUT`, and deletes in reverse order (subscriptions, watches, sinks). It is not atomic and the API has no prune. **Recommended follow-up, not specified here:** a bulk, atomic `POST /v1/apply` taking a whole file, with a dry-run plan and label-scoped prune (core #73).
6. **`PUT` semantics.** Taken: full replacement, defaults filled in responses, `201` created or `200` existed, an `Angelia-Change: created|updated|unchanged|deleted` header, and `?dry_run=true` on `PUT` and `DELETE`. Alternatives: no header (the client compares before and after); a `Prefer: return=minimal` option.
7. **`DELETE` of a missing resource.** Taken: `404`. Alternative: `204` every time (idempotent in its status too, which suits prune loops).
8. **No optimistic concurrency in v0.** Taken until spec 0.9.0: last write wins. Superseded by item 52: `ETag` on reads and writes, optional `If-Match` and `If-None-Match: *` (`412` on mismatch); without them the last write still wins.
9. **Request and response schemas are split.** Taken: `WatchWrite`, `SinkWrite`, `SubscriptionWrite` are the `PUT` bodies (closed, no response-only fields); `Watch`, `Sink`, `Subscription` are responses with every field required. Alternative: one schema with `readOnly` fields.
10. **Requested vs effective interval (core).** Taken: `interval` is the value the client asked for; `status.effective_interval` is the smallest interval among the watches on the target. The core stores only `target.interval_ms`; to return the requested value faithfully it needs a per-watch interval column (additive migration).
11. **Event cursor.** Taken: `after` is the event's `seq` (and, reading newest first, `before`, item 47); `next_after` is the highest `seq` scanned, not the last item; the scan per request is bounded, so a page may be empty with `has_more: true`. Alternatives: `next_after` = last returned item (filtered consumers rescan); an opaque cursor.
12. **Expired cursor (core).** Taken: a non-zero `after` below the highest pruned `seq` gets `410 cursor-expired` with `oldest_seq`; `after=0` starts at the oldest event kept. The core must record the highest pruned `seq`. Alternative: silently resume at the oldest event kept.
13. **Event filters.** Taken: `watch` (name or id), `type` (short types), `source` (source kinds), the keys of the subscription filter. Alternative: architecture.md's `kind=`, which is ambiguous between the event type and the source kind.
14. **`EventRecord` wrapper.** Taken: `{seq, event, ref_event_id}`, with the CloudEvents envelope untouched in `event` and the yank reference of core ADR 0018 in `ref_event_id`. Alternatives: return bare envelopes with `seq` only in a header; drop `ref_event_id`.
15. **SSE format.** Taken: `retry: 5000` first; `id` is the `seq`; `data` is the same `EventRecord` as the pull API; no `event` field; a `: keep-alive` comment after 15 idle seconds; an expired cursor is a `410` before the stream starts; bearer token in the header only; the token is checked again at least every 60 seconds and a revoked token closes the stream. Since spec 0.9.0 the admin UI's session cookie also authenticates the stream (item 54), so a browser `EventSource` on the instance's own origin works. Alternatives: `event: <type>` per message; a token in a query parameter so the browser `EventSource` works (it leaks into logs).
16. **Consumer cursors and `ack` (core #79; maintainer decisions D1 to D5 of 2026-11-10, spec 0.5.0).** Until 0.5.0 clients kept their own `next_after`; a named consumer now keeps a durable cursor on the server for clients that cannot (agents without storage, the MCP tools `events_since` and `ack_event` of core #81). Clients may still keep their own `next_after`; `after` is unchanged.
    1. *D1, shape.* Taken: a `/v1/consumers/{name}` resource (`PUT`, `GET`, `DELETE`, and `GET /v1/consumers`), `POST /v1/consumers/{name}/ack`, and a `consumer` query parameter on `GET /v1/events` and `GET /v1/events/stream`. `consumer` reads after the consumer's `acked_seq` with its stored `filter` (`ConsumerFilter`: the keys and values of the event filters `watch`, `type`, `source`), and is exclusive with `after`, `watch`, `type` and `source` by presence (`400`, even for `after=0` or an empty `watch=`); an unknown consumer gets `404`. Reading never acknowledges; on the stream, `Last-Event-ID` still takes precedence (item 15), and an open stream keeps the consumer's filter as it was when the stream started. Each `ConsumerFilter` key holds at most 100 values (draft choice, for review). Alternatives: only a `consumer` parameter that creates the consumer on first use (a typo creates a new consumer that starts from 0); a separate `GET /v1/consumers/{name}/events` (duplicates `EventPage` and the stream).
    2. *D2, ack semantics.* Taken: a cursor commit, as a Kafka offset: the body is exactly one of `seq` and `event_id` (resolved to its `seq`), and `acked_seq` becomes `max(acked_seq, seq)`, so an ack is monotonic and idempotent and an older or repeated ack returns `200` with the consumer unchanged. A `seq` above the highest `seq` ever committed, pruned events included (the larger of the highest `seq` in the log and the highest pruned `seq`), or an `event_id` the log does not hold, gets `422 validation-failed`. Alternative: per-event acks with visibility timeouts, SQS-style (a row per consumer and event, redelivery timers).
    3. *D3, scope.* Taken: `write` for `PUT`, `DELETE` and `ack`, `read` for the `GET`s and for reading events through a consumer. Alternatives: `read` for `ack` (any read token could move any consumer's cursor and make another agent skip events); a consumer owned by the token that created it (needs token identities, core #72; can be added later as an optional owner check).
    4. *D4, retention.* Taken: retention ignores consumers. A consumer whose `acked_seq` is below the highest pruned `seq` gets `410 cursor-expired` with `oldest_seq`, as `after` does (item 12), and recovers by acknowledging `oldest_seq − 1`, accepting the gap. Unlike `after=0`, a consumer's `acked_seq` of `0` is checked like any other position, so a consumer that falls behind always gets `410`. Alternative: keep the events above the lowest `acked_seq` (an abandoned consumer would stop pruning for good).
    5. *D5, start position.* Taken: an optional `start` on create, `latest` (default: `acked_seq` is the highest `seq` ever committed, pruned events included (the larger of the highest `seq` in the log and the highest pruned `seq`), read in the create transaction, so an event committed concurrently may or may not be included) or `earliest` (`acked_seq` is the highest pruned `seq`, that is `oldest_seq − 1`, so the consumer reads from the oldest event kept; draft amendment of D5, for review: the issue said `0`, which would let a consumer created on a pruned log, or left at `0`, skip the `410` check). `acked_seq` is `0` only for a consumer created on a log that was never pruned. `start` is ignored on an existing consumer, and no `PUT` moves `acked_seq`. Alternative: `earliest` by default (a new agent would receive 90 days of history by accident), or a required `start`.
17. **Pagination of resource lists.** Taken: opaque `cursor` and `next_cursor` (`null` on the last page), `limit` default 100 and at most 500 (events: at most 1,000). Alternative: offset paging.
18. **Problem `type` URIs.** Taken: `https://github.com/angelia-dev/spec/blob/main/docs/api.md#problem-<slug>`, which resolves to the [list below](#problem-types). Alternatives: `urn:angelia:problem:<slug>`; a URL on a project domain once there is one; a tagged URL instead of `main`.
19. **Problem types and members.** Taken: the [list below](#problem-types), with the extension members `errors[{pointer, detail}]`, `required_scope` and `oldest_seq`. `about:blank` is never used.
20. **No `429` in v0.** Taken: the API has no rate limit yet, so `429` is not specified. Alternative: add `429 rate-limited` with `Retry-After` now so clients handle it from the start.
21. **Body size.** Taken: `413 payload-too-large` above 1 MiB. Alternative: another limit, or one per resource.
22. **Scopes.** Taken: one scope per operation, ordered `read` < `write` < `admin`; `read` for every `GET`, `write` for watches, subscriptions, replay, consumers and their acks, `admin` for sink writes (a sink names secrets and decides where requests go). Alternatives: `write` for sinks too; unordered scopes.
23. **Auth before existence.** Taken: `401` and `403` are decided before `404`, so a token without the scope cannot probe which names exist.
24. **No secret values in the v0 API.** Taken: the API accepts only references to environment variables (`*_env` keys), as the watch file does; it carries no secret value at all, so nothing is returned that could leak. Spectral rules forbid secret-named properties in responses and require `writeOnly` on any secret-named property. Write-only stored secrets came with core #75 as named secrets instead (items 33 to 37). Please confirm this meets the issue's criterion "secrets are write-only in the schema".
25. **Allowlist of environment variables (core, new instance config key).** Taken: a `*_env` name set through the API must be listed in a new instance configuration key, proposed as `api.allowed_env` (a list of exact variable names, default empty: the API cannot set any `*_env` key, and sinks that need a secret come from the watch file). Names starting with `ANGELIA_` are always refused. Refused names get `422 env-not-allowed`. The key name, and whether it accepts patterns such as `CI_*`, are a public contract of the instance configuration. Alternatives: no allowlist (any API writer with `admin` could make the instance send any of its environment variables to a sink URL); a prefix such as `ANGELIA_SINK_` reserved for sink secrets.
26. **Sink redaction.** Taken: below `admin`, every URL in a sink's `config` is cut to `scheme://host` and `url_redacted` is true (chat webhook URLs carry their secret in the path, core ADR 0017 §7). A key a kind's `config_schema` marks `x-angelia-secret: true` is replaced by `[REDACTED]` for every caller, listed in `masked_fields`, and cannot be set through the API. A Spectral rule for `x-angelia-secret` is not feasible: config schemas come from the kinds at run time, not from this document. Alternatives: hide sink `config` from `read` entirely; return `null` instead of `[REDACTED]`.
27. **Sink `config` is free-form.** Taken: `SinkConfig` is an open object validated against the kind's `config_schema`; the built-in kinds' configurations are documented as schemas (`WebhookSinkConfig`) listed in `x-angelia-kind-config`. Alternative: `oneOf` with a `kind` discriminator (closed to plugin kinds).
28. **Replay (core).** Taken: replay queues the existing delivery again (same id, same idempotency key); `attempts` keeps counting and the retry budget starts again from the replay; allowed from `dead` or `delivered`; bulk replay selects by event, or by subscription and an event-time range, and defaults to `dead`. Core #115 says replay "creates new deliveries with the same idempotency key", which the core's `UNIQUE (event_id, subscription_id)` forbids; the two must be reconciled. Alternatives: new delivery rows (needs the unique index changed); reset `attempts`.
29. **Plugins list includes built-ins.** Taken: `GET /v1/plugins` lists every usable kind (`runtime: builtin` or `wasm`), so clients can discover valid `source` and `kind` values. Alternative: third-party plugins only.
30. **Durations.** Taken: whole seconds are kept and fractions cut; a negative subscription `policy.cooldown` is clamped to `0` as in the watch file; a negative watch `policy.cooldown` is an error. Alternative: reject negative values everywhere.
31. **Code-generation hint.** Taken: `EventRecord.event` carries `x-go-type: json.RawMessage` because oapi-codegen cannot generate a type from the external envelope schema. Alternative: bundle the schema into the document before generation.
32. **Versioning and licence.** Taken: `/v1` in the path, `info.version` following spec releases (from 0.1.0; 0.2.0 adds stored secrets; 0.5.0 adds consumers; 0.6.0 adds no change to this document, only the MCP tool contract of [docs/mcp.md](mcp.md); 0.7.0 adds API tokens; 0.8.0 adds `/v1/me`, browser sessions under `/v1/sessions`, the `sessionCookie` scheme and the `csrf` problem type; 0.9.0 adds newest-first events, delivery filters and `Delivery.sink`, `/v1/access`, `Me.session_id`, `ETag` and conditional writes with the `precondition-failed` problem type, the `JsonSchema` type of `config_schema` and `/v1/template-previews`); `info.license` is `Apache-2.0 OR CC-BY-4.0`, as the README says for `openapi/`.
33. **Stored secrets (core #75, ADR 0024).** Taken: `/v1/secrets/{name}` stores a value encrypted at rest under a name; `PUT` takes `value` (text) or `value_base64` (any bytes), at most 64 KiB, both `writeOnly`, and optional `hosts`; `GET` returns `name`, `hosts`, `key_id`, the times and `referenced_by`, never the value; `DELETE` is refused with `409 secret-in-use` while a reference exists. Every operation, reads included, needs `admin`: names, hosts and referrers map the instance's credentials. Alternatives: a per-sink `secrets` member (one value could not serve several sinks, and rotation would touch every sink); `read` for the metadata.
34. **References are `*_ref` keys.** Taken: a configuration key whose name ends in `_ref` holds the name of a stored secret, as a key ending in `_env` holds the name of an environment variable (`secret_ref` for the webhook signing secret, at most one of `secret_ref` and `secret_env`). It is a name, never a value, and is returned as written. A reference to a secret that does not exist is accepted (deliveries fail before sending, retried, until it is stored). Every delivery attempt resolves references; values are not cached. Alternatives: a structured `{"$secret": name}` value; interpolation in strings.
35. **Admin scope for references.** Taken: a write that adds, removes or changes a `*_ref` key needs `admin`, on any endpoint (watches and subscriptions too); a `write` token gets `403` with `required_scope: admin`. Writes that leave every `*_ref` unchanged keep the endpoint's scope. Alternative: an allowlist like `api.allowed_env` (it limits which secrets, not where they go).
36. **Host binding.** Taken: a secret's `hosts` (`host` or `host:port`, exact match, no wildcards) limits where it is sent; a source or registry credential may only reference a bound secret (`422 secret-host-binding-required`). A kind's `config_schema` marks the URL a sink sends to with `x-angelia-destination: true`. For a sink the binding is checked against that URL at every delivery; sinks follow no redirect. For source and registry credentials, the binding, its redirect re-check and `secret-host-binding-required` apply once they can reference stored secrets (core #111). Alternative: wildcards such as `*.example.com` (later, additive).
37. **Explicit lint for secret values.** Taken: the secret-name rules do not match `value`, so Spectral rules name `SecretWrite.value` and `value_base64`: both must be `writeOnly`, and no 2xx response schema or example may have a member of either name.

38. **`github-dispatch` sink configuration (core #113, proposal).** Taken: `GithubDispatchSinkConfig` in `x-angelia-kind-config`: `mode` (`repository_dispatch` default, or `workflow_dispatch`), `repo` (`owner/name`), `api_base_url` (default `https://api.github.com`, GitHub Enterprise Server `https://host/api/v3`, marked `x-angelia-destination`), exactly one of `token_env` and `token_ref`, `event_type` (template, default `angelia.release.published`), `workflow` and `ref` (required for `workflow_dispatch`), `inputs` (template per input, at most 25) and `timeout`. The token key names are references, not values, so they are not `x-angelia-secret` (that would mask them and refuse them in API writes). Open questions, each with the option taken:
    1. *Templates.* `event_type` and `inputs` values are ADR 0016 templates with the subscription template context. Alternative: literals only (no per-event inputs).
    2. *Payload shape.* `client_payload` is a fixed flat subset, never the whole event: `event_id`, `source`, `package`, `version`, `previous_version`, `bump`, `purl`, `release_url`, `watch`, plus `truncated` (10 keys, GitHub's top-level limit). Alternatives: nested `data` (a nested object counts as one key, but workflows then address `client_payload.data.version`); a user-defined `client_payload` mapping (more contract surface; later, additive). The key names need the maintainer's confirmation.
    3. *Truncation.* Deterministic: every string value is cut to 2048 bytes at a UTF-8 boundary and `truncated: true` is set if any was cut; `inputs` values are cut to 1024 bytes with no marker. Alternative: a permanent error when a value is too long (nothing is delivered, but nothing is silently shortened).
    4. *Rate limits.* A `403` or `429` caused by a rate limit is retried after `Retry-After` or `x-ratelimit-reset`; other `4xx` (including `404`, `422`) are permanent. Alternative: all `403` permanent (simpler, but a rate-limited delivery would die).
    5. *Token kinds.* Fine-grained personal tokens and GitHub App installation tokens work as the token; minting an installation token from an App key is not part of this kind (a later kind option, additive).
    6. *Clarifications of 2026-11-07 (maintainer-approved, core #113, spec 0.3.1).* Matching the sink as merged in core PR #204: (a) an `inputs` name must not end in `_env` or `_ref`, because the core would read the value as a reference (the schema has a `propertyNames` rule); (b) the `repository_dispatch` size guard: strings are cut to 2048 bytes, and if the JSON body would still exceed 60000 bytes (escaped control characters), the cut length halves (1024, 512, ...) until it fits, with `truncated: true`. This narrows the unreleased 0.3.0 contract.

39. **`shoutrrr` sink configuration (core #120, ADR 0026; maintainer decision of 2026-11-07, spec 0.4.0).** Taken: `ShoutrrrSinkConfig` in `x-angelia-kind-config`. It has exactly one of `url_ref` and `url_env`, whose value is the **whole** shoutrrr service URL; an optional `service` (`slack`, `discord`, `telegram`, `ntfy`, `gotify`, `matrix`) that the URL's scheme must equal; and `timeout` (`1s` to `2m`, default `10s`). The reference keys carry a new annotation, `x-angelia-secret-destination: true`: the resolved value of the reference is the destination. At every delivery the server derives the HTTP origins from it and checks each one (`https`, or `http` only for a host in `http.allow_http_hosts`; the SSRF guard; the secret's `hosts`, which stay optional), then pins every request to them. A failure of these checks is retried. Only the six services above are allowed, matrix only in its access-token form, and `skiptlsverify=yes` is refused. This is the whole-URL secret that core ADR 0024 §1 left open. The host is not visible in the configuration, so the secret's `hosts`, the `service` key and `last_error` (service and origin only) show it instead. Alternatives: a base URL plus `token_ref` (per-service config shapes mirroring shoutrrr's URL formats; rejected in ADR 0026); a required `service` (it would repeat the scheme in every sink).
40. **Named source instances (core #205; 2026-11-07, spec 0.4.1).** Taken: a watch's `source` may be a registered source kind or the name of a source instance configured on the server (`sources.<name>` with `kind:`). Events always carry the base kind in `data.source`, so the `source` filter on events matches kinds while on watches it matches the watch's `source`. Description-only change; the `Kind` pattern is unchanged. Alternative: a separate `instance` field on watches (an additive field, rejected as unnecessary since the name already fits `Kind`).

41. **API token format (core #72, ADR 0030 T1 and T8; maintainer decision of 2026-11-15, spec 0.7.0).** Taken: a token is `ang_<id>_<secret><check>`, 90 characters: the prefix `ang_`, the token's ULID (its public `id`, 26 characters, upper case), `_`, 52 characters of random secret and a 7-character CRC-32 check, both in lower-case base32 (`a-z2-7`). Scanners and redaction can rely on this regular expression (no `\b`: `_` is a word character, so `\b` would not delimit the token from a neighbouring identifier); group 1 is the token:

    ```text
    (?:^|[^A-Za-z0-9_])(ang_[0-7][0-9A-HJKMNP-TV-Z]{25}_[a-z2-7]{59})(?:$|[^A-Za-z0-9_])
    ```

    The check is `check = CRC-32 (IEEE) of the ASCII bytes ang_<id>_<secret>, as 4 big-endian bytes, lower-case RFC 4648 base32 without padding` (7 characters). Test vector: the id `01JCZ8W3T6Q9N2H4K7M5R0V8XA` with the secret `fakefakefakefakefakefakefakefakefakefakefakefakefake` (the word `fake` thirteen times) has the check `7qt7acq`, so the token is `ang_01JCZ8W3T6Q9N2H4K7M5R0V8XA_fakefakefakefakefakefakefakefakefakefakefakefakefake7qt7acq`. A later format gets a new prefix (for example `ang2_`), so the format needs no version member. The check filters typos and scanner noise only: it is public and unkeyed, so it is no defence against guessing. The secret appears in exactly one place, the member `token` of the `201` response of `POST /v1/tokens` (`TokenCreated`); `GET` never returns it. That makes `TokenCreated.token` the one secret-named response member of the API: the Spectral rules allow it on that schema only, require it to be `readOnly`, and forbid a `token` member in every other schema, response and example. Alternatives: `angelia_` as the prefix (longer for no gain); no checksum.
42. **Admin scope for token metadata (core #72, ADR 0030 T5).** Taken: all four operations (`listTokens`, `createToken`, `getToken`, `revokeToken`) need `admin`, reading included, because the list shows who can do what (as for secrets). Tokens are addressed by `id` (a ULID), not by `name`: a `name` is a label, unique among active tokens only, and a revoked token's name can be reused. No MCP tool manages tokens: an agent with an admin token should not be able to mint more tokens through a tool whose call the user may not inspect. Alternative: `read` for metadata (any read token would see every other token's name and scope).
43. **Revocation, expiry and last use (core #72, ADR 0030 T6).** Taken: `DELETE /v1/tokens/{id}` revokes (`204`, and `204` again for a token that is already revoked). It takes effect on the next request on any replica; an open event stream fails at its next re-check, at most 60 seconds later (item 15); MCP over HTTP forwards the header on every call, so it fails at once. A token may revoke itself, and revoking the last active admin token is allowed (an instance-side command creates a new one). `expires_at` is optional, set at creation, and a token has no expiry by default; an expired token is `401` exactly like an unknown one, and stays listed. `last_used_at` is written at most once per token per 5 minutes, so it is accurate to about 5 minutes and a crash can lose the last interval. Alternatives: a default expiry (such as 365 days); a cache with a TTL (a revocation could then take up to the TTL to apply).
44. **Browser sessions of the admin UI (core #262, core ADR 0033 §2 to §6; maintainer decisions D1 to D8 of 2026-11-16, spec 0.8.0).** Taken: a person signs in to the instance's web UI with an identity provider (GitHub first) outside this API (`/ui/auth/...`, browser redirects), and gets a session cookie (`sessionCookie`, `angs_<id>_<secret>`, kept as a hash on the server). A request with no `Authorization` header is authenticated by that cookie; its scope is the one of the user's role in the instance's `ui.access` list (`viewer` `read`, `editor` `write`, `admin` `admin`), re-read on every request. The scope requirements of the operations are unchanged, and they keep naming `bearerAuth` only: the session is one more way to hold a scope, not another permission system. The `Authorization` header wins when both are sent; the MCP endpoint never accepts the cookie. Alternatives: list `sessionCookie` next to `bearerAuth` in every operation's `security` (doubles every requirement for no difference in scope); roles beyond the three scopes (a second permission table).
45. **CSRF rule for the cookie (core ADR 0033 §6).** Taken: a `POST`, `PUT`, `PATCH` or `DELETE` authenticated by the cookie needs both an `Origin` equal to the origin of `ui.public_url` and the header `X-Angelia-CSRF: 1`, else `403` with the new problem type `csrf`. The cookie is also `SameSite=Lax`. Requests with a bearer token are unaffected. Alternatives: a synchronizer token (state on the server for no gain over a custom header that a cross-site form cannot send); `SameSite=Strict` (breaks the sign-in redirect back from the provider).
46. **`/v1/me` and `/v1/sessions` (core #262).** Taken: `GET /v1/me` (`read`) returns `{principal_id, name, scope, kind, role, user}`, with `role` and `user` `null` for a token, so the UI knows whom it shows and which controls to offer. `GET /v1/sessions` (`admin`) lists sessions by `id`, active ones only unless `include_ended=true`, with the same paging as tokens, and `DELETE /v1/sessions/{id}` (`admin`) revokes one (`204`, again `204` when it is already revoked). A session's principal id is `<provider>:<subject>` (`github:139323`): the provider's stable id, not the login, so the audit trail survives a rename. `TokenActor`, the `created_by` and `revoked_by` of tokens, now also takes such an id, since a signed-in admin can create and revoke tokens. Alternatives: let every user list and revoke their own sessions (later, additive); a session `role` stored at sign-in (a change of `ui.access` would then wait for the session to end).

47. **Newest-first events (core #274, spec 0.9.0).** Taken: `GET /v1/events?order=desc` lists the newest events first, starting at the head of the log or below `before` (an event's `seq`, exclusive); the page's new member `next_before` (the lowest `seq` scanned; `null` with `order=asc`) is the next `before`. The cursor stays the integer `seq` of item 11, so one position means the same thing in both directions. The filters and the bounded scan are those of item 11, so a page may be empty with `has_more` true. `next_after` is the highest `seq` scanned, so a client can show the newest page and then follow new events with `after` or the stream. Reading backwards ends at the oldest event kept and never gets `410`. `order=desc` cannot be combined with `after` or `consumer`, and `before` needs `order=desc` (`400`); the stream has no `order`. Alternatives: a `tail` or `last_seq` member in the response (the client still could not page backwards); an opaque cursor (unlike `after`).
48. **Delivery filters and `Delivery.sink` (core #274).** Taken: `GET /v1/deliveries` takes `sink` (a sink name: the deliveries of the subscriptions that deliver to it now; an unknown name matches nothing; with `subscription`, both must hold), and `since` (inclusive) and `until` (exclusive), which bound the time the event was recorded in the log, the order of the list, so a time window is one contiguous run of pages. `until` must be after `since` (`400`). `Delivery` gains `sink`, the name of the sink its subscription delivers to now, `null` once the subscription was deleted, so a client needs no join. Alternatives: the time of an attempt (a delivery keeps no attempt history, only `next_attempt_at`); the sink at the time of the delivery (the delivery does not record it; additive later).
49. **`Me.session_id` (core #274).** Taken: `GET /v1/me` returns `session_id`, the `id` of the caller's own session as `GET /v1/sessions` lists it, `null` for a token, so the UI can mark the current session and not offer to revoke it by mistake. It is the public ULID inside the cookie, never the cookie or its secret part. Alternative: a `current` flag on `Session` (only an admin can list sessions).
50. **The access list, read-only (core #274, ADR 0033 §3).** Taken: `GET /v1/access` (`admin`) lists the entries of `ui.access` in configuration order: `provider` (`github`), `kind` (`user`; an open set for teams or organisations later), `login` (lower case, `null` for an entry by id), `subject` (the numeric id, or the id the login was pinned to at its first sign-in, `null` before), `pinned` and `role`. It returns no OAuth configuration (client id, secret, URLs) and no session. No write: the list is instance configuration, read at start. Alternatives: `read` scope (any viewer would learn who the admins are, a list of targets); editing the list through the API (moves a security boundary from the configuration file into the database).
51. **`config_schema` is a JSON Schema document (core #274).** Taken: `Plugin.config_schema` is a `JsonSchema` (an object of the 2020-12 dialect, `additionalProperties: true`, with `$schema`, `type`, `description`, `properties` and `required` described) or `null`, instead of an object with no members, which generators typed as an empty record. `JsonSchema` is the one schema whose property names are not snake_case: the Spectral rule skips it. Alternatives: a `$ref` to the published metaschema URL (generators and linters would fetch it over the network); `x-go-type` to a raw value (other languages still get an empty record).
52. **Optimistic concurrency on watches, sinks and subscriptions (core #274; supersedes item 8).** Taken: `GET` of one resource and the `200`/`201` of its `PUT` carry an `ETag`. It is a **strong** tag derived from the stored row: the server hashes (SHA-256, the first 128 bits, base64url) a canonical encoding of the resource's identity (`id`, `name`, owner) and configuration (the members a `PUT` writes, as stored), never its status (`status` of a watch, check times). So the tag is the same on every replica and across restarts, needs no migration, changes exactly when a write changes the resource, and a `PUT` that changes nothing keeps it. Clients treat it as opaque. `PUT` and `DELETE` take an optional `If-Match` (a list of tags, or `*`: the resource exists), compared strongly, and `PUT` an optional `If-None-Match: *` (create only); on failure `412` with the new problem type `precondition-failed`, nothing changed, `dry_run` included. As RFC 9110 §13.2.1 asks, preconditions are evaluated only when the request would otherwise succeed: `401`, `403`, `400`, `422`, `404` (on `DELETE`) and every `409` come first. The tag is a digest of the whole stored configuration, sink URLs included: it tells whether two versions are equal and could confirm an exact guess of a whole configuration, but reveals nothing of it otherwise (secret values are never in it: they are stored secrets, item 33). Alternatives: weak tags (`If-Match` compares strongly, so a weak tag never matches); a revision counter (a migration in both engines, and the file apply would have to bump it too); `updated_at` (the rows have none); an `etag` member in list items (additive later).
53. **Template preview (core #274, ADR 0016).** Taken: `POST /v1/template-previews` (`admin`, operation `previewTemplate`) renders `template` against `event` (an envelope in the request), `event_id` (an event of the log; `404` if unknown) or `sample` (`full` or `sparse`, the events every template is checked against when written; `full` by default), at most one of them. It uses the engine deliveries use, with its curated functions: no network, file, environment or clock access; it sees the event only, so no `*_ref` or `*_env` can be resolved and no secret reaches it. It is bounded more strictly than a delivery: 250 ms, 256 KiB of output, a template of at most 32 KiB, a body of at most 1 MiB. A template that does not parse or fails is a `200` with `error` (`kind`, `line`, `column`, `reason`, never quoting the template text); the output is `null` then, and otherwise comes with the `content_type` a webhook would send. Nothing is stored or sent. Alternatives: `write` scope, so an editor can preview (a write token can already have a template checked against the samples with `PUT /v1/subscriptions/{name}?dry_run=true`; `admin` is this draft's conservative choice, for review); `422` for a failing template (the request is valid; the template is the result).
54. **`EventSource` with the session cookie (core ADR 0033 §6).** Taken: the stream's description no longer says browsers cannot use `EventSource`: the admin UI is served by the instance itself, so its `EventSource` sends the session cookie on the same origin, and a `GET` needs no CSRF header (item 45). The session is checked again at the same interval as a token and the stream closes once it ends. A client with a token still needs a fetch-based SSE client. Alternative: none; this corrects the 0.8.0 text.
55. **Adopting watch-file resources (core: admin UI configure mode).** Taken: `POST /v1/adoptions` (`admin`, operation `adoptResources`) takes `objects`, a list of `{kind, name}` (`sink`, `watch`, `subscription`; at most 1000) and an optional `dry_run`, and changes each owner from `file` to `api` in place, in one transaction: ids, targets, known versions, baselines, cooldown holds and pending deliveries are kept, so nothing is missed or sent twice (re-creating the objects through the API would give new ids, a new baseline and dead-letter the held deliveries). The instance records each adopted kind and name; while the watch file still declares one, the startup apply **skips** that entry with a warning instead of failing on the taken name (item 2), and forgets the name once the file no longer declares it. A file subscription whose sink was adopted is skipped the same way. The request is all or nothing: an unknown name, a resource already managed by the API, a subscription adopted without its file sink, or a file sink adopted without every file subscription that uses it gets `422 validation-failed` with a pointer to the object, so no resource references another owner's (item 4). The response lists the adopted `{kind, name, id}`, sinks first. It needs `admin` because it moves sinks, whose writes need `admin`. Alternatives: a `managed_by` member writable with `PUT` (an ordinary edit would silently take a row from the file); re-creating the objects with `angelia apply` after removing them from the file (the documented path until now, with the losses above); writing the watch file from the API (the file is the operator's, often read-only to the process, and read only at startup).
56. **`gitlab-pipeline-trigger` sink configuration (core #90; maintainer decisions D70 to D74 of 2026-11-25, spec 0.11.0).** Taken: `GitlabPipelineTriggerSinkConfig` in `x-angelia-kind-config`, additive. It calls `POST {base_url}/api/v4/projects/{project}/trigger/pipeline` with a pipeline trigger token in the JSON body (D70; never in the URL, a header or an error). Keys: `project` (full path or numeric id), `ref` (a literal), `base_url` (default `https://gitlab.com`, marked `x-angelia-destination`; `https`, or `http` only for a host in the instance's `http.allow_http_hosts`, D72), exactly one of `token_env` and `token_ref` (D73), `variables` and `inputs` (template per entry, at most 50 each, names must not end in `_env` or `_ref`) and `timeout`. Without `variables` and `inputs` the sink sends the `ANGELIA_*` variables listed in the schema description (D71), each cut to 2048 bytes. Responses: `2xx` success, `3xx` and `4xx` except `408`/`429` permanent with a hint, `408`, `429`, `5xx` and transport errors retried after `Retry-After` or `RateLimit-Reset` (D74). Alternatives: access-token API with `PRIVATE-TOKEN` (broader token, no `TRIGGER_PAYLOAD`), a `mode` key (can be added later), a templated `ref`.
57. **Admin scope for watches of the generic HTTP sources (core angelia-dev/angelia#97, core ADR 0038; spec 0.12.0).** Taken: the source kinds `http-json` and `http-regex` fetch a URL chosen by the watch (`url` coordinate), so creating such a watch, or changing the `source` or `coordinates` of a watch whose stored or new source is of either kind, needs the `admin` scope (`403` with `required_scope: admin` otherwise, the problem of `*_ref` keys); changing only `labels`, `policy`, `scheme` or `interval` keeps `write`. MCP `add_watch` is a REST call with the caller's token, so the same rule applies there. The operation keeps `security: [write]`, as for `*_ref` keys: the scope depends on the body and the stored watch. Reason: the SSRF guard keeps watches off private networks, but an operator who allows a private network for a registry allows it for every source, and a `write` token (a CI bot, an agent) could then copy strings from internal pages into versions. The `data.package` of their events is the watch's `name` coordinate (release-event-v1.md). Alternatives: any `write` token (no rule); a per-host opt-in in the instance configuration; URLs only in the instance configuration.
58. **`mqtt` sink configuration (core #93; maintainer decisions D75 to D79 of 2026-11-25, spec 0.13.0).** Taken: `MqttSinkConfig` in `x-angelia-kind-config`, additive. The sink publishes with an in-house MQTT 3.1.1 publish-only client (D76), one connection per attempt (`CONNECT` with a clean session, `PUBLISH`, `DISCONNECT`), through the instance's SSRF guard checked on the address actually connected and its per-host limiter (D77). Keys: `url` (`mqtts://host[:port]`, default port 8883, or `mqtt://host[:port]`, default port 1883; no userinfo, path, query or fragment; marked `x-angelia-destination`), `topic` (a template, 1 to 1024 bytes), `qos` (`0` or `1`, default `1`), `retain` (default `false`), `username`, at most one of `password_env` and `password_ref` and only with `username`, `client_id_prefix` (default `angelia`) and `timeout`. Transport (D78): `mqtts://` with TLS 1.2 or later, the system roots plus `http.ca_file`, no option to skip verification; `mqtt://` only for a host in `http.allow_http_hosts`; no HTTP proxy, no WebSockets, no client certificates. Semantics (D79): QoS 1 succeeds on `PUBACK`, QoS 0 once written, no QoS 2; the payload is the rendered message (CloudEvents JSON in structured mode by default); `CONNACK` 1, 4 and 5 are permanent, 2, 3, timeouts, protocol and transport errors retried; at least once, deduplicated on the event `id`; a broker may acknowledge a publish its ACL denied. NATS is a later, separate kind (D75). Alternatives: Eclipse Paho (EPL-2.0/EDL-1.0, a long-lived async client), MQTT 5 (reason codes and CloudEvents binary mode; a later `protocol_version` key, additive), a new `mqtt.allow_plaintext_hosts` instance key instead of reusing `http.allow_http_hosts`, a long-lived connection per sink.
59. **`exec` sink configuration (core #92, core ADR 0042; maintainer decisions D100 to D104 of 2026-11-25, spec 0.14.0).** Taken: `ExecSinkConfig` in `x-angelia-kind-config`, with one required key, `command`, the name of a command the operator defined in the instance configuration (`exec.commands.<name>`). A sink set through the API, the watch file or the admin UI can choose which events reach an approved command and what the template puts on its stdin, never a path, an argument or an environment variable, so a `write` token cannot run arbitrary code. The kind is registered only when at least one command is defined (and only on Linux and macOS), so without one `kind: exec` is an unknown kind. The command gets the rendered message on stdin and six Angelia-generated `ANGELIA_*` identifiers in a clean environment; `last_error` never holds its output. Alternatives: `argv` in the sink config, freely or behind an allowlist of executables (a `write` token becomes remote code execution, and allowing `/bin/sh` allows anything); `admin` scope for `exec` sinks (a per-kind scope rule the API does not have).
61. **Open event-type set in v1 (core angelia-dev/angelia#102, sub-story 102-A; maintainer decision D85 (b) of 2026-11-25, spec 0.16.0).** Taken: the event `type` is an open set, so a later type (`release.advisory`, PRD F15) is a minor, additive change and not a `.v2`. New event types can appear in a minor release. Consumers must ignore events whose type they do not know. The envelope schema's `type` is a pattern `^dev\.angelia\.[a-z0-9]+(\.[a-z0-9]+)*\.v[0-9]+$` instead of an enum; the three release types keep their `subject` and `dataschema` rules (an `allOf` `if`/`then` entry per type), and `data` is checked against the release `data` schema whenever `dataschema` names it, which every release type does (one reference, so bundlers do not inline the schema twice). That envelope is the single v1 envelope of every event type, and `EventRecord.event` references it directly. A new type adds its rules to it as `allOf` entries: an `if`/`then` keyed on `type` for its `subject` and `dataschema`, and one keyed on its `dataschema` for its `data`. Such an entry only narrows events of a type nobody emitted before, so adding it is additive; the type may also ship its own strict envelope schema for consumers, but that is not a branch of `EventRecord.event`. Not taken: a `oneOf` with one branch per type family (an open release envelope would also accept a later type's events, so a second branch makes every such event match two branches and fail), and a `discriminator` (openapi-typescript turns its mapping into a closed union of types). The pattern requires non-empty dot-separated segments. `ShortEventType` stays an enum, so requests (subscription and consumer filters, the `type` query parameter, the MCP `events_since` input) with an unknown type are still refused early; the enum grows in minor releases, and a client must accept a value it does not know in a response. Alternatives: build the advisory type for 1.0 (about 6 person-days added to the release that freezes the first event shape); defer without opening the set (a later type costs `.v2` of the envelope, the OpenAPI document and the MCP contract, or a parallel set of endpoints); drop F15.

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
| Consumers (event cursors) | `/v1/consumers`, `/v1/consumers/{name}`, `/v1/consumers/{name}/ack` (`POST`) | `read` | `write` (`PUT`, `DELETE`, `ack`) |
| Plugins (read-only) | `/v1/plugins`, `/v1/plugins/{interface}/{kind}` | `read` | none |
| Tokens (secret returned once) | `/v1/tokens` (`GET`, `POST`), `/v1/tokens/{id}` (`GET`, `DELETE`) | `admin` (metadata only) | `admin` (`POST` creates, `DELETE` revokes) |
| The caller (read-only) | `/v1/me` | `read` | none |
| Browser sessions | `/v1/sessions` (`GET`), `/v1/sessions/{id}` (`DELETE`) | `admin` (metadata only) | `admin` (`DELETE` revokes) |
| Access list (read-only) | `/v1/access` | `admin` | none |
| Template previews (nothing stored) | `/v1/template-previews` (`POST`) | none | `admin` |

`/healthz`, `/readyz` and `/metrics` are served on the same address but are not part of this API (see the core repository's [configuration.md](https://github.com/angelia-dev/angelia/blob/main/docs/configuration.md)).

## Naming

- **Paths:** `/v1/` followed by plural resource nouns in lower case, with words joined by hyphens. Actions that are not a create, read, update or delete are a sub-resource with a verb (`/replay`) or a resource of their own (`/v1/replays`).
- **Fields and query parameters:** `snake_case`, like the release event schema and the watch file. A resource uses the same key as the watch file wherever the watch file has one (`source`, `coordinates`, `interval`, `scheme`, `labels`, `policy`, `kind`, `config`, `sink`, `filter`, `template`).
- **Keys:** watches, sinks, subscriptions, secrets and consumers are addressed by their `name` (pattern `^[a-z0-9][a-z0-9._-]{0,62}$`), unique per resource type whoever manages the resource. Each also has a response-only `id`, a ULID generated on creation and kept across updates. Events, deliveries and API tokens are addressed by their ULID `id` (a token also has a `name`, a label that is unique among active tokens and is not a key). Where a parameter accepts either (`watch`, `subscription`), the two never overlap: names are lower case, ULIDs upper case.
- **Event types** in filters are the short types of subscription filters (`release.published`, `release.yanked`, `release.prerelease`). New event types can appear in a minor release. Consumers must ignore events whose type they do not know.
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
- **Versions.** `GET` of one watch, sink or subscription, and the response of its `PUT`, carry an `ETag` (item 52). A `PUT` or `DELETE` with `If-Match: <etag>` applies only if the resource is still at that version, and a `PUT` with `If-None-Match: *` only creates; otherwise `412 precondition-failed` and nothing changes. Without these headers, the last write wins.
- **Owners.** Resources loaded from a watch file by `angelia serve --watches` have `managed_by: file`. The API reads them but refuses to change or delete them (`409 managed-by-file`) until an admin adopts them with `POST /v1/adoptions` (item 55), which makes them `api` in place, and an API resource cannot reference a file resource (`409 cross-owner-reference`): if it could, removing the file resource would make the next startup apply fail. Resources written through the API have `managed_by: api`.
- **`angelia apply`** sends one `PUT` per object, in dependency order: sinks, then watches, then subscriptions; deletions go in reverse order (subscriptions, watches, sinks). The sequence is **not atomic**: a failure leaves the objects before it applied. The API has no prune; a client that prunes lists and deletes.

## Pagination

**Lists of resources** (`watches`, `versions`, `sinks`, `secrets`, `subscriptions`, `deliveries`, `plugins`, `consumers`, `tokens`) use opaque cursors:

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
- `next_before` is `null` in this order.

**Newest first** (item 47): `order=desc` reads the log backwards, from the newest event, or from below `before`:

```http
GET /v1/events?order=desc&limit=50
GET /v1/events?order=desc&limit=50&before=4131
```

- The page lists the newest events first; `next_before` (the lowest `seq` scanned) is the `before` of the next, older page, and `has_more` says whether older events are kept. The filters and the bounded scan are the same, so a page can be empty with `has_more: true`.
- `next_after` is the highest `seq` scanned: after the first page it is the head of the log, so `after=<next_after>` or the stream then follows new events without a gap.
- Reading backwards stops at the oldest event kept; it never gets `410`. `order=desc` cannot be combined with `after` or `consumer`, and `before` needs `order=desc` (`400`).

**Consumers** keep the event cursor on the server (item 16). A consumer is created with `PUT /v1/consumers/{name}`, a stored `filter` (`watch`, `type`, `source`, as the query parameters) and an optional `start`; it is read with `consumer=` and moved only by an ack:

```http
PUT /v1/consumers/release-bot
{"filter": {"watch": ["requests"], "type": ["release.published", "release.yanked"]}}

GET /v1/events?consumer=release-bot&limit=100
POST /v1/consumers/release-bot/ack
{"seq": 4190}
```

- `GET /v1/events?consumer=c` returns exactly what `GET /v1/events?after=<acked_seq>` with the consumer's filter returns, `next_after` and `has_more` included. `limit` still applies. `consumer` cannot be combined with `after`, `watch`, `type` or `source`, by presence: `after=0` or an empty `watch=` next to `consumer` also gets `400`. An unknown consumer gets `404`.
- The filter is stored as written. Each key holds at most 100 values; an empty or absent key matches everything, so an empty `type` means every type (unlike a subscription filter, whose default is `release.published`). Watch names are resolved at each request, and once when a stream starts.
- Reading never acknowledges. After processing a page, the client acknowledges its `next_after` (which also skips the events the filter left out) or the `seq` or `event_id` of the last event it handled. An ack sets `acked_seq` to `max(acked_seq, seq)`: repeating it, or acknowledging an older position, changes nothing. A client that crashes before acknowledging reads the same events again (at least once).
- `start` applies on create only. `latest` (the default) sets `acked_seq` to the highest `seq` ever committed, pruned events included (the larger of the highest `seq` in the log and the highest pruned `seq`), read when the create commits: an event committed concurrently may or may not be included. `earliest` sets it to the highest pruned `seq` (`oldest_seq − 1`, or `0` on a log that was never pruned), so the consumer reads from the oldest event kept. A `PUT` of an existing consumer replaces its filter and never moves `acked_seq`.
- An ack accepts any `seq` up to the highest `seq` ever committed, pruned events included (the larger of the highest `seq` in the log and the highest pruned `seq`), so on a log whose every event was pruned, `latest` does not get `410` and acknowledging `oldest_seq − 1` is not refused.
- Retention does not wait for consumers. A consumer whose `acked_seq` is below the highest pruned `seq` gets `410 cursor-expired` with `oldest_seq`; acknowledging `oldest_seq − 1` resumes it after the gap. Unlike `after=0`, an `acked_seq` of `0` is checked like any other position, so a consumer that falls behind always gets `410`.
- One consumer is meant for one reader: two readers of the same consumer receive the same events.

**The event stream** `GET /v1/events/stream` takes the same filters and sends [server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html):

- The stream starts with `retry: 5000`. Each message has `id` (the `seq`) and `data` (the same `EventRecord` as the pull API, one line of JSON), and no `event` field.
- A reconnecting client sends `Last-Event-ID`, which takes precedence over `after` and over a consumer's `acked_seq`. With `consumer=`, the stream starts after the consumer's `acked_seq` with its stored filter and never moves its cursor. The consumer is read once, when the stream starts: a later `PUT` or `DELETE` of it does not affect an open stream. An expired cursor gets a `410 cursor-expired` problem response before any stream starts.
- A `: keep-alive` comment is sent when the stream has been idle for 15 seconds.
- A token goes in the `Authorization` header, which the browser `EventSource` API cannot set: a client with a token uses a fetch-based SSE client. The admin web UI, served by the instance on the same origin, authenticates with its session cookie, so a plain `EventSource` works there (item 54). The server checks the token or session again at least every 60 seconds and closes the stream once it is revoked or the session ends.

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

`400`. Malformed JSON, an unknown or invalid query parameter, a cursor the server did not issue, `consumer` combined with `after`, `watch`, `type` or `source`, `order=desc` with `after` or `consumer`, `before` without `order=desc`, or an `until` not after `since`.

#### Problem: unauthorized

`401`. No token, or an unknown, revoked or malformed one. The response carries `WWW-Authenticate: Bearer`.

#### Problem: forbidden

`403`. The token's scope is below the operation's; `required_scope` names it.

#### Problem: csrf

`403`. A `POST`, `PUT`, `PATCH` or `DELETE` authenticated by the admin UI's session cookie without an `Origin` equal to the origin of the instance's `ui.public_url` and the header `X-Angelia-CSRF: 1` (item 45). Requests with a bearer token never get it.

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

`410`. The event cursor (`after`, `Last-Event-ID` or a consumer's `acked_seq`) points into pruned events; `oldest_seq` is the oldest event kept.

#### Problem: precondition-failed

`412`. A `PUT` or `DELETE` whose `If-Match` names no current version of the resource (or `*` while it does not exist), or a `PUT` with `If-None-Match: *` on a resource that exists (item 52). Nothing was changed: read the resource again for its `ETag`.

#### Problem: payload-too-large

`413`. The request body is over 1 MiB.

#### Problem: unsupported-media-type

`415`. A request body that is not `application/json`.

#### Problem: env-not-allowed

`422`. A `*_env` key names an environment variable the instance configuration does not allow, or one starting with `ANGELIA_`.

#### Problem: secrets-key-missing

`422`. Storing a secret on an instance that has no secrets key configured (`secrets.key_file`). Nothing is stored.

#### Problem: secret-host-binding-required

`422`. A source or registry credential references a stored secret that has no `hosts`: such a secret must be bound to the hosts it is sent to. Returned once source and registry credentials can reference stored secrets (core #111).

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
| `write` | `PUT` and `DELETE` of watches, subscriptions and consumers, replay of deliveries, consumer acks |
| `admin` | `PUT` and `DELETE` of sinks, which name secrets and decide where the instance sends requests; full sink URLs; every operation on `/v1/secrets`, `/v1/tokens`, `/v1/sessions` and `/v1/access`; template previews; any write that adds, removes or changes a `*_ref` key; creating or retargeting a watch of `http-json` or `http-regex` (item 57) |

The admin web UI authenticates with a session cookie instead (`sessionCookie`, items 44 and 45): with no `Authorization` header, the cookie's session holds the scope of the user's role in the instance's `ui.access` list (`viewer` `read`, `editor` `write`, `admin` `admin`), and a request that changes something also needs `Origin` and `X-Angelia-CSRF: 1` (else `403 csrf`). `GET /v1/me` tells a client which principal and scope it has.

Each operation in the specification declares the scope it needs in its `security` requirement (OpenAPI 3.1 allows role names for a non-OAuth scheme). Tokens have the format of item 41, are created and revoked through `/v1/tokens` (items 42 and 43; [API tokens](#api-tokens)), and are stored hashed, as [core ADR 0030](https://github.com/angelia-dev/angelia/blob/main/docs/adr/0030-api-tokens.md) decides; OIDC may come later.

## API tokens

Tokens are managed through `/v1/tokens`, all operations `admin` ([core ADR 0030](https://github.com/angelia-dev/angelia/blob/main/docs/adr/0030-api-tokens.md), items 41 to 43).

- `POST /v1/tokens` takes `name`, `scope` and an optional `expires_at` (in the future) and returns `201` with the token's metadata and `token`, the token itself. This is the only response that ever carries it: store it now, the server keeps a hash only. A `name` already used by an active token is `422 validation-failed` with `errors[{pointer: "/name"}]`; there is no new problem type.
- `GET /v1/tokens` lists tokens in ascending `id` order with the usual cursor paging; revoked tokens are left out unless `include_revoked=true`. `GET /v1/tokens/{id}` returns one token, revoked or not. An unknown id is `404`, after authentication as usual (item 23).
- `DELETE /v1/tokens/{id}` revokes: `204`, also for a token that is already revoked. The row stays, so an id is never reused, and the name is free again.
- `created_by` and `revoked_by` are a token id, or `bootstrap` (the token stored from the bootstrap file) or `local` (a token created or revoked by an instance-side command). `expires_at`, `last_used_at`, `revoked_at` and `revoked_by` are `null` when they have no value. `last_used_at` is accurate to about 5 minutes.
- No MCP tool manages tokens: the tools of [docs/mcp.md](mcp.md) are unchanged.

## Browser sessions

People sign in to the admin web UI of an instance with GitHub ([core ADR 0033](https://github.com/angelia-dev/angelia/blob/main/docs/adr/0033-admin-web-ui.md); items 44 to 46). The sign-in itself is outside this API; a session is then one more way to authenticate a `/v1` request.

- `GET /v1/me` (`read`) returns the caller: `principal_id`, `name`, `scope`, `kind` (`token` or `session`), and for a session `role`, `user` (`provider`, `subject`, `login`, `name`, `avatar_url`) and `session_id`, the session's `id` in `GET /v1/sessions` (item 49).
- `GET /v1/access` (`admin`) lists the instance's `ui.access` entries (item 50): `provider`, `kind`, `login`, `subject` (an id given in the configuration, or the one a login was pinned to at its first sign-in), `pinned` and `role`. Read-only, and never the OAuth configuration.
- `GET /v1/sessions` (`admin`) lists sessions in ascending `id` order: active ones only (not revoked, not past `expires_at`, used within the instance's idle timeout) unless `include_ended=true`. Never the cookie or its hash. `last_seen_at` is accurate to about 5 minutes.
- `DELETE /v1/sessions/{id}` (`admin`) revokes a session: `204`, also when it is already revoked; `404` for an unknown id. Signing out revokes the session too, with the user's own principal id as `revoked_by`.

## Template previews

`POST /v1/template-previews` (`admin`, item 53) renders a message template against one event, without storing or sending anything, so an editor can see what a sink would receive:

```http
POST /v1/template-previews
{"template": "{\"text\": \"{{.data.package}} {{.data.version}} was released\"}", "event_id": "01JBX2A7C8D9E0F1G2H3J4K5M6"}
```

- The event is `event` (an envelope given in the request, rendered as given), `event_id` (an event of the log) or `sample` (`full` or `sparse`); at most one of them, and `full` when none is given.
- The template runs in the engine of the deliveries, with the same functions and no network, file, environment or clock access. It sees the event only: no secret is resolved. The run is bounded to 250 ms and 256 KiB of output.
- The response is `{output, content_type, error}`: the body and the `Content-Type` a webhook would send, or `error` (`kind`, `line`, `column`, `reason`) with a `200` status, since the request itself was fine. Reasons never quote the template text.

## Secrets

Secret values are stored through the API, **write-only** and encrypted at rest by the instance ([core ADR 0024](https://github.com/angelia-dev/angelia/blob/main/docs/adr/0024-secrets-encrypted-at-rest.md)). No response carries a value.

- `PUT /v1/secrets/{name}` stores `value` (text, stored as its UTF-8 bytes exactly) or `value_base64` (any bytes), at most 64 KiB, with optional `hosts`. Both value members are `writeOnly`; they never appear in a response, a log, an audit record or a problem detail (a value that is too large reports its size only). The instance needs a key (`422 secrets-key-missing` otherwise).
- `GET /v1/secrets[/{name}]` returns the name, `hosts`, `key_id`, `created_at`, `updated_at` and `referenced_by`. Every operation on `/v1/secrets` needs `admin`.
- Configuration names a stored secret with a key ending in `_ref` (`secret_ref` for the webhook signing secret), or an environment variable of the instance with a key ending in `_env` (`secret_env`). Both are names, not secrets, and are returned as written. A write that adds, removes or changes a `*_ref` key needs `admin`, whatever the endpoint's scope.
- A `*_env` name set through the API must be allowed by the instance configuration (`api.allowed_env`, default empty); names starting with `ANGELIA_` are always refused (`422 env-not-allowed`).
- `hosts` binds a secret to the hosts it may be sent to (`host` or `host:port`, exact match). A bound secret is resolved only for such a destination, and every request carrying it is checked again, redirects included. A source or registry credential may only reference a bound secret (`422 secret-host-binding-required`), from core #111.
- `DELETE /v1/secrets/{name}` is refused with `409 secret-in-use` while a reference exists.
- Below the `admin` scope, URLs in a sink's `config` are cut to `scheme://host` (`url_redacted: true`), because chat webhook URLs carry a secret in their path.
- A kind can mark a configuration key as a secret value with `x-angelia-secret: true` in its `config_schema`. The server masks such a key as `[REDACTED]` in every response (listed in `masked_fields`) and refuses it in API writes; kinds use `*_ref` keys instead. `x-angelia-destination: true` marks the URL a sink sends to, which a referenced secret's `hosts` must allow. `x-angelia-secret-destination: true` marks a `*_ref` or `*_env` key whose resolved value is itself the destination URL (the `shoutrrr` kind). The server derives the HTTP hosts from the value at every delivery and checks them against the SSRF guard and the secret's `hosts` before anything is sent. Such a key holds a name and is returned as written, like any other reference.

## Versioning

- The major version is in the path (`/v1`). Within a major version, changes are additive: new operations, new optional request fields, new response fields, new enum values in open sets, new problem types. Clients must ignore response fields they do not know.
- Adding an event type is additive (item 61): the v1 envelope that `EventRecord.event` references gains `if`/`then` entries for the new type, `ShortEventType` gains a value, and the event log, the stream and `events_since` can return events of the new type. Requests that name a type the server does not know are still refused.
- A new status code that only a new parameter or operation can produce is additive too (`404` on `GET /v1/events` exists only with `consumer`): clients that do not send the parameter never see it.
- Removing or renaming a path, a field or a parameter, changing a type, or making an optional request field required is a breaking change: a new major version (`/v2`) served next to the old one for a deprecation period, and an ADR in the core repository.
- `info.version` follows the spec repository release. While it is 0.x, the rules above are a goal, not a promise: any 0.x minor release may still break `/v1` before spec 1.0.0 freezes it.

## Code generation

The server and the CLI use code generated by [oapi-codegen](https://github.com/oapi-codegen/oapi-codegen). The event envelope is referenced from [schemas/release/envelope/v1.json](../schemas/release/envelope/v1.json) rather than copied. oapi-codegen cannot generate a type from that external JSON Schema, and the server returns stored events byte for byte, so `EventRecord.event` carries `x-go-type: json.RawMessage`. Other generators ignore the extension.

CI checks that the stubs generate and compile: [`scripts/check-go-stubs.sh`](../scripts/check-go-stubs.sh) runs oapi-codegen v2.8.2 (models, chi server, strict server, embedded spec) in a throwaway module and runs `go build` and `go vet`. The stubs are not committed here.

## Lint

CI lints the specification with [Spectral](https://github.com/stoplightio/spectral) and the ruleset in [`.spectral.yaml`](../.spectral.yaml): `spectral:oas` plus rules for the conventions above (paths under `/v1`, `snake_case` properties except in `JsonSchema` (item 51), one scope per operation, problem details for errors, no secret-named property in a response schema or example and `writeOnly` on any secret-named property (the one exception is `TokenCreated.token`, item 41: it must be `readOnly`, and no other schema, response or example may have a `token` member), `writeOnly` on the stored-secret members `value` and `value_base64` and neither of them in any response schema or example, an example for every request, response and parameter). Run it locally:

```sh
npx --yes @stoplight/spectral-cli@6.17.0 lint --fail-severity=hint openapi/angelia.v1.yaml
```
