#!/usr/bin/env bash
set -Eeuo pipefail

debug_error() {
  local exit_code=$?
  echo "[ERROR] Exit code: ${exit_code}" >&2
  echo "[ERROR] File: ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" >&2
  echo "[ERROR] Line: ${BASH_LINENO[0]:-${LINENO}}" >&2
  echo "[ERROR] Command: ${BASH_COMMAND}" >&2
  exit "$exit_code"
}

trap debug_error ERR

ENV_FILE="${ENV_FILE:-/opt/zabbix-config-backup/conf/backup.env}"

[[ -f "$ENV_FILE" ]] || {
  echo "[ERROR] ENV file not found: $ENV_FILE" >&2
  exit 1
}

# shellcheck disable=SC1090
source "$ENV_FILE"

export TZ="${TZ:-Asia/Bangkok}"

DATE="$(date +'%F_%H%M%S')"

PROJECT_DIR="${PROJECT_DIR:-/opt/zabbix-config-backup}"
BACKUP_BASE="${BACKUP_BASE:-${PROJECT_DIR}/storage}"

LOG_FILE="${LOG_FILE:-/var/log/zabbix-config-backup.log}"

mkdir -p "${BACKUP_BASE}/db" "${BACKUP_BASE}/etc" "${BACKUP_BASE}/exports" "${PROJECT_DIR}/manifests"

log() {
  local level="$1"; shift
  echo "[$(date '+%F %T')] [$level] $*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR" "$*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

check_dependencies() {
  require_cmd tar
  require_cmd gzip
  require_cmd jq
  require_cmd curl

  if [[ "${ENABLE_DB_BACKUP:-true}" == "true" ]]; then
    case "${DB_TYPE}" in
      postgresql)
        require_cmd pg_dump
        require_cmd psql
        ;;
      mysql|mariadb)
        require_cmd mysqldump
        require_cmd mysql
        ;;
      *)
        die "Unsupported DB_TYPE=${DB_TYPE}"
        ;;
    esac
  fi
}

get_zabbix_version() {
  if command -v zabbix_server >/dev/null 2>&1; then
    zabbix_server -V 2>/dev/null | head -n 1 || true
  else
    echo "zabbix_server command not found"
  fi
}

get_db_version() {
  case "${DB_TYPE}" in
    postgresql)
      PGPASSWORD="${DB_PASS}" psql \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d "${DB_NAME}" \
        -Atc "select version();" 2>/dev/null || echo "unknown"
      ;;
    mysql|mariadb)
      MYSQL_PWD="${DB_PASS}" mysql \
        -h "${DB_HOST}" \
        -P "${DB_PORT}" \
        -u "${DB_USER}" \
        -Nse "select version();" 2>/dev/null || echo "unknown"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

write_manifest() {
  local manifest="${PROJECT_DIR}/manifests/backup_manifest.json"
  local zabbix_version
  local db_version

  zabbix_version="$(get_zabbix_version)"
  db_version="$(get_db_version)"

  cat > "$manifest" <<EOF_MANIFEST
{
  "backup_time": "${DATE}",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "zabbix_version": "${zabbix_version}",
  "db_type": "${DB_TYPE}",
  "db_version": "${db_version}",
  "db_host": "${DB_HOST}",
  "db_port": "${DB_PORT}",
  "db_name": "${DB_NAME}",
  "db_backup_mode": "${DB_BACKUP_MODE}",
  "db_status": "${DB_STATUS:-unknown}",
  "db_backup_file": "${DB_BACKUP_FILE:-}",
  "etc_status": "${ETC_STATUS:-unknown}",
  "etc_backup_file": "${ETC_BACKUP_FILE:-}",
  "api_export_status": "${EXPORT_STATUS:-unknown}",
  "api_export_dir": "${EXPORT_DIR:-}"
}
EOF_MANIFEST

  log "INFO" "Manifest written: $manifest"
}

cleanup_retention() {
  local days="${RETENTION_DAYS:-30}"

  log "INFO" "Cleanup retention older than ${days} days"

  find "${BACKUP_BASE}/db" -type f \( -name "*.dump" -o -name "*.sql.gz" \) -mtime +"$days" -delete || true
  find "${BACKUP_BASE}/etc" -type f -name "*.tar.gz" -mtime +"$days" -delete || true
  find "${BACKUP_BASE}/exports" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" -exec rm -rf {} + 2>/dev/null || true
}

# shellcheck disable=SC1091
source "${PROJECT_DIR}/scripts/backup_db.sh"
# shellcheck disable=SC1091
source "${PROJECT_DIR}/scripts/backup_etc.sh"
# shellcheck disable=SC1091
source "${PROJECT_DIR}/scripts/export_api.sh"

main() {
  log "INFO" "========== START ZABBIX CONFIG BACKUP ${DATE} =========="

  check_dependencies

  backup_db
  backup_etc
  export_api

  write_manifest
  cleanup_retention

  log "INFO" "========== BACKUP DONE ${DATE} =========="
}

main "$@"
