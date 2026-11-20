#!/bin/sh
# Thin wrapper around golang-migrate, used by the docker-compose `migrate` service.
# Usage (via make): make migrate-up | make migrate-down | make migrate-version
set -e

: "${DATABASE_URL:?DATABASE_URL is not set}"

exec migrate -path=/migrations -database "$DATABASE_URL" "$@"
