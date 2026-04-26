#!/usr/bin/env bash
set -Eeuo pipefail

read_exclude_tables() {
  local file="${EXCLUDE_TABLES_FILE:-}"
  [[ -f "$file" ]] || return 0

  grep -vE '^\s*#|^\s*$' "$file" | sed 's/[[:space:]]//g'
}

backup_db_mysql() {
  local outfile="${BACKUP_BASE}/db/zabbix_${DB_TYPE}_${DB_BACKUP_MODE}_${DATE}.sql.gz"
  local tmp_sql
  local -a ignore_args=()
  local -a excluded_tables=()
  local tbl

  tmp_sql="$(mktemp)"

  if [[ "${DB_BACKUP_MODE}" == "config_only" ]]; then
    while IFS= read -r tbl; do
      [[ -z "$tbl" ]] && continue
      excluded_tables+=("$tbl")
      ignore_args+=(--ignore-table="${DB_NAME}.${tbl}")
    done < <(read_exclude_tables)
  fi

  log "INFO" "Backup MySQL/MariaDB DB: ${DB_HOST}:${DB_PORT}/${DB_NAME}"

  if [[ "${#excluded_tables[@]}" -gt 0 ]]; then
    MYSQL_PWD="${DB_PASS}" mysqldump \
      -h "${DB_HOST}" \
      -P "${DB_PORT}" \
      -u "${DB_USER}" \
      --no-data \
      --skip-triggers \
      "${DB_NAME}" \
      "${excluded_tables[@]}" >> "$tmp_sql"
  fi

  MYSQL_PWD="${DB_PASS}" mysqldump \
    -h "${DB_HOST}" \
    -P "${DB_PORT}" \
    -u "${DB_USER}" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --hex-blob \
    --set-gtid-purged=OFF \
    "${ignore_args[@]}" \
    "${DB_NAME}" >> "$tmp_sql"

  gzip -c "$tmp_sql" > "$outfile"
  rm -f "$tmp_sql"

  DB_BACKUP_FILE="$outfile"
}

backup_db_postgresql() {
  local outfile
  local -a exclude_args=()
  local tbl

  if [[ "${DB_BACKUP_MODE}" == "config_only" ]]; then
    while IFS= read -r tbl; do
      [[ -z "$tbl" ]] && continue
      exclude_args+=(--exclude-table-data="$tbl")
    done < <(read_exclude_tables)
  fi

  if [[ "${PG_DUMP_FORMAT:-custom}" == "custom" ]]; then
    outfile="${BACKUP_BASE}/db/zabbix_${DB_TYPE}_${DB_BACKUP_MODE}_${DATE}.dump"
  else
    outfile="${BACKUP_BASE}/db/zabbix_${DB_TYPE}_${DB_BACKUP_MODE}_${DATE}.sql.gz"
  fi

  log "INFO" "Backup PostgreSQL DB: ${DB_HOST}:${DB_PORT}/${DB_NAME}"

  export PGPASSWORD="${DB_PASS}"

  if [[ "${PG_DUMP_FORMAT:-custom}" == "custom" ]]; then
    pg_dump \
      -h "${DB_HOST}" \
      -p "${DB_PORT}" \
      -U "${DB_USER}" \
      -d "${DB_NAME}" \
      -Fc \
      --no-owner \
      --no-privileges \
      "${exclude_args[@]}" \
      -f "$outfile"
  else
    pg_dump \
      -h "${DB_HOST}" \
      -p "${DB_PORT}" \
      -U "${DB_USER}" \
      -d "${DB_NAME}" \
      --no-owner \
      --no-privileges \
      "${exclude_args[@]}" | gzip > "$outfile"
  fi

  unset PGPASSWORD

  DB_BACKUP_FILE="$outfile"
}

backup_db() {
  DB_BACKUP_FILE=""
  DB_STATUS="skipped"

  if [[ "${ENABLE_DB_BACKUP}" != "true" ]]; then
    DB_STATUS="disabled"
    return
  fi

  mkdir -p "${BACKUP_BASE}/db"

  case "${DB_TYPE}" in
    postgresql)
      backup_db_postgresql
      ;;
    mysql|mariadb)
      backup_db_mysql
      ;;
    *)
      die "Unsupported DB_TYPE=${DB_TYPE}"
      ;;
  esac

  [[ -s "$DB_BACKUP_FILE" ]] || die "DB backup failed or empty"

  ln -sfn "$DB_BACKUP_FILE" "${BACKUP_BASE}/db/latest"

  DB_STATUS="success"
  log "INFO" "DB backup done: $DB_BACKUP_FILE"
}
