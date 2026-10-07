#!/usr/bin/env bash
# set-secrets.sh — copy named values from Supabase/.env into one Railway timed-job service, printing NO value.
#   bash services/timed-jobs/set-secrets.sh <service> KEY [KEY...]
# Run by a person (the Claude sessions do not enter secrets). Values travel on stdin, never on the command line.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; envfile="$here/../../.env"
project=$(node -p "require('$here/services.json').projectId"); envname=$(node -p "require('$here/services.json').environment")
svc="$1"; shift
for k in "$@"; do
  v=$(grep -m1 "^$k=" "$envfile" | cut -d= -f2- | tr -d '\r') || true
  [ -n "$v" ] || { echo "$k: not found in .env, skipped"; continue; }
  printf '%s' "$v" | railway variable set "$k" --stdin --service "$svc" --environment "$envname" --project "$project" --skip-deploys >/dev/null
  echo "$k: set on $svc"
done
