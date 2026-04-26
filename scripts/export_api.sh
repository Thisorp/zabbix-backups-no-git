#!/usr/bin/env bash

api_call() {
  local payload="$1"
  local response
  local retry="${API_RETRY:-3}"
  local timeout="${API_TIMEOUT:-60}"
  local count=1

  while true; do
    response="$(
      "${CURL_BIN:-curl}" -sS \
        --connect-timeout 10 \
        --max-time "$timeout" \
        -H "Content-Type: application/json-rpc" \
        -H "Authorization: Bearer ${ZBX_TOKEN}" \
        -X POST \
        -d "$payload" \
        "${ZBX_URL%/}/api_jsonrpc.php"
    )" && break

    if (( count >= retry )); then
      die "Zabbix API curl failed after ${retry} attempts"
    fi

    log "WARN" "API curl failed, retry ${count}/${retry}"
    count=$((count + 1))
    sleep 2
  done

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

normalize_json_file() {
  local file="$1"

  [[ -s "$file" ]] || die "Export file is empty: $file"

  if [[ "${EXPORT_FORMAT:-json}" == "json" ]]; then
    "${JQ_BIN:-jq}" . "$file" > "${file}.tmp" \
      && mv "${file}.tmp" "$file"
  fi
}

export_object_group() {
  local get_method="$1"
  local id_field="$2"
  local option_key="$3"
  local output_file="$4"

  local batch_size="${EXPORT_OBJECT_BATCH_SIZE:-100}"
  local object_name="${output_file%.*}"
  local batch_dir="${EXPORT_DIR}/${object_name}"
  local ids_file="${EXPORT_DIR}/${object_name}_ids.txt"
  local index_file="${EXPORT_DIR}/${object_name}_index.txt"

  local total
  local start=1
  local end
  local batch_no=1
  local batch_ids
  local ids_json
  local outfile

  mkdir -p "$batch_dir"
  : > "$index_file"

  api_call "{
    \"jsonrpc\":\"2.0\",
    \"method\":\"${get_method}\",
    \"params\":{\"output\":[\"${id_field}\"]},
    \"id\":1
  }" | "${JQ_BIN:-jq}" -r ".result[].${id_field}" > "$ids_file"

  total="$(wc -l < "$ids_file" | tr -d ' ')"

  if [[ "$total" == "0" || -z "$total" ]]; then
    log "WARN" "No objects found for ${option_key}"
    return 0
  fi

  log "INFO" "Export ${option_key}: total=${total}, batch=${batch_size}"

  while (( start <= total )); do
    end=$((start + batch_size - 1))
    batch_ids="$(sed -n "${start},${end}p" "$ids_file")"

    ids_json="$(
      echo "$batch_ids" \
        | "${JQ_BIN:-jq}" -R . \
        | "${JQ_BIN:-jq}" -s 'map(tostring)'
    )"

    outfile="${batch_dir}/${object_name}_$(printf "%04d" "$batch_no").${EXPORT_FORMAT:-json}"

    api_call "{
      \"jsonrpc\":\"2.0\",
      \"method\":\"configuration.export\",
      \"params\":{
        \"format\":\"${EXPORT_FORMAT:-json}\",
        \"options\":{\"${option_key}\":${ids_json}}
      },
      \"id\":2
    }" | "${JQ_BIN:-jq}" -r '.result' > "$outfile"

    if [[ ! -s "$outfile" ]]; then
      log "WARN" "Empty export file, skip: $outfile"
      rm -f "$outfile"
    else
      normalize_json_file "$outfile"
      echo "$outfile" >> "$index_file"
      log "INFO" "Exported ${option_key} batch ${batch_no}: $outfile"
    fi

    start=$((end + 1))
    batch_no=$((batch_no + 1))
  done
}

