#!/usr/bin/env bash

api_call() {
  local payload="$1"
  local response

  response="$(
    "${CURL_BIN:-curl}" -sS \
      -H "Content-Type: application/json-rpc" \
      -H "Authorization: Bearer ${ZBX_TOKEN}" \
      -X POST \
      -d "$payload" \
      "${ZBX_URL%/}/api_jsonrpc.php"
  )"

  if ! echo "$response" | "${JQ_BIN:-jq}" . >/dev/null 2>&1; then
    echo "$response" >&2
    die "Zabbix API returned non-JSON response"
  fi

  if echo "$response" | "${JQ_BIN:-jq}" -e '.error' >/dev/null 2>&1; then
    echo "$response" | "${JQ_BIN:-jq}" -c '.error' >&2
    die "Zabbix API error"
  fi

  echo "$response"
}

export_object_group() {
  local get_method="$1"
  local id_field="$2"
  local option_key="$3"
  local output_file="$4"

  local ids_json
  ids_json="$(
    api_call "{
      \"jsonrpc\":\"2.0\",
      \"method\":\"${get_method}\",
      \"params\":{\"output\":[\"${id_field}\",\"name\"]},
      \"id\":1
    }" | "${JQ_BIN:-jq}" "[.result[].${id_field}] | map(tonumber)"
  )"

  if [[ "$ids_json" == "[]" || -z "$ids_json" ]]; then
    log "WARN" "No objects found for ${option_key}"
    return
  fi

  api_call "{
    \"jsonrpc\":\"2.0\",
    \"method\":\"configuration.export\",
    \"params\":{
      \"format\":\"${EXPORT_FORMAT:-json}\",
      \"options\":{\"${option_key}\":${ids_json}}
    },
    \"id\":2
  }" | "${JQ_BIN:-jq}" -r '.result' > "${EXPORT_DIR}/${output_file}"

  if [[ "${EXPORT_FORMAT:-json}" == "json" ]]; then
    "${JQ_BIN:-jq}" . "${EXPORT_DIR}/${output_file}" > "${EXPORT_DIR}/${output_file}.tmp" \
      && mv "${EXPORT_DIR}/${output_file}.tmp" "${EXPORT_DIR}/${output_file}"
  fi

  log "INFO" "Exported ${option_key}: ${EXPORT_DIR}/${output_file}"
}

export_hosts() {
  local ids_json

  ids_json="$(
    api_call "{
      \"jsonrpc\":\"2.0\",
      \"method\":\"host.get\",
      \"params\":{\"output\":[\"hostid\",\"host\"]},
      \"id\":3
    }" | "${JQ_BIN:-jq}" '[.result[].hostid] | map(tonumber)'
  )"

  if [[ "$ids_json" == "[]" || -z "$ids_json" ]]; then
    log "WARN" "No hosts found"
    return
  fi

  api_call "{
    \"jsonrpc\":\"2.0\",
    \"method\":\"configuration.export\",
    \"params\":{
      \"format\":\"${EXPORT_FORMAT:-json}\",
      \"options\":{\"hosts\":${ids_json}}
    },
    \"id\":4
  }" | "${JQ_BIN:-jq}" -r '.result' > "${EXPORT_DIR}/hosts.${EXPORT_FORMAT:-json}"

  if [[ "${EXPORT_FORMAT:-json}" == "json" ]]; then
    "${JQ_BIN:-jq}" . "${EXPORT_DIR}/hosts.${EXPORT_FORMAT:-json}" > "${EXPORT_DIR}/hosts.${EXPORT_FORMAT:-json}.tmp" \
      && mv "${EXPORT_DIR}/hosts.${EXPORT_FORMAT:-json}.tmp" "${EXPORT_DIR}/hosts.${EXPORT_FORMAT:-json}"
  fi

  log "INFO" "Exported hosts: ${EXPORT_DIR}/hosts.${EXPORT_FORMAT:-json}"
}

