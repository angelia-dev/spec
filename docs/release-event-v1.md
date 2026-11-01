# Release events v1 (draft)

> **Draft, pre-1.0.** While the spec repository is at version 0.x, these types and their schemas may still change in a breaking way in any 0.x minor release, without a new `.v<major>` type. The `v1` suffix names the major version that is frozen at spec 1.0.0. Decisions behind every field: [proposal 0001](proposals/0001-release-event-v1-fields.md) (Accepted).

Angelia emits three CloudEvents 1.0 types, in JSON structured mode, that share **one** `data` schema:

| Type | Short type | Emitted when |
| --- | --- | --- |
| `dev.angelia.release.published.v1` | `release.published` | A new version passes the watch's policy (including cooldown) and is not a pre-release. |
| `dev.angelia.release.prerelease.v1` | `release.prerelease` | A new version passes the watch's policy and is a pre-release (the policy's `prerelease` mode is `include` or `only`). |
| `dev.angelia.release.yanked.v1` | `release.yanked` | A version **this watch has emitted** becomes yanked upstream, detected by a later check. One event per watch per yank. |

Not events in v1 (logged only): a version yanked while held for cooldown, a version first seen yanked, un-yank, removal and return. Each could become an additive event type later.

Schemas:

- `data`: [`schemas/release/v1.json`](../schemas/release/v1.json), `$id` `https://github.com/angelia-dev/spec/schemas/release/v1.json`.
- Envelope profile: [`schemas/release/envelope/v1.json`](../schemas/release/envelope/v1.json), `$id` `https://github.com/angelia-dev/spec/schemas/release/envelope/v1.json`. It references the `data` schema.

The `$id` URLs are identifiers, not promised to be fetchable. Examples: [`examples/valid/release/v1/`](../examples/valid/release/v1/) and [`examples/valid/release/envelope/v1/`](../examples/valid/release/envelope/v1/).

## Conventions

- Field names are snake_case.
- **Every documented field is always present.** A field with no value is `null`, never omitted. Fields added later in a minor version are optional and may be absent in older events.
- Timestamps are RFC 3339 in UTC with a `Z` suffix and at most millisecond precision, for example `2026-10-30T17:00:02.512Z`.
- **Open sets.** The values of `source`, `scheme` and `notes.format` are documented lists, not closed enums: they match `^[a-z0-9][a-z0-9-]{0,62}$`, and consumers must accept values they do not know. `bump` and the event `type` are closed enums.
- **Open objects, tolerant consumers.** Producers emit only the documented fields in `data` and its nested objects, and only the documented envelope attributes (no extension attributes in v1). Consumers **must ignore** fields and extension attributes they do not know: the `data` schema and its nested objects (`urls`, `notes`, `watch`) accept unknown properties, and the envelope schema accepts any attribute whose name is a valid CloudEvents extension name (`^[a-z0-9]{1,20}$`, for example `traceparent` added by a tracing intermediary). Other unknown envelope names are rejected. Adding a new optional field or attribute is therefore a **minor** change.

## Envelope attributes

| Attribute | Required | Value |
| --- | --- | --- |
| `specversion` | yes | `"1.0"`. |
| `type` | yes | One of the three types above. The short type is `type` without the `dev.angelia.` prefix and the `.v<major>` suffix; subscription filters use it. |
| `source` | yes | `angelia://<instance>/watches/<watch_id>`, for example `angelia://angelia/watches/01JBX1Z3M4N5P6Q7R8S9T0V1W2`. `<instance>` is the instance name from the instance configuration (pattern `^[a-z0-9][a-z0-9.-]{0,62}$`, default `angelia`); `<watch_id>` equals `data.watch.id`. Two watches on one package produce two events with different `source` values. |
| `id` | yes | ULID: 26 characters, Crockford base32, upper case. Generated once when the event is written. Every delivery attempt, retry and replay carries the same `id`: deduplicate on it (delivery is at-least-once). `source` + `id` is globally unique. The `id` is not derived from content: to get one notification per release across two watches, deduplicate on `data.purl` + `type` or `subject` + `type`. |
| `subject` | yes | `<source kind>:<package>@<version>` with the raw version, for example `pypi:requests@2.33.0`, `npm:@angular/core@17.3.0`, `github-release:cli/cli@v2.62.0`. |
| `time` | yes | When the event was **emitted** (the end of the check that emitted it). With a cooldown this is later than `data.detected_at`. |
| `datacontenttype` | yes | `"application/json"`. |
| `dataschema` | yes | `"https://github.com/angelia-dev/spec/schemas/release/v1.json"`. Once the spec repository has release tags it will name a tagged, versioned URL instead. |
| `data` | yes | The payload described below. |

