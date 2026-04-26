#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE=${NAMESPACE:-criu-svc-test}
SOURCE_POD=${SOURCE_POD:-server-source}
SOURCE_CONTAINER=${SOURCE_CONTAINER:-server}
RESTORE_POD=${RESTORE_POD:-server-restore}
SERVICE=${SERVICE:-criu-server-svc}
RESTORE_IMAGE=${RESTORE_IMAGE:-localhost/checkpoint-server-source:latest}
CHECKPOINT_DIR=${CHECKPOINT_DIR:-/mnt/data/kubelet/checkpoints}

ITERATIONS=${ITERATIONS:-1}
OUT_DIR=${OUT_DIR:-logs/measurements}
CHECKPOINT_TIMEOUT_SECONDS=${CHECKPOINT_TIMEOUT_SECONDS:-60}
POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-0.1}
SERVICE_TIMEOUT_SECONDS=${SERVICE_TIMEOUT_SECONDS:-300}
CLEANUP_BEFORE=${CLEANUP_BEFORE:-1}
CLEANUP_AFTER=${CLEANUP_AFTER:-0}

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -n, --iterations N          Number of experiment iterations. Default: $ITERATIONS
  -o, --out-dir DIR           Output directory. Default: $OUT_DIR
      --no-cleanup-before     Reuse existing namespace instead of recreating it.
      --cleanup-after         Delete the namespace after all iterations.
  -h, --help                  Show this help.

Environment overrides:
  NAMESPACE SOURCE_POD SOURCE_CONTAINER RESTORE_POD SERVICE RESTORE_IMAGE
  CHECKPOINT_DIR CHECKPOINT_TIMEOUT_SECONDS POLL_INTERVAL_SECONDS
  SERVICE_TIMEOUT_SECONDS CLEANUP_BEFORE CLEANUP_AFTER
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--iterations)
      ITERATIONS="$2"
      shift 2
      ;;
    -o|--out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --no-cleanup-before)
      CLEANUP_BEFORE=0
      shift
      ;;
    --cleanup-after)
      CLEANUP_AFTER=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

for cmd in kubectl curl date sudo; do
  require_cmd "$cmd"
done

now_ns() {
  date +%s%N
}

iso_now() {
  date --iso-8601=ns
}

ns_to_ms() {
  local start=$1
  local end=$2
  if [[ -z "$start" || -z "$end" || "$start" == "0" || "$end" == "0" ]]; then
    echo ""
    return
  fi
  echo $(((end - start) / 1000000))
}

log() {
  printf '[%s] %s\n' "$(iso_now)" "$*"
}

