#!/usr/bin/env bash
set -e

#
chmod +x ./sops-secret.sh

umask 077

tmp="$(mktemp ./secret-XXXXXX.env)"

trap 'rm -f "$tmp"' EXIT

{
  printf 'KRATOS_PASSWORD=%s\n' "$(openssl rand -hex 32)"
  printf 'HYDRA_PASSWORD=%s\n' "$(openssl rand -hex 32)"
  printf 'KETO_PASSWORD=%s\n' "$(openssl rand -hex 32)"
} > "$tmp"

./sops-secret.sh \
  --name ory-credentials \
  --namespace flux-system \
  --env-file "$tmp"