v1 defines **no extension attributes**, and Angelia emits none. Consumers must ignore extension attributes they find anyway (a broker or tracing intermediary may add `traceparent`, for example); the envelope schema allows any name matching `^[a-z0-9]{1,20}$`. `partitionkey` (the CloudEvents Partitioning extension) is planned with the NATS, MQTT and Kafka sinks, as an additive change.

The per-delivery `idempotency-key` and the Standard Webhooks `webhook-id` are delivery headers, not CloudEvents attributes.

## Rules that depend on the type

The `data` schema cannot check these, because `data` does not carry the type. Producers must follow them and consumers may rely on them.

| Field | `release.published` | `release.prerelease` | `release.yanked` |
| --- | --- | --- | --- |
| `prerelease` | `false` | `true` | as in the emitted event |
| `yanked` | `false` | `false` | `true` |
| `detected_at` | first check that saw the version | first check that saw the version | first check that saw the yank |
| `cooldown_satisfied_at` | set or `null` | set or `null` | always `null` |

A `release.yanked` event repeats the classification of the event the watch emitted for that version (`version`, `normalized_version`, `previous_version`, `scheme`, `bump`, `backport`, `prerelease`, read from the stored earlier payload), so it matches what the subscriber received.

## `data` fields

### `source`

- **Type:** string, open set. **Required, not null.**
- Source kind of the watch that produced the event. Known values: `pypi`, `npm`, `crates`, `github-release`, `github-tag`, `gitlab-release`, `oci`, `go-proxy`, `maven`, `http-json`, `http-regex`, or a plugin's kind.
- Not the CloudEvents `source` attribute (a URI): in templates write `.data.source`. It is the value the subscription filter's `source` key matches.
- Example: `"pypi"`

### `package`

- **Type:** string. **Required, not null.**
- Package name as the source normalised it. The form depends on the source kind: `requests` (pypi), `@angular/core` (npm), `serde` (crates), `cli/cli` (GitHub owner/repo), `group/subgroup/project` (GitLab path), `ghcr.io/org/image` (OCI), `github.com/gorilla/mux` (Go module path), `org.slf4j:slf4j-api` (Maven). The subscription filter's `package` glob matches it.
- Example: `"requests"`

### `version`

- **Type:** string. **Required, not null.**
- The raw upstream version string, exactly as the registry or forge lists it: a tag stays `v2.62.0`. What a consumer installs, pins or checks out.
- Example: `"2.33.0"`

### `normalized_version`

- **Type:** string. **Required, not null.**
- The version in the classifying scheme's normalised form, so consumers can compare without reimplementing PEP 440 or SemVer. PEP 440 `1.0-RC1` gives `1.0rc1`. Equals `version` for the lexical fallback.
- Example: `"2.33.0"`

### `previous_version`

- **Type:** string or null. **Required, nullable.**
- Raw string of the version this one was classified against: the greatest earlier version of the same scheme. For the backport `1.9.4` detected after `2.0.0` it is `1.9.3`, not `2.0.0`.
- `null` when there is nothing to compare with: the first version, or the lexical fallback.
- Example: `"2.32.5"`

### `scheme`

- **Type:** string, open set. **Required, not null.**
- Version scheme that classified the version. Known values: `semver`, `pep440`, `calver`, `lexical`; `maven` later.
- Example: `"pep440"`

### `bump`

- **Type:** closed enum or null. **Required, nullable.**
- Change from `previous_version` to `version`:
  - `major`, `minor`, `patch`: the usual meaning for the scheme;
  - `prerelease`: between pre-releases of the same core version (`2.0.0-rc.1` to `2.0.0-rc.2`);
  - `other`: an alias of equal precedence, a version not greater than its previous one, or a comparison across schemes.
- `null` when `previous_version` is `null`.
- Example: `"minor"`

### `backport`

- **Type:** boolean. **Required, not null.**
- `true` when a greater version of the same scheme was already known, and not removed, when this one was detected (`1.9.4` after `2.0.0`). Tells a backport from a new latest version.
- Example: `false`

### `prerelease`