export_hosts() {
  local batch_size="${HOST_EXPORT_BATCH_SIZE:-100}"
  local all_ids_file="${EXPORT_DIR}/hosts_all_ids.txt"
  local batch_dir="${EXPORT_DIR}/hosts"
  local index_file="${EXPORT_DIR}/hosts_index.txt"
  local total
  local start=1
  local end
  local batch_no=1
  local batch_ids
  local ids_json
  local outfile

  mkdir -p "$batch_dir"
  : > "$index_file"

  log "INFO" "Fetching all host IDs..."

  api_call '{
    "jsonrpc":"2.0",
    "method":"host.get",
    "params":{"output":["hostid"]},
    "id":10
  }' | "${JQ_BIN:-jq}" -r '.result[].hostid' > "$all_ids_file"

  total="$(wc -l < "$all_ids_file" | tr -d ' ')"

  if [[ "$total" == "0" || -z "$total" ]]; then
    log "WARN" "No hosts found"
    return 0
  fi

  log "INFO" "Total hosts: ${total}; batch size: ${batch_size}"

  while (( start <= total )); do
    end=$((start + batch_size - 1))

    batch_ids="$(sed -n "${start},${end}p" "$all_ids_file")"

    ids_json="$(
      echo "$batch_ids" \
        | "${JQ_BIN:-jq}" -R . \
        | "${JQ_BIN:-jq}" -s 'map(tostring)'
    )"

    outfile="${batch_dir}/hosts_$(printf "%04d" "$batch_no").${EXPORT_FORMAT:-json}"

    api_call "{
      \"jsonrpc\":\"2.0\",
      \"method\":\"configuration.export\",
      \"params\":{
        \"format\":\"${EXPORT_FORMAT:-json}\",
        \"options\":{\"hosts\":${ids_json}}
      },
      \"id\":11
    }" | "${JQ_BIN:-jq}" -r '.result' > "$outfile"

    normalize_json_file "$outfile"

    echo "$outfile" >> "$index_file"

    log "INFO" "Exported hosts batch ${batch_no}: ${outfile}"

    start=$((end + 1))
    batch_no=$((batch_no + 1))
  done

  log "INFO" "Host export completed: ${batch_no} batches index=${index_file}"
}

export_raw_json() {
  local method="$1"
  local output_file="$2"
  local params="$3"

  api_call "{
    \"jsonrpc\":\"2.0\",
    \"method\":\"${method}\",
    \"params\":${params},
    \"id\":50
  }" | "${JQ_BIN:-jq}" '.result' > "${EXPORT_DIR}/${output_file}"

  normalize_json_file "${EXPORT_DIR}/${output_file}"

  log "INFO" "Exported raw ${method}: ${EXPORT_DIR}/${output_file}"
}

export_api() {
  EXPORT_STATUS="skipped"

  if [[ "${ENABLE_API_EXPORT:-true}" != "true" ]]; then
    EXPORT_STATUS="disabled"
    return 0
  fi

  [[ -n "${ZBX_URL:-}" ]] || die "ZBX_URL is empty"
  [[ -n "${ZBX_TOKEN:-}" ]] || die "ZBX_TOKEN is empty"

  EXPORT_DIR="${BACKUP_BASE}/exports/${DATE}"
  mkdir -p "$EXPORT_DIR"

  log "INFO" "Testing Zabbix API version..."

  "${CURL_BIN:-curl}" -sS \
    --connect-timeout 10 \
    --max-time "${API_TIMEOUT:-60}" \
    -H "Content-Type: application/json-rpc" \
    -X POST \
    -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":100}' \
    "${ZBX_URL%/}/api_jsonrpc.php" \
    | "${JQ_BIN:-jq}" -r '.result' > "${EXPORT_DIR}/zabbix_api_version.txt"

  [[ -s "${EXPORT_DIR}/zabbix_api_version.txt" ]] || die "Cannot get Zabbix API version"

  [[ "${EXPORT_TEMPLATES:-true}" == "true" ]] && \
    export_object_group "template.get" "templateid" "templates" "templates.${EXPORT_FORMAT:-json}"

  [[ "${EXPORT_HOST_GROUPS:-true}" == "true" ]] && \
    export_object_group "hostgroup.get" "groupid" "host_groups" "host_groups.${EXPORT_FORMAT:-json}"

  [[ "${EXPORT_MEDIA_TYPES:-true}" == "true" ]] && \
    export_object_group "mediatype.get" "mediatypeid" "mediaTypes" "media_types.${EXPORT_FORMAT:-json}"

  [[ "${EXPORT_ACTIONS:-true}" == "true" ]] && \
    export_raw_json "action.get" "actions.raw.json" '{
      "output":"extend",
      "selectOperations":"extend",
      "selectRecoveryOperations":"extend",
      "selectUpdateOperations":"extend",
      "selectFilter":"extend"
    }'

  [[ "${EXPORT_VALUE_MAPS:-true}" == "true" ]] && \
    export_raw_json "valuemap.get" "value_maps.raw.json" '{
      "output":"extend",
      "selectMappings":"extend"
    }'

  [[ "${EXPORT_MAPS:-true}" == "true" ]] && \
    export_object_group "map.get" "sysmapid" "maps" "maps.${EXPORT_FORMAT:-json}"

  [[ "${EXPORT_MAINTENANCE:-true}" == "true" ]] && \
    export_raw_json "maintenance.get" "maintenance.raw.json" '{
      "output":"extend",
      "selectGroups":"extend",
      "selectHosts":"extend",
      "selectTimeperiods":"extend",
      "selectTags":"extend"
    }'

  [[ "${EXPORT_HOSTS:-true}" == "true" ]] && export_hosts

  ln -sfn "$EXPORT_DIR" "${BACKUP_BASE}/exports/latest"

  EXPORT_STATUS="success"
  log "INFO" "API export done: $EXPORT_DIR"
}