json_escape() {
  local value=${1//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

event() {
  local file=$1
  local name=$2
  local ns=$3
  local detail=${4:-}
  printf '{"time":"%s","event":"%s","ns":%s,"detail":"%s"}\n' \
    "$(iso_now)" "$name" "$ns" "$(json_escape "$detail")" >> "$file"
}

wait_for_namespace_deleted() {
  local timeout=${1:-120}
  local start
  start=$(now_ns)
  while kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; do
    if (( ($(now_ns) - start) / 1000000000 > timeout )); then
      echo "Timed out waiting for namespace deletion: $NAMESPACE" >&2
      return 1
    fi
    sleep 1
  done
}

reset_namespace() {
  if [[ "$CLEANUP_BEFORE" == "1" ]]; then
    log "Deleting namespace $NAMESPACE if it exists"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
    wait_for_namespace_deleted 180
  fi

  log "Applying Kubernetes manifests"
  kubectl apply -f namespace.yaml
  kubectl apply -f service.yaml
  kubectl apply -f server-source.yaml
  kubectl apply -f client.yaml
  kubectl delete pod "$RESTORE_POD" -n "$NAMESPACE" --ignore-not-found=true

  kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/$SOURCE_POD" --timeout=120s
  kubectl wait -n "$NAMESPACE" --for=condition=Ready pod/client --timeout=120s
}

endpoint_lines() {
  kubectl get endpointslice -n "$NAMESPACE" \
    -l "kubernetes.io/service-name=$SERVICE" \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{" "}{.conditions.ready}{" "}{.addresses[*]}{"\n"}{end}' 2>/dev/null || true
}

source_endpoint_removed() {
  ! endpoint_lines | awk -v pod="$SOURCE_POD" '$1 == pod && $2 == "true" { found=1 } END { exit found ? 0 : 1 }'
}

restore_endpoint_ready() {
  endpoint_lines | awk -v pod="$RESTORE_POD" '$1 == pod && $2 == "true" { found=1 } END { exit found ? 0 : 1 }'
}

wait_until() {
  local name=$1
  local timeout_seconds=$2
  local start
  shift 2
  start=$(now_ns)
  while true; do
    if "$@"; then
      now_ns
      return 0
    fi
    if (( ($(now_ns) - start) / 1000000000 >= timeout_seconds )); then
      echo "Timed out waiting for $name" >&2
      return 1
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

pod_ready() {
  local pod=$1
  [[ "$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]]
}

service_request_once() {
  local service_host="${SERVICE}.${NAMESPACE}.svc.cluster.local"
  local code
  code=$(kubectl exec -n "$NAMESPACE" client -- \
    curl -sS --connect-timeout 1 --max-time 1 -o /dev/null -w '%{http_code}' \
    "http://${service_host}/" 2>/dev/null || true)
  [[ "$code" == "200" ]]
}

start_service_monitor() {
  local output_file=$1
  local timeout_seconds=$2
  (
    local start
    start=$(now_ns)
    while true; do
      if service_request_once; then
        now_ns > "$output_file"
        exit 0
      fi
      if (( ($(now_ns) - start) / 1000000000 >= timeout_seconds )); then
        : > "$output_file"
        exit 1
      fi
      sleep "$POLL_INTERVAL_SECONDS"
    done
  ) >/dev/null 2>&1 &
  SERVICE_MONITOR_PID=$!
}

checkpoint_once() {
  local response_file=$1
  local status_file=$2
  local status
  status=$(curl --insecure --silent --show-error \
    --cert client-admin.crt \
    --key client-admin.key \
    -X POST \
    -o "$response_file" \
    -w '%{http_code}' \
    "https://localhost:10250/checkpoint/${NAMESPACE}/${SOURCE_POD}/${SOURCE_CONTAINER}" 2>"${response_file}.stderr" || true)
  printf '%s' "$status" > "$status_file"
  [[ "$status" =~ ^2[0-9][0-9]$ ]]
}

checkpoint_until_success() {
  local iter_dir=$1
  local event_file=$2
  local start
  local attempts=0
  local response_file status_file status detail
  start=$(now_ns)

  while true; do
    attempts=$((attempts + 1))
    response_file="${iter_dir}/checkpoint-attempt-${attempts}.body"
    status_file="${iter_dir}/checkpoint-attempt-${attempts}.status"
    if checkpoint_once "$response_file" "$status_file"; then
      event "$event_file" "checkpoint_success" "$(now_ns)" "attempt=$attempts"
      printf '%s %s\n' "$(now_ns)" "$attempts"
      return 0
    fi

    status=$(cat "$status_file")
    detail="attempt=$attempts status=$status body=$(tr '\n' ' ' < "$response_file") stderr=$(tr '\n' ' ' < "${response_file}.stderr")"
    event "$event_file" "checkpoint_retry" "$(now_ns)" "$detail"

    if (( ($(now_ns) - start) / 1000000000 >= CHECKPOINT_TIMEOUT_SECONDS )); then
      echo "Checkpoint did not succeed within ${CHECKPOINT_TIMEOUT_SECONDS}s" >&2
      return 1
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

latest_checkpoint_archive() {
  sudo find "$CHECKPOINT_DIR" -type f \
    -name "checkpoint-${SOURCE_POD}_${NAMESPACE}-${SOURCE_CONTAINER}-*.tar" \
    | sort \
    | tail -n 1
}

build_and_import_restore_image() {
  local archive=$1
  local oci_archive=$2
  sudo checkpointctl build "$archive" "$RESTORE_IMAGE"
  sudo buildah push "$RESTORE_IMAGE" "oci-archive:${oci_archive}:${RESTORE_IMAGE}"
  sudo ctr -n k8s.io images import "$oci_archive"
}

mkdir -p "$OUT_DIR"
RUN_ID=$(date +%Y%m%d-%H%M%S)
CSV_FILE="${OUT_DIR}/migration-measurements-${RUN_ID}.csv"

cat > "$CSV_FILE" <<'EOF'
run_id,iteration,label_remove_ns,endpoint_source_removed_ns,checkpoint_success_ns,restore_image_build_start_ns,restore_image_imported_ns,restore_apply_ns,restore_ready_ns,endpointslice_restore_ready_ns,service_success_ns,label_to_endpoint_removed_ms,drain_to_checkpoint_ms,checkpoint_to_restore_apply_ms,restore_image_build_import_ms,restore_apply_to_ready_ms,restore_apply_to_endpointslice_ready_ms,restore_ready_to_endpointslice_ready_ms,label_to_service_success_ms,endpoint_removed_to_service_success_ms,total_migration_ms,checkpoint_attempts,checkpoint_archive
EOF

for iteration in $(seq 1 "$ITERATIONS"); do
  ITER_DIR="${OUT_DIR}/${RUN_ID}/iteration-${iteration}"
  mkdir -p "$ITER_DIR"
  EVENT_FILE="${ITER_DIR}/events.jsonl"
  SERVICE_SUCCESS_FILE="${ITER_DIR}/service-success.ns"
  OCI_ARCHIVE="/tmp/checkpoint-server-source-${RUN_ID}-${iteration}.tar"

  log "Starting iteration ${iteration}/${ITERATIONS}"
  event "$EVENT_FILE" "iteration_start" "$(now_ns)" "iteration=$iteration"
  reset_namespace

  log "Removing $SOURCE_POD from Service selector"
  LABEL_REMOVE_NS=$(now_ns)
  event "$EVENT_FILE" "label_remove_start" "$LABEL_REMOVE_NS" ""
  kubectl label pod "$SOURCE_POD" app- -n "$NAMESPACE" --overwrite
  event "$EVENT_FILE" "label_remove_done" "$(now_ns)" ""

  ENDPOINT_SOURCE_REMOVED_NS=$(wait_until "source endpoint removal" 60 source_endpoint_removed)
  event "$EVENT_FILE" "source_endpoint_removed" "$ENDPOINT_SOURCE_REMOVED_NS" "$(endpoint_lines)"

  start_service_monitor "$SERVICE_SUCCESS_FILE" "$SERVICE_TIMEOUT_SECONDS"

  log "Retrying checkpoint until it succeeds"
  read -r CHECKPOINT_SUCCESS_NS CHECKPOINT_ATTEMPTS < <(checkpoint_until_success "$ITER_DIR" "$EVENT_FILE")
  CHECKPOINT_ARCHIVE=$(latest_checkpoint_archive)
  event "$EVENT_FILE" "checkpoint_archive" "$(now_ns)" "$CHECKPOINT_ARCHIVE"

  log "Building and importing restore image"
  BUILD_START_NS=$(now_ns)
  event "$EVENT_FILE" "restore_image_build_start" "$BUILD_START_NS" "$CHECKPOINT_ARCHIVE"
  build_and_import_restore_image "$CHECKPOINT_ARCHIVE" "$OCI_ARCHIVE"
  RESTORE_IMAGE_IMPORTED_NS=$(now_ns)
  event "$EVENT_FILE" "restore_image_imported" "$RESTORE_IMAGE_IMPORTED_NS" "$RESTORE_IMAGE"

  log "Applying restore Pod"
  RESTORE_APPLY_NS=$(now_ns)
  event "$EVENT_FILE" "restore_apply_start" "$RESTORE_APPLY_NS" ""
  kubectl apply -f server-restore.yaml

  RESTORE_READY_NS=$(wait_until "restore pod ready" 180 pod_ready "$RESTORE_POD")
  event "$EVENT_FILE" "restore_pod_ready" "$RESTORE_READY_NS" ""

  ENDPOINTSLICE_RESTORE_READY_NS=$(wait_until "restore endpoint ready" 60 restore_endpoint_ready)
  event "$EVENT_FILE" "restore_endpoint_ready" "$ENDPOINTSLICE_RESTORE_READY_NS" "$(endpoint_lines)"

  wait "$SERVICE_MONITOR_PID" || true
  SERVICE_SUCCESS_NS=$(cat "$SERVICE_SUCCESS_FILE" 2>/dev/null || true)
  if [[ -z "$SERVICE_SUCCESS_NS" ]]; then
    event "$EVENT_FILE" "service_success_timeout" "$(now_ns)" ""
  else
    event "$EVENT_FILE" "service_success" "$SERVICE_SUCCESS_NS" ""
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
    "$RUN_ID" \
    "$iteration" \
    "$LABEL_REMOVE_NS" \
    "$ENDPOINT_SOURCE_REMOVED_NS" \
    "$CHECKPOINT_SUCCESS_NS" \
    "$BUILD_START_NS" \
    "$RESTORE_IMAGE_IMPORTED_NS" \
    "$RESTORE_APPLY_NS" \
    "$RESTORE_READY_NS" \
    "$ENDPOINTSLICE_RESTORE_READY_NS" \
    "$SERVICE_SUCCESS_NS" \
    "$(ns_to_ms "$LABEL_REMOVE_NS" "$ENDPOINT_SOURCE_REMOVED_NS")" \
    "$(ns_to_ms "$LABEL_REMOVE_NS" "$CHECKPOINT_SUCCESS_NS")" \
    "$(ns_to_ms "$CHECKPOINT_SUCCESS_NS" "$RESTORE_APPLY_NS")" \
    "$(ns_to_ms "$BUILD_START_NS" "$RESTORE_IMAGE_IMPORTED_NS")" \
    "$(ns_to_ms "$RESTORE_APPLY_NS" "$RESTORE_READY_NS")" \
    "$(ns_to_ms "$RESTORE_APPLY_NS" "$ENDPOINTSLICE_RESTORE_READY_NS")" \
    "$(ns_to_ms "$RESTORE_READY_NS" "$ENDPOINTSLICE_RESTORE_READY_NS")" \
    "$(ns_to_ms "$LABEL_REMOVE_NS" "$SERVICE_SUCCESS_NS")" \
    "$(ns_to_ms "$ENDPOINT_SOURCE_REMOVED_NS" "$SERVICE_SUCCESS_NS")" \
    "$(ns_to_ms "$LABEL_REMOVE_NS" "$SERVICE_SUCCESS_NS")" \
    "$CHECKPOINT_ATTEMPTS" \
    "$CHECKPOINT_ARCHIVE" >> "$CSV_FILE"

  kubectl get pod -n "$NAMESPACE" -o wide > "${ITER_DIR}/pods.txt"
  kubectl get endpointslice -n "$NAMESPACE" \
    -l "kubernetes.io/service-name=$SERVICE" \
    -o yaml > "${ITER_DIR}/endpointslice.yaml"
  kubectl get events -n "$NAMESPACE" \
    --sort-by=.metadata.creationTimestamp > "${ITER_DIR}/k8s-events.txt"

  event "$EVENT_FILE" "iteration_done" "$(now_ns)" "iteration=$iteration"
done

if [[ "$CLEANUP_AFTER" == "1" ]]; then
  log "Deleting namespace $NAMESPACE"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
fi

log "Wrote measurements to $CSV_FILE"