- **Type:** boolean. **Required, not null.**
- Whether the version is a pre-release: the upstream flag when the source gives one (GitHub, npm dist-tags), otherwise the opinion of the watch's scheme.
- Example: `false`

### `yanked`

- **Type:** boolean. **Required, not null.**
- Whether the version is yanked, unpublished or withdrawn upstream at the time of the event. A version first seen yanked is never emitted.
- Example: `false`

### `published_at`

- **Type:** timestamp or null. **Required, nullable.**
- Upstream publish date as the registry or forge reports it, unchanged. `null` when the source gives none.
- **Not trustworthy for every kind.** Registries assign the date for `pypi`, `npm`, `crates` and `github-release`. `github-tag` gives the committer date and `oci` the image's own `created` field: both are set by the publisher and can be back-dated.
- Example: `"2026-10-27T14:02:11Z"`

### `detected_at`

- **Type:** timestamp. **Required, not null.**
- Time of the check that first saw the version; on `release.yanked`, of the check that first saw the yank.
- Example: `"2026-10-30T17:00:00Z"`

### `cooldown_satisfied_at`

- **Type:** timestamp or null. **Required, nullable.**
- When the version passed the watch's cooldown: cooldown start + cooldown. The start is `published_at` for kinds whose date the registry assigns (`pypi`, `npm`, `crates`, `github-release`) when it is not after `detected_at`, and `detected_at` otherwise (this basis rule is still pending in the core repository).
- `null` when the watch has no cooldown. Always `null` on `release.yanked`.
- Example: `"2026-10-30T14:02:11Z"`

### `urls`

- **Type:** object. **Required, not null.** Its three keys are always present.
- Links about the release. Each URL is `https`; an `http` URL from a private registry is passed as given. A URL is absolute, has a non-empty host and contains no whitespace (pattern `^https?://[^\s/?#]+([/?#]\S*)?$`).

### `urls.release`

- **Type:** URL or null. **Required, nullable.**
- Release page: GitHub release, PyPI project version page, npm version page. `null` when unknown.
- Example: `"https://pypi.org/project/requests/2.33.0/"`

### `urls.changelog`

- **Type:** URL or null. **Required, nullable.**
- Release notes or changelog page. `null` when unknown.
- Example: `"https://github.com/psf/requests/blob/main/HISTORY.md"`

### `urls.artifact`

- **Type:** URL or null. **Required, nullable.**
- Downloadable artifact when there is exactly one obvious one (npm tarball, crate download). `null` for PyPI (many files per version), forges and OCI, and whenever the source does not report it.
- Example: `"https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz"`

### `notes`

- **Type:** object or null. **Required, nullable.**
- Release notes text. `null` until notes enrichment exists (PRD F12): no source fetches a notes body yet. When it is an object, its three keys are always present.

### `notes.format`

- **Type:** string, open set. **Required, not null** (inside `notes`).
- Format of `body`. Known values: `markdown`, `text`. HTML is converted or sent as `text`, never passed through.
- Example: `"markdown"`

### `notes.body`

- **Type:** string. **Required, not null** (inside `notes`).
- Notes text, at most **16,384 bytes of UTF-8**, cut at a character boundary. JSON Schema counts characters, so the schema only checks the weaker bound of 16,384 characters; producers enforce the byte limit.
- Example: `"## 2.33.0\n\n- Fix ..."`

### `notes.truncated`

- **Type:** boolean. **Required, not null** (inside `notes`).
- `true` when `body` was cut to the limit. The full text is at `urls.changelog` or `urls.release`.
- Example: `true`

### `watch`

- **Type:** object. **Required, not null.**
- The watch that produced the event.

### `watch.id`

- **Type:** string (ULID). **Required, not null.**
- Watch id, a bare ULID as the store generates it, the same string as in the API and logs. Stable across edits of the watch (including a change of source or coordinates); a renamed or recreated watch gets a new id. Equals the last segment of the envelope `source`.
- Example: `"01JBX1Z3M4N5P6Q7R8S9T0V1W2"`

### `watch.name`

- **Type:** string or null. **Required, nullable.**
- The watch's `name` from the watch file. `null` for watches created through the API without a name. Lets a consumer tell watches apart without a lookup.
- Example: `"requests"`

### `watch.labels`

- **Type:** object of string to string. **Required, not null.**
- The watch's labels; `{}` when it has none, never `null`. At most 32 entries; keys match `^[A-Za-z0-9][A-Za-z0-9._/-]{0,62}$`; values are at most 253 characters. The subscription filter's `labels` key matches them.
- Example: `{"team": "platform", "repo": "api"}`

