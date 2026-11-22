#!/usr/bin/env bash
# Apply the SQL migrations in sql/migrations/ in order, each once (bookkeeping: meta.schema_migration).
#   PGHOST=… PGPORT=… PGUSER=… PGPASSWORD=… PGDATABASE=neo_model sql/migrate.sh
# The database must exist and have the extensions timescaledb and btree_gist (created by a superuser, see docs/OPERATIONS.md).
# A file that changed after it was applied is reported and not re-applied: write a new migration instead.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)/migrations"
P=(psql -XAtq -v ON_ERROR_STOP=1)
"${P[@]}" -c "CREATE SCHEMA IF NOT EXISTS meta; CREATE TABLE IF NOT EXISTS meta.schema_migration (version text PRIMARY KEY,
             applied_at timestamptz NOT NULL DEFAULT now(), checksum text NOT NULL)"
for f in "$DIR"/[0-9][0-9][0-9]_*.sql; do
  v=$(basename "$f" .sql); sum=$(sha256sum "$f" | cut -d' ' -f1)
  have=$("${P[@]}" -c "SELECT checksum FROM meta.schema_migration WHERE version = '$v'")
  if [[ -n $have ]]; then
    [[ $have != "$sum" ]] && echo "WARNING: $v changed after it was applied (not re-applied)"
    continue
  fi
  echo "applying $v"
  "${P[@]}" --single-transaction -f "$f" -c "INSERT INTO meta.schema_migration (version, checksum) VALUES ('$v', '$sum')" >/dev/null
done
echo "schema up to date: $("${P[@]}" -c "SELECT string_agg(version, ' ' ORDER BY version) FROM meta.schema_migration")"
