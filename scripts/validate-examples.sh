#!/usr/bin/env bash
# Validates every example against the schema selected by its path.
#
# Path convention:
#   examples/valid/<type>/v<major>/<name>.json   must validate
#   examples/invalid/<type>/v<major>/<name>.json must fail schema validation
#   maps to schemas/<type>/v<major>.json
#   (<type> may have several segments, e.g. release/envelope)
#
# Fails if:
#   - a valid example fails, or an invalid example passes;
#   - an invalid example fails for the wrong reason (malformed JSON,
#     unresolvable $ref, unexpected tool error): only the schema-validation
#     error message counts as a correct failure;
#   - an example is not parseable JSON, or is not a .json file;
#   - an example has no matching schema, or a schema is not valid JSON Schema;
#   - no examples were found at all;
#   - webhooks/v1/vectors.json does not validate against
#     schemas/webhooks/v1.json, or a signature or expected result in it does
#     not recompute (scripts/check-webhook-vectors.py).
set -euo pipefail

cd "$(dirname "$0")/.."

CHECK="${CHECK_JSONSCHEMA:-check-jsonschema}"
if ! command -v "$CHECK" >/dev/null 2>&1; then
  echo "error: $CHECK not found; install it with: pip install check-jsonschema==0.38.2" >&2
  exit 2
fi

# Message printed by check-jsonschema 0.38.2 when an instance violates its schema.
VALIDATION_ERROR="Schema validation errors were encountered."

failures=0
checked=0
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

fail() {
  echo "FAIL $*"
  failures=$((failures + 1))
}

# 1. Examples must be .json files only.
while IFS= read -r -d '' other; do
  fail "non-JSON file under examples/: $other"
done < <(find examples -type f ! -name '*.json' -print0)

# 2. Every schema must itself be a valid JSON Schema.
while IFS= read -r -d '' schema; do
  if ! "$CHECK" --check-metaschema "$schema" >"$log" 2>&1; then
    fail "metaschema: $schema is not a valid JSON Schema"
    cat "$log"
  fi
done < <(find schemas -type f -name '*.json' -print0)

# 3. Examples must match their schema: valid passes, invalid fails with a
#    schema-validation error (and nothing else).
check_group() {
  local group="$1" expect="$2" # expect: pass | fail
  local root="examples/$group"
  local found=0
  while IFS= read -r -d '' example; do
    found=$((found + 1))
    local rel="${example#"$root"/}"          # <type>/v<major>/<name>.json
    local dir
    dir="$(dirname "$rel")"                  # <type>/v<major>
    if [[ "$dir" == "." || "$(basename "$dir")" != v[0-9]* ]]; then
      fail "layout: $example must be $root/<type>/v<major>/<name>.json"
      continue
    fi
    local schema="schemas/${dir}.json"
    if [[ ! -f "$schema" ]]; then
      fail "schema: no schema $schema for $example"
      continue
    fi
    if ! python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$example" 2>"$log"; then
      fail "parse: $example is not valid JSON"
      cat "$log"
      continue
    fi
    checked=$((checked + 1))
    local result=pass
    # --base-uri makes relative $refs (for example the envelope's "../v1.json")
    # resolve to the schema files in this checkout instead of fetching the
    # $id URLs, which are identifiers and not promised to be fetchable.
    if ! "$CHECK" --base-uri "file://$PWD/$schema" --schemafile "$schema" "$example" >"$log" 2>&1; then
      result=fail
    fi
    if [[ "$result" != "$expect" ]]; then
      fail "[$group expects $expect, got $result] $example against $schema"
      cat "$log"
    elif [[ "$expect" == fail ]] && ! grep -qF "$VALIDATION_ERROR" "$log"; then
      fail "[$group] $example failed for the wrong reason (no schema-validation error)"
      cat "$log"
    else
      echo "ok   [$group expects $expect] $example"
    fi
  done < <(find "$root" -type f -name '*.json' -print0)
  if [[ "$found" -eq 0 ]]; then
    fail "no examples found under $root"
  fi
}

check_group valid pass
check_group invalid fail

# 4. The webhook test vectors must match their schema and recompute.
vectors=webhooks/v1/vectors.json
if [[ ! -f "$vectors" ]]; then
  fail "missing $vectors"
elif ! "$CHECK" --base-uri "file://$PWD/schemas/webhooks/v1.json" --schemafile schemas/webhooks/v1.json "$vectors" >"$log" 2>&1; then
  fail "[webhooks] $vectors does not validate against schemas/webhooks/v1.json"
  cat "$log"
elif ! python3 scripts/check-webhook-vectors.py "$vectors" >"$log" 2>&1; then
  fail "[webhooks] $vectors does not recompute"
  cat "$log"
else
  checked=$((checked + 1))
  echo "ok   [webhooks] $vectors; $(cat "$log")"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "validate-examples: $failures failure(s) across $checked example(s)"
  exit 1
fi
echo "validate-examples: all $checked example(s) behaved as expected"
