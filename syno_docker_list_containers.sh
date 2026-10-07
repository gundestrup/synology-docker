#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
readonly SCRIPT_DIR
readonly NOT_COMPOSE="!---not_managed_by_compose---!"
readonly MAYBE_PORTAINER="!---maybe_managed_by_portainer---!"

usage() {
  echo "Usage: $0 [--compose-dir DIR] [--force] [CONTAINER]" >&2
  echo "With --compose-dir, existing Compose output is compared and differences are saved as .generated unless --force is used." >&2
  exit 1
}

compose_dir=''
force='false'
target_container=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --compose-dir)
      shift
      [ "${1:-}" != '' ] || usage
      compose_dir=$1
      shift
      ;;
    -f|--force)
      force='true'
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      usage
      ;;
    *)
      [ -z "$target_container" ] || usage
      target_container=$1
      shift
      ;;
  esac
done

containers=()
if [ -n "$target_container" ]; then
  docker inspect "$target_container" >/dev/null
  containers+=("$target_container")
else
  while IFS= read -r container_id; do
    [ -n "$container_id" ] && containers+=("$container_id")
  done < <(docker ps -aq)
fi

# Store container information in an array
containers_info=()
# Get the list of containers and their compose locations
for c in "${containers[@]}"; do
  container_info=$(docker inspect "$c" --format "{{.Name}} {{if index .Config.Labels \"com.docker.compose.project.config_files\"}}{{index .Config.Labels \"com.docker.compose.project.config_files\"}}{{else}}${NOT_COMPOSE}{{end}} {{.HostConfig.LogConfig.Type}}")
  containers_info+=("$container_info")
done

# Sort the array based on the second field (compose location)
sorted_containers_info=()
while IFS= read -r info; do
  [ -n "$info" ] || continue
  sorted_containers_info+=("$info")
done < <(printf "%s\n" "${containers_info[@]}" | sort -t " " -k 2)
# Original with -u - this unfortunately hides portainer containers.
# IFS=$'\n' sorted_containers_info=($(printf "%s\n" "${containers_info[@]}" | sort -t -u " " -k 2))

# Calculate the maximum length for the container names and compose locations
max_container_length=0
max_location_length=0
max_logger_length=7
for info in "${sorted_containers_info[@]}"; do
  container=${info%% *}
  logger=${info##* }
  location=${info#* }
  location=${location% *}
  [ "${#container}" -gt "$max_container_length" ] && max_container_length=${#container}
  [ "${#location}" -gt "$max_location_length" ] && max_location_length=${#location}
  [ "${#logger}" -gt "$max_logger_length" ] && max_logger_length=${#logger}
done

# Print the header
echo
printf "%-${max_container_length}s  %-${max_location_length}s %-${max_logger_length}s\n" \
  "Container" "Compose_Location" "Logger"
printf "%-${max_container_length}s  %-${max_location_length}s %-${max_logger_length}s\n" \
  "$(printf '%*s' "${max_container_length}" '' | tr ' ' '-')" \
  "$(printf '%*s' "${max_location_length}" '' | tr ' ' '-')" \
  "$(printf '%*s' "${max_logger_length}" '' | tr ' ' '-')"

docker_managed=()
# Print the sorted container information
for info in "${sorted_containers_info[@]}"; do
  container=${info%% *}
  logger=${info##* }
  location=${info#* }
  location=${location% *}
  if [ "$location" != "$NOT_COMPOSE" ] && [ ! -f "$location" ];then
  location="${MAYBE_PORTAINER}"
  fi
  if [ "$location" == "$NOT_COMPOSE" ]; then
  docker_managed+=("$container")
  fi
  printf "%-${max_container_length}s  %-${max_location_length}s %s\n" "$container" "$location" "$logger"
done

if [ ${#docker_managed[@]} -gt 0 ]; then
  # There are containers not managed by compose nor portainer.
  # Provide some clues on how to restart those containers.
  echo
  echo "The following containers may have been created with docker commands."
  echo "Below are some clues on the command needed to to recreate them ONLY IF YOU HAVE NO OTHER WAY TO DO SO."
  echo "...this is a best guess and may not be 100% accurate."
  echo "If these containers already show as 'local' logger, there is no need to recreate them manually"
  echo
  for container in "${docker_managed[@]}"; do
    docker_command=$("${SCRIPT_DIR}/container_recreate.sh" "$container")
    echo "----------------------------------------------------"
    echo "Container: ${container}"
    echo "----------------------------------------------------"
    printf '%s\n' "$docker_command"
    echo
  done
fi

if [ -n "$compose_dir" ]; then
  if [ ${#docker_managed[@]} -eq 0 ]; then
    echo "No non-Compose containers to convert."
    exit 0
  fi
  mkdir -p "$compose_dir"
  converter_args=()
  [ "$force" = 'true' ] && converter_args+=(--force)
  for container in "${docker_managed[@]}"; do
    inspect_temp=$(mktemp "${compose_dir}/.docker-inspect.XXXXXX")
    docker inspect "$container" > "$inspect_temp"
    "${SCRIPT_DIR}/syno_container_export_to_compose.sh" "${converter_args[@]}" "$inspect_temp" "$compose_dir"
    rm -f "$inspect_temp"
  done
elif [ -n "$target_container" ] && [ ${#docker_managed[@]} -eq 0 ]; then
  echo "Container is already Compose-managed or was not found."
fi
