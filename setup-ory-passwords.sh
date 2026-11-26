#!/usr/bin/env bash
set -euo pipefail

umask 077

tmp="$(mktemp "${TMPDIR:-/tmp}/ory-secret-XXXXXX.env")"

trap 'rm -f "$tmp"' EXIT

{
  printf 'KRATOS_PASSWORD=%s\n' "$(openssl rand -hex 32)"
  printf 'HYDRA_PASSWORD=%s\n' "$(openssl rand -hex 32)"
  printf 'KETO_PASSWORD=%s\n' "$(openssl rand -hex 32)"
} > "$tmp"

bash ./sops-secret.sh \
  --name ory-credentials \
  --namespace flux-system \
  --env-file "$tmp"