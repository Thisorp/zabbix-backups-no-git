#!/usr/bin/env bash

backup_etc() {
  ETC_BACKUP_FILE=""
  ETC_STATUS="skipped"

  if [[ "${ENABLE_ETC_BACKUP:-true}" != "true" ]]; then
    ETC_STATUS="disabled"
    return
  fi

  [[ -d "${ZABBIX_ETC_PATH}" ]] || die "ZABBIX_ETC_PATH not found: ${ZABBIX_ETC_PATH}"

  mkdir -p "${BACKUP_BASE}/etc"

  local outfile="${BACKUP_BASE}/etc/zabbix_etc_${DATE}.tar.gz"
  local tmp_list
  tmp_list="$(mktemp)"

  echo "${ZABBIX_ETC_PATH}" > "$tmp_list"

  for p in ${EXTRA_ETC_PATHS:-}; do
    [[ -e "$p" ]] && echo "$p" >> "$tmp_list"
  done

  log "INFO" "Backup /etc zabbix: $outfile"

  tar -czf "$outfile" -T "$tmp_list"
  rm -f "$tmp_list"

  [[ -s "$outfile" ]] || die "ETC backup failed or empty"

  ETC_BACKUP_FILE="$outfile"
  ETC_STATUS="success"

  ln -sfn "$ETC_BACKUP_FILE" "${BACKUP_BASE}/etc/latest"

  log "INFO" "ETC backup done: $ETC_BACKUP_FILE"
}