export_api() {
  EXPORT_STATUS="skipped"

  if [[ "${ENABLE_API_EXPORT:-true}" != "true" ]]; then
    EXPORT_STATUS="disabled"
    return
  fi

  [[ -n "${ZBX_URL:-}" ]] || die "ZBX_URL is empty"
  [[ -n "${ZBX_TOKEN:-}" ]] || die "ZBX_TOKEN is empty"

  EXPORT_DIR="${BACKUP_BASE}/exports/${DATE}"
  mkdir -p "$EXPORT_DIR"

  log "INFO" "Testing Zabbix API..."

  "${CURL_BIN:-curl}" -sS \
    -H "Content-Type: application/json-rpc" \
    -X POST \
    -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":100}' \
    "${ZBX_URL%/}/api_jsonrpc.php" \
    | "${JQ_BIN:-jq}" -r '.result' > "${EXPORT_DIR}/zabbix_api_version.txt" \
    | "${JQ_BIN:-jq}" -r '.result' > "${EXPORT_DIR}/zabbix_api_version.txt"

  [[ "${EXPORT_TEMPLATES:-true}" == "true" ]] && \
    export_object_group "template.get" "templateid" "templates" "templates.${EXPORT_FORMAT:-json}"

  [[ "${EXPORT_HOST_GROUPS:-true}" == "true" ]] && \
    export_object_group "hostgroup.get" "groupid" "host_groups" "host_groups.${EXPORT_FORMAT:-json}"

  [[ "${EXPORT_MEDIA_TYPES:-true}" == "true" ]] && \
    export_object_group "mediatype.get" "mediatypeid" "mediaTypes" "media_types.${EXPORT_FORMAT:-json}"

  if [[ "${EXPORT_ACTIONS:-true}" == "true" ]]; then
    api_call '{
      "jsonrpc":"2.0",
      "method":"action.get",
      "params":{
        "output":"extend",
        "selectOperations":"extend",
        "selectRecoveryOperations":"extend",
        "selectUpdateOperations":"extend",
        "selectFilter":"extend"
      },
      "id":30
    }' | "${JQ_BIN:-jq}" '.result' > "${EXPORT_DIR}/actions.raw.json"

    log "INFO" "Exported actions raw: ${EXPORT_DIR}/actions.raw.json"
  fi

  if [[ "${EXPORT_VALUE_MAPS:-true}" == "true" ]]; then
    api_call '{
      "jsonrpc":"2.0",
      "method":"valuemap.get",
      "params":{
        "output":"extend",
        "selectMappings":"extend"
      },
      "id":31
    }' | "${JQ_BIN:-jq}" '.result' > "${EXPORT_DIR}/value_maps.raw.json"

    log "INFO" "Exported value maps raw: ${EXPORT_DIR}/value_maps.raw.json"
  fi

  [[ "${EXPORT_MAPS:-true}" == "true" ]] && \
    export_object_group "map.get" "sysmapid" "maps" "maps.${EXPORT_FORMAT:-json}"

  if [[ "${EXPORT_MAINTENANCE:-true}" == "true" ]]; then
    api_call '{
      "jsonrpc":"2.0",
      "method":"maintenance.get",
      "params":{
        "output":"extend",
        "selectGroups":"extend",
        "selectHosts":"extend",
        "selectTimeperiods":"extend",
        "selectTags":"extend"
      },
      "id":32
    }' | "${JQ_BIN:-jq}" '.result' > "${EXPORT_DIR}/maintenance.raw.json"

    log "INFO" "Exported maintenance raw: ${EXPORT_DIR}/maintenance.raw.json"
  fi

  [[ "${EXPORT_HOSTS:-true}" == "true" ]] && export_hosts

  ln -sfn "$EXPORT_DIR" "${BACKUP_BASE}/exports/latest"

  EXPORT_STATUS="success"
  log "INFO" "API export done: $EXPORT_DIR"
}
