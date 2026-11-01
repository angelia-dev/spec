#!/usr/bin/env bash
# Validates every example against the schema selected by its path.
#
# Path convention:
#   examples/valid/<type>/v<major>/<name>.json   must pass
#   examples/invalid/<type>/v<major>/<name>.json must fail
#   maps to schemas/<type>/v<major>.json
#
# Fails if a valid example fails, an invalid example passes, an example has
# no matching schema, or no examples were found at all.
set -euo pipefail

cd "$(dirname "$0")/.."

CHECK="${CHECK_JSONSCHEMA:-check-jsonschema}"
if ! command -v "$CHECK" >/dev/null 2>&1; then
  echo "error: $CHECK not found; install it with: pip install check-jsonschema==0.38.2" >&2
  exit 2
fi

failures=0
checked=0
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# 1. Every schema must itself be a valid JSON Schema.
while IFS= read -r -d '' schema; do
  if ! "$CHECK" --check-metaschema "$schema" >/dev/null 2>&1; then
    echo "FAIL metaschema: $schema is not a valid JSON Schema"
    "$CHECK" --check-metaschema "$schema" || true
    failures=$((failures + 1))
  fi
done < <(find schemas -type f -name '*.json' -print0)

# 2. Examples must match their schema (valid passes, invalid fails).
check_group() {
  local group="$1" expect="$2" # expect: pass | fail
  local root="examples/$group"
  local found=0
  while IFS= read -r -d '' example; do
    found=$((found + 1))
    local rel="${example#"$root"/}"          # <type>/v<major>/<name>.json
    local dir rel_schema schema
    dir="$(dirname "$rel")"                  # <type>/v<major>
    if [[ "$dir" == "." || "$(basename "$dir")" != v[0-9]* ]]; then
      echo "FAIL layout: $example must be $root/<type>/v<major>/<name>.json"
      failures=$((failures + 1))
      continue
    fi
    schema="schemas/${dir}.json"
    if [[ ! -f "$schema" ]]; then
      echo "FAIL schema: no schema $schema for $example"
      failures=$((failures + 1))
      continue
    fi
    checked=$((checked + 1))
    if "$CHECK" --schemafile "$schema" "$example" >"$log" 2>&1; then
      result=pass
    else
      result=fail
    fi
    if [[ "$result" == "$expect" ]]; then
      echo "ok   [$group expects $expect] $example"
    else
      echo "FAIL [$group expects $expect, got $result] $example against $schema"
      cat "$log"
      failures=$((failures + 1))
    fi
  done < <(find "$root" -type f -name '*.json' -print0)
  if [[ "$found" -eq 0 ]]; then
    echo "FAIL: no examples found under $root"
    failures=$((failures + 1))
  fi
}

check_group valid pass
check_group invalid fail

echo
if [[ "$failures" -gt 0 ]]; then
  echo "validate-examples: $failures failure(s) across $checked example(s)"
  exit 1
fi
echo "validate-examples: all $checked example(s) behaved as expected"
