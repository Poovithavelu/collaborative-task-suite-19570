#!/usr/bin/env bash
set -euo pipefail

# Simple idempotent migration runner for local dev
# Usage: ./migrate.sh
# It will:
#  1) detect connection URL via env (POSTGRES_URL or POSTGRES_USER/PASS/DB/PORT) or db_connection.txt
#  2) apply schema/*.sql in sorted order
#  3) keep a migrations table to avoid reapplying the same files

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="${ROOT_DIR}/schema"

# Resolve connection string
POSTGRES_URL="${POSTGRES_URL:-}"
if [[ -z "${POSTGRES_URL}" ]]; then
  # Try db_visualizer/postgres.env
  if [[ -f "${ROOT_DIR}/db_visualizer/postgres.env" ]]; then
    # shellcheck disable=SC1090
    source "${ROOT_DIR}/db_visualizer/postgres.env"
  fi
fi

if [[ -z "${POSTGRES_URL:-}" ]]; then
  # Build from individual vars if available
  HOST="localhost"
  PORT="${POSTGRES_PORT:-5000}"
  USER="${POSTGRES_USER:-appuser}"
  PASS="${POSTGRES_PASSWORD:-dbuser123}"
  DB="${POSTGRES_DB:-myapp}"
  POSTGRES_URL="postgresql://${USER}:${PASS}@${HOST}:${PORT}/${DB}"
fi

# Allow override by db_connection.txt if present
if [[ -f "${ROOT_DIR}/db_connection.txt" ]]; then
  TXT_URL="$(cat "${ROOT_DIR}/db_connection.txt" | tr -d '\n' | tr -d '\r')"
  if [[ "${TXT_URL}" == psql* ]]; then
    TXT_URL="${TXT_URL#psql }"
  fi
  POSTGRES_URL="${TXT_URL}"
fi

echo "Using database URL: ${POSTGRES_URL}"

# Ensure schema dir exists
if [[ ! -d "${SCHEMA_DIR}" ]]; then
  echo "Schema directory not found: ${SCHEMA_DIR}"
  exit 1
fi

# Create migrations table if not exists
psql "${POSTGRES_URL}" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  id serial PRIMARY KEY,
  filename text UNIQUE NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);
SQL

# Apply migrations in order
APPLIED=0
for file in $(ls -1 "${SCHEMA_DIR}"/*.sql | sort); do
  FNAME="$(basename "$file")"
  EXISTS=$(psql "${POSTGRES_URL}" -tAc "SELECT 1 FROM public.schema_migrations WHERE filename='${FNAME}'" || true)
  if [[ "${EXISTS}" != "1" ]]; then
    echo "Applying migration: ${FNAME}"
    psql "${POSTGRES_URL}" -v ON_ERROR_STOP=1 -f "${file}"
    psql "${POSTGRES_URL}" -v ON_ERROR_STOP=1 -c "INSERT INTO public.schema_migrations (filename) VALUES ('${FNAME}');"
    APPLIED=$((APPLIED+1))
  else
    echo "Skipping already applied: ${FNAME}"
  fi
done

echo "Migrations complete. Applied ${APPLIED} new migration(s)."
