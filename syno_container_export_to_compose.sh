#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--force] [--volume-root PATH] EXPORT.json [OUTPUT_DIR]" >&2
  exit 1
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

yaml_string() {
  jq -n --arg value "$1" '$value'
}

force='false'
volume_root='/volume1'
positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--force)
      force='true'
      shift
      ;;
    --volume-root)
      shift
      [ "${1:-}" != '' ] || fail "--volume-root requires a path"
      volume_root=$1
      shift
      ;;
    -*)
      usage
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

[ "${#positional[@]}" -ge 1 ] && [ "${#positional[@]}" -le 2 ] || usage
input=${positional[0]}
output_dir=${positional[1]:-$(dirname "$input")}

[ -f "$input" ] || fail "Export file not found: $input"
mkdir -p "$output_dir" || fail "Could not create output directory: $output_dir"
command -v jq >/dev/null 2>&1 || fail "jq is required"

record=$(jq 'if type == "array" then .[0] else . end' "$input") || fail "Invalid JSON export"
name=$(printf '%s\n' "$record" | jq -r '.name // .Name // empty')
image=$(printf '%s\n' "$record" | jq -r '.image // .Image // empty')
[ -n "$name" ] || fail "Export does not contain a container name"
[ -n "$image" ] || fail "Export does not contain an image"
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail "Unsupported container name: $name"

compose_file="${output_dir}/${name}.docker-compose.yml"
env_file="${output_dir}/${name}.env"
compose_temp=$(mktemp "${compose_file}.XXXXXX")
env_temp=$(mktemp "${env_file}.XXXXXX")
cleanup() {
  rm -f "$compose_temp" "$env_temp"
}
trap cleanup EXIT

if [ "$force" != 'true' ] && { [ -e "$compose_file" ] || [ -e "$env_file" ]; }; then
  fail "Output already exists; use --force: $compose_file or $env_file"
fi

