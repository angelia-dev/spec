#!/usr/bin/env bash
# Generate Go server stubs from openapi/angelia.v1.yaml with oapi-codegen (the
# generator named in the core repository's architecture.md §6) and compile them
# in a throwaway module. Nothing is written to the repository: committing the
# stubs is the core repository's job.
#
# Requires Go 1.25 or later. Every module version is pinned.
set -euo pipefail

OAPI_CODEGEN="github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.8.2"
DEPS=(
  "github.com/go-chi/chi/v5@v5.5.0"
  "github.com/oapi-codegen/runtime@v1.8.0"
  "github.com/getkin/kin-openapi@v0.152.0"
)

root="$(cd "$(dirname "$0")/.." && pwd)"
spec="$root/openapi/angelia.v1.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"$work/oapi-codegen.yaml" <<'EOF'
package: api
output: api/api.gen.go
generate:
  models: true
  chi-server: true
  strict-server: true
  embedded-spec: true
EOF

cd "$work"
mkdir api
go mod init example.com/stubcheck >/dev/null 2>&1
go run "$OAPI_CODEGEN" -config oapi-codegen.yaml "$spec"
go get "${DEPS[@]}" >/dev/null 2>&1
go mod tidy
CGO_ENABLED=0 go build ./...
go vet ./...
echo "check-go-stubs: generated $(grep -c '^func ' api/api.gen.go) functions; build and vet ok"
