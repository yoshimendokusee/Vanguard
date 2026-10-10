#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

if [ ! -f .env ]; then
  (umask 077 && cp .env.example .env)
  printf 'Created %s/.env from .env.example (permissions 600).\n' "$repo_dir"
fi

if docker compose version >/dev/null 2>&1; then
  docker compose up -d --build "$@"
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose up -d --build "$@"
else
  printf 'Docker Compose v2 is required (docker compose or docker-compose).\n' >&2
  exit 1
fi
vite_port=$(sed -n 's/^VITE_PORT=//p' .env | tail -n 1 | tr -d '\"' | tr -d "'")
[ -n "$vite_port" ] || vite_port=3301
printf '\nWristCue dashboard: http://localhost:%s/\n' "$vite_port"