{
  printf 'name: %s\n' "$(yaml_string "$name")"
  printf 'services:\n'
  printf '  %s:\n' "$(yaml_string "$name")"
  printf '    image: %s\n' "$(yaml_string "$image")"
  printf '    container_name: %s\n' "$(yaml_string "$name")"

  if [ "$(printf '%s\n' "$record" | jq -r '.env_variables | length')" -gt 0 ]; then
    printf '    env_file:\n      - %s\n' "$(yaml_string "./${name}.env")"
  fi

  if [ "$(printf '%s\n' "$record" | jq -r '.enable_restart_policy // false')" = 'true' ]; then
    printf '    restart: unless-stopped\n'
  fi
  if [ "$(printf '%s\n' "$record" | jq -r '.privileged // false')" = 'true' ]; then
    printf '    privileged: true\n'
  fi
  if [ "$(printf '%s\n' "$record" | jq -r '.tty // false')" = 'true' ]; then
    printf '    tty: true\n'
  fi
  if [ "$(printf '%s\n' "$record" | jq -r '.stdin_open // false')" = 'true' ]; then
    printf '    stdin_open: true\n'
  fi

  for field in hostname domainname user working_dir; do
    value=$(printf '%s\n' "$record" | jq -r --arg field "$field" '.[$field] // empty')
    if [ -n "$value" ]; then
      printf '    %s: %s\n' "$field" "$(yaml_string "$value")"
    fi
  done

  entrypoint_json=$(printf '%s\n' "$record" | jq -c '.entrypoint // null')
  entrypoint_type=$(printf '%s\n' "$entrypoint_json" | jq -r 'type')
  if [ "$entrypoint_type" = 'array' ]; then
    printf '    entrypoint:\n'
    while IFS= read -r entrypoint_arg; do
      printf '      - %s\n' "$(yaml_string "$entrypoint_arg")"
    done < <(printf '%s\n' "$entrypoint_json" | jq -r '.[] | tostring')
  elif [ "$entrypoint_type" != 'null' ] && [ "$entrypoint_json" != '""' ]; then
    printf '    entrypoint: %s\n' "$entrypoint_json"
  fi

  network_mode=$(printf '%s\n' "$record" | jq -r '.network_mode // empty')
  network_names=''
  host_network='false'
  if [ "$(printf '%s\n' "$record" | jq -r '.use_host_network // false')" = 'true' ] || [ "$network_mode" = 'host' ]; then
    host_network='true'
    printf '    network_mode: host\n'
  elif [ "$network_mode" = 'bridge' ] || [ "$network_mode" = 'none' ] || [[ "$network_mode" == service:* ]] || [[ "$network_mode" == container:* ]]; then
    printf '    network_mode: %s\n' "$(yaml_string "$network_mode")"
  else
    network_names=$(printf '%s\n' "$record" | jq -r '.network[]? | .name // .Name // empty')
    if [ -z "$network_names" ] && [ -n "$network_mode" ]; then
      network_names=$network_mode
    fi
    if [ -n "$network_names" ]; then
      printf '    networks:\n'
      while IFS= read -r network_name; do
        [ -n "$network_name" ] || continue
        printf '      - %s\n' "$(yaml_string "$network_name")"
      done <<< "$network_names"
    fi
  fi

  if [ "$host_network" != 'true' ] && [ "$(printf '%s\n' "$record" | jq -r '.port_bindings | length')" -gt 0 ]; then
    printf '    ports:\n'
    while IFS= read -r binding; do
      container_port=$(printf '%s\n' "$binding" | jq -r '.container_port // empty')
      host_port=$(printf '%s\n' "$binding" | jq -r '.host_port // empty')
      protocol=$(printf '%s\n' "$binding" | jq -r '.type // "tcp"')
      [ -n "$container_port" ] || fail "Port binding is missing container_port"
      if [ -n "$host_port" ]; then
        port_mapping="${host_port}:${container_port}/${protocol}"
      else
        port_mapping="${container_port}/${protocol}"
      fi
      printf '      - %s\n' "$(yaml_string "$port_mapping")"
    done < <(printf '%s\n' "$record" | jq -c '.port_bindings[]?')
  fi

  if [ "$(printf '%s\n' "$record" | jq -r '.volume_bindings | length')" -gt 0 ]; then
    printf '    volumes:\n'
    while IFS= read -r binding; do
      host_path=$(printf '%s\n' "$binding" | jq -r '.host_volume_file // empty')
      container_path=$(printf '%s\n' "$binding" | jq -r '.mount_point // empty')
      access=$(printf '%s\n' "$binding" | jq -r '.type // "rw"')
      [ -n "$host_path" ] && [ -n "$container_path" ] || fail "Volume binding is missing a host path or mount point"
      case "$host_path" in
        /volume*|/dev/*|/run/*)
          ;;
        /*)
          host_path="${volume_root%/}/${host_path#/}"
          ;;
        *)
          fail "Unsupported relative volume path: $host_path"
          ;;
      esac
      volume_mapping="${host_path}:${container_path}:${access}"
      printf '      - %s\n' "$(yaml_string "$volume_mapping")"
    done < <(printf '%s\n' "$record" | jq -c '.volume_bindings[]?')
  fi

  for cap_field in CapAdd CapDrop; do
    case "$cap_field" in
      CapAdd) compose_field='cap_add' ;;
      CapDrop) compose_field='cap_drop' ;;
    esac
    if [ "$(printf '%s\n' "$record" | jq -r --arg field "$cap_field" '.[$field] | length')" -gt 0 ]; then
      printf '    %s:\n' "$compose_field"
      while IFS= read -r capability; do
        [ -n "$capability" ] || continue
        printf '      - %s\n' "$(yaml_string "$capability")"
      done < <(printf '%s\n' "$record" | jq -r --arg field "$cap_field" '.[$field][]?')
    fi
  done

  if [ "$(printf '%s\n' "$record" | jq -r '.labels | length')" -gt 0 ]; then
    printf '    labels:\n'
    while IFS= read -r label; do
      key=$(printf '%s\n' "$label" | jq -r '.key')
      value=$(printf '%s\n' "$label" | jq -r '.value | tostring')
      printf '      %s: %s\n' "$(yaml_string "$key")" "$(yaml_string "$value")"
    done < <(printf '%s\n' "$record" | jq -c '.labels | to_entries[]?')
  fi

  if [ "$(printf '%s\n' "$record" | jq -r '.devices | length')" -gt 0 ]; then
    printf '    devices:\n'
    while IFS= read -r device; do
      device_mapping=$(printf '%s\n' "$device" | jq -r 'if type == "string" then . else ((.path_on_host // .host_path // .host_volume_file // .source // empty) + ":" + (.path_in_container // .container_path // .mount_point // .destination // empty) + (if (.cgroup_permissions // .permissions // "") == "" then "" else ":" + (.cgroup_permissions // .permissions) end)) end')
      [[ "$device_mapping" == *:* ]] || fail "Unsupported device mapping in export"
      printf '      - %s\n' "$(yaml_string "$device_mapping")"
    done < <(printf '%s\n' "$record" | jq -c '.devices[]?')
  fi

  command_json=$(printf '%s\n' "$record" | jq -c '.cmd_v2 // .cmd // null')
  command_type=$(printf '%s\n' "$command_json" | jq -r 'type')
  if [ "$command_type" = 'array' ]; then
    printf '    command:\n'
    while IFS= read -r command_arg; do
      printf '      - %s\n' "$(yaml_string "$command_arg")"
    done < <(printf '%s\n' "$command_json" | jq -r '.[] | tostring')
  elif [ "$command_type" != 'null' ] && [ "$command_json" != '""' ]; then
    printf '    command: %s\n' "$command_json"
  fi

  printf '    logging:\n      driver: local\n'

  cpu_priority=$(printf '%s\n' "$record" | jq -r '.cpu_priority // empty')
  memory_limit=$(printf '%s\n' "$record" | jq -r '.memory_limit // 0')
  if [ -n "$cpu_priority" ] || { [ -n "$memory_limit" ] && [ "$memory_limit" != '0' ]; }; then
    printf '    # Review Synology-only resource settings manually:'
    [ -n "$cpu_priority" ] && printf ' cpu_priority=%s' "$cpu_priority"
    [ -n "$memory_limit" ] && [ "$memory_limit" != '0' ] && printf ' memory_limit=%s' "$memory_limit"
    printf '\n'
  fi

  if [ -n "$network_names" ] && [ "$host_network" != 'true' ] &&
    [ "$network_mode" != 'bridge' ] && [ "$network_mode" != 'none' ] &&
    [[ "$network_mode" != service:* ]] && [[ "$network_mode" != container:* ]]; then
    printf 'networks:\n'
    while IFS= read -r network_name; do
      [ -n "$network_name" ] || continue
      printf '  %s:\n    external: true\n' "$(yaml_string "$network_name")"
    done <<< "$network_names"
  fi
} > "$compose_temp"

if [ "$(printf '%s\n' "$record" | jq -r '.env_variables | length')" -gt 0 ]; then
  while IFS= read -r env_entry; do
    env_key=$(printf '%s\n' "$env_entry" | jq -r '.key // .name // empty')
    env_value=$(printf '%s\n' "$env_entry" | jq -r '(.value // "") | tostring')
    [[ "$env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "Unsupported environment variable name: $env_key"
    if [[ "$env_value" == *$'\n'* ]] || [[ "$env_value" == *$'\r'* ]]; then
      fail "Environment variable $env_key contains a newline and needs manual review"
    fi
    printf '%s=%s\n' "$env_key" "$env_value" >> "$env_temp"
  done < <(printf '%s\n' "$record" | jq -c '.env_variables[]?')
fi

mv "$compose_temp" "$compose_file"
if [ -s "$env_temp" ]; then
  mv "$env_temp" "$env_file"
  chmod 600 "$env_file"
else
  rm -f "$env_temp"
fi
chmod 600 "$compose_file"
trap - EXIT

printf 'Wrote %s\n' "$compose_file"
if [ -f "$env_file" ]; then
  printf 'Wrote private environment file %s\n' "$env_file"
fi
printf 'Review the files, remove or rename the old stopped container, then run:\n'
printf '  docker-compose -f %q up -d --force-recreate\n' "$compose_file"
