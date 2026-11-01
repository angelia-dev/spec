# Proposal 0001: release event v1, envelope profile and field names

- **Status:** Accepted (maintainer, 2026-11-01, PR #6)
- **Decision:** the recommendation of every open question in section 7 is adopted as written. Implemented in `schemas/release/v1.json`, `schemas/release/envelope/v1.json` and `docs/release-event-v1.md`.
- **Date:** 2026-11-01
- **Story:** angelia-dev/spec#2 (Human-led)
- **Sources read:** core repository `main` at `660363a`: architecture.md §3.3 to §5, prd.md, ADR 0004, 0006, 0010, 0012, `docs/watch-file.md`, `internal/version`, `internal/policy` (`Release`), `internal/diff` (`Change`), `internal/subscription` (`Input`, `Filter`), `internal/source` (`Version`, source kinds)

This proposal names and types every field of the three release events before any schema, example or docs page is written. The issue requires the maintainer to approve the naming first. When the maintainer has answered the open questions (section 7), the follow-up commits on this story write `schemas/release/v1.json`, the examples and the per-field docs page from the approved tables, and nothing else.

## 1. Summary

- CloudEvents 1.0, JSON structured mode, three types: `dev.angelia.release.published.v1`, `dev.angelia.release.yanked.v1`, `dev.angelia.release.prerelease.v1`. One `data` schema for all three.
- Field names are **snake_case**, as in architecture.md §4, the watch file and the store (`published_at`, `previous_version`).
- Every field of the §4 example is kept. One rename is proposed, `ecosystem` to `source`, because the approved watch-file decision D16 and the subscription matcher already use `source` (Q1).
- Three fields not in §4 are proposed: `normalized_version`, `backport` and `watch.name`, each a value the code already produces (Q12). `previous_version`, `bump`, `published_at`, `cooldown_satisfied_at`, `notes` and `purl` are nullable because the code can leave them empty.
- Convention: **every documented field is always present**; a field with no value is `null`, never omitted. Consumers and templates then never need to tell "missing" from "null". Fields added later in a minor version are necessarily optional and may be absent in older events.
- Open enums: values of `source`, `scheme` and `notes.format` are **documented strings, not closed JSON Schema enums**. The spec README says changing an enum is a major change; a closed `source` enum would force a new major version for every new source kind (Q8).

## 2. CloudEvents envelope profile

| Attribute | Required | Value | Notes |
| --- | --- | --- | --- |
| `specversion` | yes | `"1.0"` | CloudEvents 1.0. |
| `type` | yes | `dev.angelia.release.published.v1`, `dev.angelia.release.yanked.v1` or `dev.angelia.release.prerelease.v1` | Reverse-DNS prefix `dev.angelia.`, then the short type, then `.v<major>`. The short type (`release.published`, ...) is what the subscription filter and `subscription.Input.Type` use: short type = `type` without the `dev.angelia.` prefix and the `.v<major>` suffix. When each type is emitted: section 5. `release.advisory` is reserved for later (PRD F15) and not in this proposal. |
| `source` | yes | `angelia://<instance>/watches/<watch_id>` (recommended; §4 has `angelia://<instance>/watches/<ecosystem>/<name>`) | The context that produced the event is the watch: the event row is per watch (`event.watch_id`, architecture.md §5), and two watches on one target produce two events. See Q2 for the form and Q3 for `<instance>`. |
| `id` | yes | ULID, 26 characters, Crockford base32, upper case | ADR 0004 §6. Generated once when the event row is written, in the check's transaction. See below. |
| `subject` | yes | `<source kind>:<package>@<version>`, e.g. `pypi:requests@2.33.0`, `npm:@angular/core@17.3.0`, `github-release:cli/cli@v2.62.0` | As in §4. `<version>` is the raw upstream version (`data.version`). Lets brokers and routers filter without parsing `data`. Q4 discusses using the purl instead. |
| `time` | yes | RFC 3339, UTC, `Z` suffix, millisecond precision at most | The time the event was **emitted** (`event.created_at`): the end of the check that emitted it. With a cooldown this is later than `data.detected_at`. The §4 example shows `time` = `detected_at`, which only holds without a cooldown (Q10). |
| `datacontenttype` | yes | `"application/json"` | Always JSON. |
| `dataschema` | yes | URI of the data schema, e.g. `https://github.com/angelia-dev/spec/schemas/release/v1.json` | The `$id` of `schemas/release/v1.json`, following the placeholder's `$id` convention. It is an identifier, not promised to be fetchable (Q11). |
| `data` | yes | object, section 3 | |

**`id` semantics.**

- Unique per instance; `source` + `id` is globally unique as CloudEvents requires (the ULID alone is already unique in practice).
- The event is immutable (ADR 0004 §3): every delivery attempt, retry and replay of the same event carries the **same** `id`. Consumers deduplicate on `id` (delivery is at-least-once). The per-delivery `idempotency-key` (`event.id + subscription.id`) and the Standard Webhooks `webhook-id` are delivery headers, not CloudEvents attributes.
- The `id` is not derived from content. Two watches on the same target emit two events with different ids for the same release; a consumer that subscribes to both and wants one notification per release deduplicates on `data.purl` + `type` (or `subject` + `type`). A content-derived id was considered and rejected: the same version can legitimately produce a second `release.published` after a watch is deleted and created again (new baseline), and ULIDs keep the time order that the pull API and logs rely on.
- The ULID timestamp is the emission time. It is not the pull-API cursor (ADR 0008 keeps a separate `event.seq`).

**Extension attributes.** None in v1 (recommended). Everything a consumer filters on is in `data`, and the subscription filter reads the stored event, not the envelope. Candidates for later, all valid extension names (lowercase alphanumeric, at most 20 characters): `partitionkey` (the standard CloudEvents Partitioning extension, for the NATS, MQTT and Kafka sinks of PRD F8: one partition per package keeps per-package order), `angeliawatch` (12 characters, the watch id for broker-side routing), `angeliabump` (11). See Q5.

## 3. The `data` payload

"Required" means the key is always present. "Nullable" means its value may be `null`. Types are JSON types; `string (date-time)` is an RFC 3339 timestamp in UTC with a `Z` suffix and at most millisecond precision (the store keeps unix milliseconds, architecture.md §5).

| Name | JSON type | Required / nullable | Description | Example | Source in code or §4 |
| --- | --- | --- | --- | --- | --- |
| `source` | string | required, not null | Source kind of the watch that produced the event: `pypi`, `npm`, `crates`, `github-release`, `github-tag`, `gitlab-release`, `oci`, `go-proxy`, `maven`, `http-json`, `http-regex`, or a plugin's kind. Open set (Q8). Pattern `^[a-z0-9][a-z0-9-]{0,62}$`. **§4 calls this field `ecosystem`** (Q1). | `"pypi"` | §4 `ecosystem`; `target.kind`; `source.Source.Kind()`; `subscription.Input.Source` ("the ecosystem of the PRD"); watch-file `watches[].source` and filter key `source` (D16) |
| `package` | string | required, not null | Package name as the source normalised it (ADR 0006: the source owns normalisation). Its form depends on the source kind: `requests`, `@angular/core`, `serde`, `cli/cli` (GitHub `owner/repo`), `group/subgroup/project` (GitLab path), `ghcr.io/org/image` (OCI), `github.com/gorilla/mux` (Go module path), `org.slf4j:slf4j-api` (Maven). What the filter's `package` glob matches. | `"requests"` | §4 `package`; `subscription.Input.Package`; target coordinates (`name`, `repo`, `project`) |
| `version` | string | required, not null | The **raw** upstream version string, exactly as the registry lists it: a tag stays `v2.62.0`. This is what a consumer installs, pins or checks out. | `"2.33.0"` | §4 `version`; `policy.Release.Raw`; `source.Version.Raw` |
| `normalized_version` | string | required, not null | The version in the classifying scheme's normalised form; equals `version` for a lexical fallback. Lets consumers compare without reimplementing PEP 440 or SemVer. **New, not in §4** (Q12). | `"2.33.0"` (PEP 440 `1.0-RC1` gives `1.0rc1`) | `policy.Release.Normalized`; `version.Version.String()` |
| `previous_version` | string | required, nullable | Raw string of the version this one was classified against: the greatest earlier version of the same scheme (ADR 0010 §8), so for the backport `1.9.4` after `2.0.0` it is `1.9.3`, not `2.0.0`. `null` when there is nothing to compare with (first version, or a lexical fallback). | `"2.32.5"` | §4 `previous_version`; `diff.Change.Previous`, `policy.Release.Previous` |
| `scheme` | string | required, not null | Name of the version scheme that classified the version: `semver`, `pep440`, `calver`, `lexical`; `maven` later. Open set (Q8). | `"pep440"` | §4 `scheme`; `policy.Release.Scheme`; `schemes.Names()` |
| `bump` | string | required, nullable | Change from `previous_version` to `version`: `major`, `minor`, `patch`, `prerelease` or `other`; `null` when `previous_version` is `null`. Values and meaning in Q7. | `"minor"` | §4 `bump`; `version.Bump`; `policy.Release.Bump`; `subscription.Input.Bump` |
| `backport` | boolean | required, not null | True when a greater version of the same scheme was already known and not removed when this one was detected (`1.9.4` after `2.0.0`). **New, not in §4** (Q12). | `false` | `policy.Release.Backport`; ADR 0010 §9 |
| `prerelease` | boolean | required, not null | Whether the version is a pre-release: the upstream flag when the source gives one (GitHub, npm dist-tags), otherwise the scheme's opinion for the watch's scheme. | `false` | §4 `prerelease`; `policy.Release.Prerelease`; `source.Version.Prerelease` |
| `yanked` | boolean | required, not null | Whether the version is yanked, unpublished or withdrawn upstream at the time of the event. Always `false` on `release.published` and `release.prerelease` (a version first seen yanked is never emitted, ADR 0012 §1); always `true` on `release.yanked`. See Q9. | `false` | §4 `yanked`; `source.Version.Yanked`; `version.yanked` |
| `published_at` | string (date-time) | required, nullable | Upstream publish date as the registry or forge reports it. `null` when the source gives none. **Not trustworthy for every kind**: `github-tag` gives the committer date and `oci` the image's own `created` field, both set by the publisher (ADR 0012 §6). | `"2026-10-27T14:02:11Z"` | §4 `published_at`; `policy.Release.PublishedAt` (zero when unknown) |
| `detected_at` | string (date-time) | required, not null | Time of the check that first saw the version (for `release.yanked`: the check that first saw the yank). | `"2026-10-30T17:00:00Z"` | §4 `detected_at`; `policy.Release.DetectedAt`; `version.first_seen_at` |
| `cooldown_satisfied_at` | string (date-time) | required, nullable | When the version passed the watch's cooldown: cooldown start + cooldown. The start is `published_at` for kinds whose date the registry assigns (`pypi`, `npm`, `crates`, `github-release`) when it is not after `detected_at`, and `detected_at` otherwise (ADR 0012 §6, pending confirmation). `null` when the watch has no cooldown. Always `null` on `release.yanked`. See Q11 on how much of the policy decision to expose. | `"2026-10-30T14:02:11Z"` | §4 `cooldown_satisfied_at`; `policy.Release.CooldownSatisfiedAt`; `Release.CooldownFrom` |
| `urls` | object | required, not null | Links about the release. Each key is always present and `null` when unknown. Only `https` URLs (an `http` URL from a private registry is passed as given). | | §4 `urls` |
| `urls.release` | string (uri) | required, nullable | Release page (GitHub release, PyPI project version page, npm version page). | `"https://pypi.org/project/requests/2.33.0/"` | §4; `source.Version.URL`, `policy.Release.URL` |
| `urls.changelog` | string (uri) | required, nullable | Release notes or changelog. **The code calls it `NotesURL`** (Q13). | `"https://github.com/psf/requests/blob/main/HISTORY.md"` | §4; `source.Version.NotesURL`, `policy.Release.NotesURL` |
| `urls.artifact` | string (uri) | required, nullable | Downloadable artifact when there is exactly one obvious one (npm tarball, crate download URL). `null` for PyPI (many files per version), forges and OCI. No source fills it in a typed field today; it comes from `Metadata` (Q13). | `"https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz"` | §4; `source.Version.Metadata` (tarball URL) |
| `notes` | object | required, nullable | Release notes text. `null` until notes enrichment exists (PRD F12, Phase 2): no source fetches a notes body today. | | §4 `notes` |
| `notes.format` | string | required, not null | `markdown` or `text`. Open set (Q8). HTML is converted or sent as `text`, never passed through. | `"markdown"` | §4 |
| `notes.body` | string | required, not null | Notes text, at most the size limit (Q6), cut at a UTF-8 character boundary. | `"## 2.33.0\n\n- Fix ..."` | §4 |
| `notes.truncated` | boolean | required, not null | True when `body` was cut to the limit. The full text is at `urls.changelog` or `urls.release`. | `true` | §4 |
| `watch` | object | required, not null | The watch that produced the event. | | §4 `watch` |
| `watch.id` | string | required, not null | Watch id: a ULID, as the store generates it (§4's `w_123` is illustrative; Q14). Stable across edits of the watch (including a change of source or coordinates); a renamed or recreated watch gets a new id. | `"01JBX1Z3M4N5P6Q7R8S9T0V1W2"` | §4; `watch.id`, `event.watch_id` |
| `watch.name` | string | required, nullable | The watch's `name` from the watch file; `null` for watches created through the API without a name. **New, not in §4**. Lets a consumer tell watches apart without a lookup. | `"requests"` | watch-file §2.1; `watch.name` (migration 00004) |
| `watch.labels` | object (string → string) | required, not null | The watch's labels; `{}` when it has none. At most 32 entries, keys `^[A-Za-z0-9][A-Za-z0-9._/-]{0,62}$`, values at most 253 characters. What the filter's `labels` matches. Shape: Q15. | `{"team": "platform", "repo": "api"}` | §4 `watch.labels`; `watch.labels_json`; `subscription.Input.Labels`; watch-file §2.2 |
| `purl` | string | required, nullable | Package URL of this version, per section 4. `null` for kinds without a purl type (`http-json`, `http-regex`, plugins) and when the identity cannot be built. (This row first listed an OCI image without a digest here; the answer to Q16 supersedes that: such an image gets a versionless purl with a `tag` qualifier, see section 4.) | `"pkg:pypi/requests@2.33.0"` | §4 `purl`; ADR 0004 §2 |

**Mapping to the subscription matcher** (`internal/subscription.Input`, which the issue says the event must map to):

| `Input` field | From the event |
| --- | --- |
| `Source` | `data.source` |
| `Package` | `data.package` |
| `Labels` | `data.watch.labels` |
| `Bump` | `data.bump`, with `null` mapped to `""` |
| `Type` | `type` without `dev.angelia.` and `.v1` (`release.published`) |

No field needs I/O to fill, as `Input`'s comment requires. `Type` is not repeated inside `data` (Q17).

**Not in the payload** (deliberately): `Metadata` (source-specific, unvalidated upstream data: digests, dist-tags, deprecation), target coordinates and the target id (internal; `package` is the public identity), the watch's policy, and the raw upstream response.

## 4. purl rules per source kind

General rules, from the purl specification:

- `pkg:<type>/<namespace>/<name>@<version>?<qualifiers>`. Each segment is percent-encoded: `@` in a namespace becomes `%40`, `+` in a version (SemVer build metadata) becomes `%2B`, `:` in a digest becomes `%3A`.
- The version is the **raw** upstream version (`data.version`), so the purl names exactly what the registry serves.
- When the watch uses a non-default registry (PRD F16: the instance config's `sources.<kind>.base_url`), the purl gets the `repository_url` qualifier with that base URL. On the public registry it has no qualifier.
- The purl type is the purl specification's, not Angelia's source kind (`cargo`, not `crates`; `golang`, not `go-proxy`).

| Source kind | purl | Name and case rules | Example |
| --- | --- | --- | --- |
| `pypi` | `pkg:pypi/<name>@<version>` | Name lower-cased and each `_` replaced by `-`, as the purl `pypi` type text says; no `.` folding, so `zope.interface` stays `pkg:pypi/zope.interface` (amended after acceptance, section 10; the first version said PEP 503). | `pkg:pypi/typing-extensions@4.12.2` for `typing_extensions` |
| `npm` | `pkg:npm/<name>@<version>`, or `pkg:npm/%40<scope>/<name>@<version>` for a scoped package | Scope is the namespace, `@` percent-encoded. Names are already lower case on the public registry. | `pkg:npm/%40angular/core@17.3.0` |
| `crates` | `pkg:cargo/<name>@<version>` | Name as published (crates.io names are case-insensitive for lookup but keep their published case). | `pkg:cargo/serde@1.0.215` |
| `github-release` | `pkg:github/<owner>/<repo>@<tag>` | Owner and repo lower-cased (the `github` type is case-insensitive). Version is the release's tag name. | `pkg:github/cli/cli@v2.62.0` |
| `github-tag` | `pkg:github/<owner>/<repo>@<tag>` | Same as `github-release`. A release and its tag therefore have the same purl, which is correct: they name the same source tree. `data.source` tells them apart. | `pkg:github/golang/go@go1.23.3` |
| `gitlab-release` | `pkg:gitlab/<group>/<subgroup...>/<project>@<tag>` | Every path segment except the last is the namespace (subgroups included), lower-cased. A self-managed GitLab adds `repository_url`. A watch whose coordinate `project` is a numeric id needs the path: the source must report it, or `purl` is `null` (Q16). | `pkg:gitlab/gitlab-org/gitlab-runner@v17.5.0` |
| `oci` | `pkg:oci/<image name>@sha256%3A<digest>?repository_url=<registry>/<path>&tag=<tag>` | The `oci` type's version is the manifest **digest**, not the tag; the tag is the `tag` qualifier and the registry path the `repository_url` qualifier. Name is the last path segment, lower case. Without a known digest: Q16. The `oci` source is not implemented yet. | `pkg:oci/node@sha256%3Ae3b0c4...?repository_url=docker.io/library/node&tag=22.11.0` |
| `go-proxy` | `pkg:golang/<module path>@<version>` | The module path's segments before the last are the namespace. Case is kept (module paths are case-sensitive; the proxy's `!` escaping is not used in the purl). This deviates from the purl `golang` type text, which says to lower-case. The task calls this kind `go`; the code and architecture.md call it `go-proxy` (Q8). | `pkg:golang/github.com/gorilla/mux@v1.8.1` |
| `maven` | `pkg:maven/<groupId>/<artifactId>@<version>` | Group id is the namespace. A repository other than Maven Central adds `repository_url`. Phase 1 (no `maven` scheme or source yet). | `pkg:maven/org.slf4j/slf4j-api@2.0.16` |
| `http-json`, `http-regex`, plugins | `null` | No package identity is known; a `pkg:generic/...` purl would invent one. | `null` |

## 5. When each type is emitted

Today the policy engine (ADR 0012) emits releases; turning them into events is story angelia-dev/angelia#106 and yank events are #112. This section is the proposed contract those stories implement.

| Type | Emitted when | `prerelease` | `yanked` |
| --- | --- | --- | --- |
| `release.published` | A new version passes the watch's policy (including cooldown) and is **not** a pre-release. | `false` | `false` |
| `release.prerelease` | A new version passes the watch's policy and **is** a pre-release (the policy's `prerelease` mode is `include` or `only`). | `true` | `false` |
| `release.yanked` | A version **this watch has emitted** becomes yanked upstream (detected by a later check). One event per watch per yank. | as emitted | `true` |

Not events in v1 (all logged only, as today): a version yanked while held for cooldown (dropped, ADR 0012 §8), a version first seen yanked, un-yank, removal and return (ADR 0010 §1). Each could become an additive event type later. Alternatives: Q9 and Q18.

## 6. Versioning

- The spec repository is versioned with SemVer (README). While it is at **0.x**, `dev.angelia.release.*.v1` and `schemas/release/v1.json` are a **draft**: any 0.x minor release may change them in a breaking way, with a changelog entry, and without a new `.v<major>` type. The `v1` suffix names the major version that will be frozen at spec 1.0.0 (Phase 3 exit criterion, prd.md §9), not a stability promise today.
- From spec 1.0.0, the README's rules apply as written: additive changes (a new optional field, a new open-set value) are minor; removals, renames, type changes, new required fields and closed-enum changes need `.v2` and an ADR in the core repository.
- How a consumer sees the draft status: the schema's `title` and `description` say "draft, pre-1.0", the README says it, and `dataschema` may name the spec release (Q11). There is **no** `version` field for the schema inside `data`: `data.version` is the package version, and a second meaning of the same word would confuse every template (Q11).
- Rejected: naming the types `.v0` until the freeze, then renaming them `.v1`. The rename itself would break every consumer at the moment the contract is supposed to become stable.

## 7. Open questions

Each question has options and a recommendation. Q1 to Q4 and Q6 to Q9 block the schema; the others can be decided with it.

**Q1. `ecosystem` (§4) or `source` (code and watch file) for the source kind in `data`?**
§4 says `ecosystem`. The approved watch-file decision D16 chose `source` for the filter key ("instead of the PRD's ecosystem"), and `subscription.Input.Source` follows it. A subscriber writing `filter: {source: [pypi]}` would see a `data.ecosystem` field.
(a) `source`; (b) `ecosystem`, as §4; (c) `source_kind`.
**Recommendation: (a) `source`**, consistent with the filter and the watch file, and accurate for `github-release` and `oci`, which are not ecosystems. Cost: the word also names the CloudEvents `source` attribute, a different thing (a URI); templates must write `.data.source`. If that clash is judged worse, (c). §4 then needs a one-word update.

**Q2. Form of the CloudEvents `source`.**
(a) `angelia://<instance>/watches/<source kind>/<package>` as §4 (readable; but not unique per watch when two watches share a target, and npm scopes and GitLab subgroups need percent-encoding in the path); (b) `angelia://<instance>/watches/<watch_id>`; (c) `angelia://<instance>` only.
**Recommendation: (b)**. The watch is the context that produced the event, the package is already in `subject` and `data`, and a ULID needs no encoding. ADR 0004 lists this as open.

**Q3. Where does `<instance>` come from?**
No instance name exists in the instance configuration today. (a) A new config key (e.g. `instance.name`), default `angelia`; (b) the host name (leaks internal host names into events sent to third parties); (c) a random id generated at first start and stored in the database.
**Recommendation: (a)**, pattern `^[a-z0-9][a-z0-9.-]{0,62}$`. It is a change to the core config format, so it needs its own core issue.

**Q4. `subject`: `<source kind>:<package>@<version>` (§4) or the purl?**
The purl is a standard identity, but it is `null` for some kinds, does not tell `github-release` from `github-tag`, and percent-encodes (`pkg:npm/%40angular/core@...`).
**Recommendation: keep §4's form**, always non-null and readable; `purl` stays in `data`.

**Q5. Extension attributes in v1?**
(a) none; (b) `partitionkey` now, set to the versionless purl or `<source>:<package>`; (c) also `angeliawatch` and `angeliabump` for broker-side filtering.
**Recommendation: (a)**; add `partitionkey` with the NATS, MQTT and Kafka sinks (PRD F8), which is an additive change.

**Q6. Size limit of `notes.body`.**
(a) 4 KiB; (b) 16 KiB; (c) 64 KiB; (d) none. The event row, each delivery and every webhook body carry it. Known downstream limits: Slack messages about 40,000 characters, Discord 2,000 (chat sinks render their own message anyway), NATS default maximum payload 1 MiB, GitHub `repository_dispatch` `client_payload` limited to 10 top-level keys (the sink must nest `data`).
**Recommendation: (b) 16,384 bytes of UTF-8**, cut at a character boundary, `truncated: true`; the full text stays at `urls.changelog` or `urls.release`. Since nothing fills `notes` yet, the limit could also be fixed by the enrichment story (F12) as long as the field and `truncated` exist now.

**Q7. Values of `bump`.**
The code has `major`, `minor`, `patch`, `prerelease`, `other`, and an empty value when there is no previous version. `prerelease` is a change between pre-releases of the same core (`2.0.0-rc.1` to `2.0.0-rc.2`); `other` is an alias of equal precedence (dropped by the policy, so rarely seen), or a version not greater than its previous one, or a comparison across schemes. The subscription filter accepts only `major`, `minor`, `patch`.
(a) closed enum of the five values plus `null`; (b) also add `initial` instead of `null` for a first version; (c) open set.
**Recommendation: (a)**, `null` for "nothing to compare with" (consistent with `previous_version: null`). Whether the filter should also accept `prerelease` is a watch-file question, not a schema one.

**Q8. Closed enums or open sets?**
The README makes any enum change a major change. `source` will grow (`go-proxy`, `maven`, `http-json`, plugins), `scheme` will gain `maven` (Phase 1), `notes.format` may gain values.
**Recommendation:** closed enums only for `bump` and the three event types; `source`, `scheme` and `notes.format` are strings with a pattern and a documented list of known values, and consumers must accept unknown values. Also confirm the kind spelling `go-proxy` (code, architecture.md §3.3, PRD F2) rather than `go`.

**Q9. How does `release.yanked` differ from `release.published`, and when is it emitted?**
Same `data` shape in all proposals. (a) Only for versions **this watch emitted** (recommended in section 5: a subscriber never hears of a yank of a version it was never told about); (b) for every known version that becomes yanked, emitted or not; (c) also emit for versions dropped while held for cooldown.
And its content: the yanked event repeats the emitted event's classification (`previous_version`, `bump`, `backport`, `prerelease`, `cooldown_satisfied_at` set to `null`) with `yanked: true` and `detected_at` = when the yank was seen, read from the stored payload of the earlier event so it matches what the subscriber received.
**Recommendation: (a)**, with no un-yank event in v1 (a `release.unyanked` type can be added later). ADR 0010 leaves this to angelia-dev/angelia#112, which should implement whatever is decided here.

**Q10. Timestamps: which time is `time`, and is `published_at` trusted?**
(a) `time` = emission time (recommended: it is when the event happened in Angelia, and with a cooldown it differs from detection by up to days); (b) `time` = `detected_at`, as the §4 example suggests; (c) `time` = `published_at`.
Also: keep `published_at` exactly as upstream reports it (nullable), and document per kind whether it can be back-dated (section 3), rather than replacing it with a trusted date.
**Recommendation: (a)**, plus the per-kind note. The §4 example's `time` then needs a footnote or a change.

**Q11. How much of the policy decision is in the event, and how is the draft status shown?**
Cooldown: (a) only `cooldown_satisfied_at`, as §4; (b) also `cooldown_started_from` (`published_at` or `detected_at`) so a consumer can audit which basis was used; (c) a `policy` object with the cooldown, constraint and prerelease mode in force.
**Recommendation: (a) for v1**: the basis rule (ADR 0012 §6) is still pending, and (b) can be added later as an optional field.
Draft status: (a) only in the schema's title, description and the README; (b) `dataschema` points at a tagged, versioned URL (`.../v0.1.0/schemas/release/v1.json`); (c) an extension attribute `angeliaspec` = `0.1.0`.
**Recommendation: (a) plus (b)** once the repository has release tags. Confirm also the `$id` / `dataschema` host: `https://github.com/angelia-dev/spec/...` (the placeholder's convention, not resolvable as JSON) or a domain the project owns.

**Q12. Add `normalized_version` and `backport`, which §4 lacks?**
Both exist in `policy.Release` and are computed for every emitted version. `backport` is how a consumer tells `1.9.4` after `2.0.0` from a new latest version (the main reason for "every new version", PRD G2). `normalized_version` saves consumers from reimplementing PEP 440 normalisation.
**Recommendation: add both**, as required fields. The alternative is to leave them out of v1 and add them as optional fields later (minor).

**Q13. `urls` keys versus the code.**
The code has `URL` and `NotesURL`; §4 has `release`, `changelog`, `artifact`. (a) Keep §4's keys, map `NotesURL` to `changelog`; (b) rename to `release`, `notes`, `artifact`; (c) drop `artifact` until a source sets it in a typed field.
**Recommendation: (a)**, keep `artifact` nullable so the shape does not change when a source starts setting it.

**Q14. Watch id format.**
§4 shows `w_123`; the store uses bare ULIDs. (a) bare ULID, as stored; (b) a `w_` prefix in the public contract only.
**Recommendation: (a)**, so ids in events, the API and logs are the same string.

**Q15. Shape of `labels`.**
(a) object of string to string, as the watch file and the filter; (b) array of `{key, value}` (friendlier to some SQL and BI tools); (c) array of `key=value` strings.
**Recommendation: (a)**, `{}` when empty, never `null`; limits as in the watch file.

**Q16. `purl` when it cannot be built exactly.**
OCI without a known digest, GitLab watched by numeric project id, plugins. (a) `null`; (b) a best-effort purl (OCI without version and with the tag qualifier; GitLab with the numeric id as name); (c) `pkg:generic/...`.
**Recommendation: (a) `null`** for plugins and the generic HTTP kinds; for OCI, (b) a versionless purl with the `tag` qualifier until the source reports digests, since a consumer joining with SBOMs still gets the image; for GitLab, the source should report the path.

**Q17. Repeat the short type in `data`?**
`subscription.Input.Type` is the short type. (a) No, derive it from the envelope `type`; (b) add `data.type`.
**Recommendation: (a)**: one source of truth, and the mapping is mechanical.

**Q18. One data schema for the three types, and its path.**
The issue says `schemas/release/v1.json` for all three; the README's convention is one schema per type at `schemas/<type>/v<major>.json`.
**Recommendation:** one shared schema at `schemas/release/v1.json` (the payloads are identical), with `if`/`then` rules per type in the docs only (the schema validates `data` alone, which does not carry the type); examples under `examples/valid/release/v1/`. The README's layout section gets one sentence for this case.

## 8. Conflicts with the current documents and code

These are flagged, not resolved; each maps to a question above.

| Document or code | Says | Conflict | Question |
| --- | --- | --- | --- |
| architecture.md §4 | `data.ecosystem` | watch-file D16 and `subscription.Input` say `source` | Q1 |
| architecture.md §4 | `source` = `angelia://my-instance/watches/pypi/requests` | not unique per watch; no instance name exists in the config | Q2, Q3 |
| architecture.md §4 | `time` equals `detected_at` | with a cooldown, emission is later than detection | Q10 |
| architecture.md §4 | `watch.id` = `w_123` | store ids are bare ULIDs | Q14 |
| architecture.md §4 | `notes` with a body | no source fetches notes (PRD F12, Phase 2) | Q6 |
| architecture.md §4 | `urls.changelog`, `urls.artifact` | code has `NotesURL`, and no typed artifact URL | Q13 |
| architecture.md §4 | no `backport`, no normalised version | `policy.Release` has both | Q12 |
| `internal/subscription` | `Input.Bump` is `""` when unclassified | the schema proposes `null` | Q7 |
| spec README | changing an enum is breaking | `source` and `scheme` must grow | Q8 |
| task wording | ecosystem `go` | kind is `go-proxy` in code, architecture.md and PRD | Q8 |
| spec README | `schemas/<type>/v<major>.json` per type | the issue asks for one `schemas/release/v1.json` | Q18 |

## 9. Next steps after approval

1. Update this proposal with the answers (status: Accepted).
2. Write `schemas/release/v1.json` and examples for pypi, npm, github-release, a yanked and a pre-release event, plus invalid examples (missing required field, wrong type, bad `bump`), validated by CI.
3. Write the per-field docs page and the open-questions list in the README, as the issue's acceptance criteria require.
4. File core issues for what the answers change outside this repository: architecture.md §4, the instance name config key (Q3), and the emission rules for #106 and #112.

## 10. Amendments after acceptance

Review of the schemas on angelia-dev/spec#2 (2026-11-01) changed the following. Open objects were confirmed by the maintainer (2026-11-01); the purl items are pending confirmation.

- **Open objects.** The `data` object and its nested `urls`, `notes` and `watch` objects accept unknown properties, and the envelope accepts CloudEvents extension attributes (names matching `^[a-z0-9]{1,20}$`; other unknown names stay rejected). Producers still emit only the documented fields and, as Q5 decided, no extension attributes in v1; consumers must ignore unknown fields and extension attributes. This keeps a new optional field a minor change, as section 6 says, instead of breaking every consumer that validates strictly. The alternative, closed objects (`additionalProperties: false`), was the first draft of the schemas.
- **`purl` row of section 3.** Q16's answer supersedes the row's first wording: an OCI image without a known digest gets a versionless purl with a `tag` qualifier, not `null`.
- **PyPI purl.** Follows the purl `pypi` type text exactly: lower-case and replace `_` with `-`, without PEP 503's `.` folding (`zope.interface` gives `pkg:pypi/zope.interface`), so the purl matches what SBOM tools produce. The name comes from the project name as PyPI reports it, because `data.package` is PEP 503-normalised.
- **Go purl.** Keeps the module path's case, a documented deviation from the purl `golang` type text, because Go module paths are case-sensitive.