### `purl`

- **Type:** string or null. **Required, nullable.**
- [Package URL](https://github.com/package-url/purl-spec) of this version, built per source kind as described in the next section.
- `null` for kinds without a purl type (`http-json`, `http-regex`, plugins) and when the identity cannot be built.
- Example: `"pkg:pypi/requests@2.33.0"`

## purl rules per source kind

General rules, from the purl specification:

- Form: `pkg:<type>/<namespace>/<name>@<version>?<qualifiers>`. Each segment is percent-encoded: `@` in a namespace becomes `%40`, `+` in a version (SemVer build metadata) becomes `%2B`, `:` in a digest becomes `%3A`.
- The version is the **raw** upstream version (`data.version`), so the purl names exactly what the registry serves.
- When the watch uses a non-default registry (the instance configuration's `sources.<kind>.base_url`), the purl gets the `repository_url` qualifier with that base URL. On the public registry it has no qualifier.
- The purl type is the purl specification's, not Angelia's source kind: `cargo`, not `crates`; `golang`, not `go-proxy`.

| Source kind | purl | Name and case rules | Example |
| --- | --- | --- | --- |
| `pypi` | `pkg:pypi/<name>@<version>` | Name lower-cased, runs of `-`, `_`, `.` replaced by one `-` (PEP 503). | `pkg:pypi/typing-extensions@4.12.2` for `typing_extensions` |
| `npm` | `pkg:npm/<name>@<version>`, or `pkg:npm/%40<scope>/<name>@<version>` for a scoped package | The scope is the namespace, `@` percent-encoded. | `pkg:npm/%40angular/core@17.3.0` |
| `crates` | `pkg:cargo/<name>@<version>` | Name as published. | `pkg:cargo/serde@1.0.215` |
| `github-release` | `pkg:github/<owner>/<repo>@<tag>` | Owner and repo lower-cased. The version is the release's tag name. | `pkg:github/cli/cli@v2.62.0` |
| `github-tag` | `pkg:github/<owner>/<repo>@<tag>` | Same as `github-release`: a release and its tag have the same purl; `data.source` tells them apart. | `pkg:github/golang/go@go1.23.3` |
| `gitlab-release` | `pkg:gitlab/<group>/<subgroup...>/<project>@<tag>` | Every path segment except the last is the namespace, lower-cased. A self-managed GitLab adds `repository_url`. A watch whose `project` coordinate is a numeric id needs the source to report the path; otherwise `purl` is `null`. | `pkg:gitlab/gitlab-org/gitlab-runner@v17.5.0` |
| `oci` | `pkg:oci/<image name>@sha256%3A<digest>?repository_url=<registry>/<path>&tag=<tag>` | The version is the manifest **digest**; the tag is the `tag` qualifier and the registry path the `repository_url` qualifier. Name is the last path segment, lower case. Until the source reports digests: a versionless purl with the `tag` qualifier. | `pkg:oci/node@sha256%3Ae3b0c4...?repository_url=docker.io/library/node&tag=22.11.0`; without digest `pkg:oci/node?repository_url=docker.io/library/node&tag=22.11.0` |
| `go-proxy` | `pkg:golang/<module path>@<version>` | The module path's segments before the last are the namespace. Case is kept; the proxy's `!` escaping is not used. | `pkg:golang/github.com/gorilla/mux@v1.8.1` |
| `maven` | `pkg:maven/<groupId>/<artifactId>@<version>` | The group id is the namespace. A repository other than Maven Central adds `repository_url`. | `pkg:maven/org.slf4j/slf4j-api@2.0.16` |
| `http-json`, `http-regex`, plugins | `null` | No package identity is known; a `pkg:generic/...` purl would invent one. | `null` |

## Mapping to the subscription matcher

| Matcher input | From the event |
| --- | --- |
| source | `data.source` |
| package | `data.package` |
| labels | `data.watch.labels` |
| bump | `data.bump`, with `null` mapped to an empty value |
| type | `type` without `dev.angelia.` and `.v1`, for example `release.published` |

The short type is not repeated inside `data`.

## Not in the payload

Deliberately left out: source-specific upstream metadata (digests, dist-tags, deprecation), target coordinates and the target id (`package` is the public identity), the watch's policy, and the raw upstream response.
