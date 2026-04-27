#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE=${NAMESPACE:-criu-svc-test}
SOURCE_POD=${SOURCE_POD:-server-source}
SOURCE_CONTAINER=${SOURCE_CONTAINER:-server}
RESTORE_POD=${RESTORE_POD:-server-restore}
SERVICE=${SERVICE:-criu-server-svc}

HOLD_SECONDS=${HOLD_SECONDS:-30}
INITIAL_CHECKPOINT_WINDOW_SECONDS=${INITIAL_CHECKPOINT_WINDOW_SECONDS:-10}
POST_RELEASE_CHECKPOINT_TIMEOUT_SECONDS=${POST_RELEASE_CHECKPOINT_TIMEOUT_SECONDS:-60}
POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-1}
OUT_DIR=${OUT_DIR:-logs/long-lived-drain}
CLEANUP_BEFORE=${CLEANUP_BEFORE:-1}
CLEANUP_AFTER=${CLEANUP_AFTER:-0}

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
      --hold-seconds N             Long-lived request duration. Default: $HOLD_SECONDS
      --initial-window-seconds N   Checkpoint retry window while the connection is active. Default: $INITIAL_CHECKPOINT_WINDOW_SECONDS
      --cleanup-after              Delete the namespace after the experiment.
  -o, --out-dir DIR                Output directory. Default: $OUT_DIR
  -h, --help                       Show this help.

This experiment starts a long-lived HTTP request through the Service, removes
the source Pod from the Service, then checks whether checkpoint is blocked until
the long-lived connection is released.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hold-seconds)
      HOLD_SECONDS="$2"
      shift 2
      ;;
    --initial-window-seconds)
      INITIAL_CHECKPOINT_WINDOW_SECONDS="$2"
      shift 2
      ;;
    --cleanup-after)
      CLEANUP_AFTER=1
      shift
      ;;
    -o|--out-dir)
      OUT_DIR="$2"
      shift 2
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

for cmd in kubectl curl date; do
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
  if [[ -z "$start" || -z "$end" ]]; then
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

active_holds() {
  kubectl exec -n "$NAMESPACE" "$SOURCE_POD" -- \
    python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/holds", timeout=2).read().decode().strip())' \
    2>/dev/null || echo 0
}

service_request_once() {
  local service_host="${SERVICE}.${NAMESPACE}.svc.cluster.local"
  kubectl exec -n "$NAMESPACE" client -- \
    curl -sS --connect-timeout 1 --max-time 2 -o /dev/null \
    "http://${service_host}/ready" >/dev/null 2>&1
}

dump_hold_client_state() {
  echo "--- hold.out ---" >&2
  cat "${RUN_DIR}/hold.out" >&2 2>/dev/null || true
  echo "--- hold.err ---" >&2
  cat "${RUN_DIR}/hold.err" >&2 2>/dev/null || true
}

wait_for_active_holds() {
  local expected=$1
  local timeout=$2
  local start current
  start=$(now_ns)
  while true; do
    current=$(active_holds)
    if (( current == expected )); then
      now_ns
      return 0
    fi
    if (( ($(now_ns) - start) / 1000000000 >= timeout )); then
      echo "Timed out waiting for active_holds=$expected; last=$current" >&2
      return 1
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

endpoint_lines() {
  kubectl get endpointslice -n "$NAMESPACE" \
    -l "kubernetes.io/service-name=$SERVICE" \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{" "}{.conditions.ready}{" "}{.addresses[*]}{"\n"}{end}' 2>/dev/null || true
}

source_endpoint_removed() {
  ! endpoint_lines | awk -v pod="$SOURCE_POD" '$1 == pod && $2 == "true" { found=1 } END { exit found ? 0 : 1 }'
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

try_checkpoint_for_window() {
  local phase=$1
  local timeout_seconds=$2
  local iter_dir=$3
  local event_file=$4
  local start attempts response_file status_file status detail
  start=$(now_ns)
  attempts=0
  while true; do
    attempts=$((attempts + 1))
    response_file="${iter_dir}/${phase}-checkpoint-attempt-${attempts}.body"
    status_file="${iter_dir}/${phase}-checkpoint-attempt-${attempts}.status"
    if checkpoint_once "$response_file" "$status_file"; then
      event "$event_file" "${phase}_checkpoint_success" "$(now_ns)" "attempt=$attempts active_holds=$(active_holds)"
      printf '%s %s success\n' "$(now_ns)" "$attempts"
      return 0
    fi

    status=$(cat "$status_file")
    detail="attempt=$attempts status=$status active_holds=$(active_holds) body=$(tr '\n' ' ' < "$response_file") stderr=$(tr '\n' ' ' < "${response_file}.stderr")"
    event "$event_file" "${phase}_checkpoint_failure" "$(now_ns)" "$detail"

    if (( ($(now_ns) - start) / 1000000000 >= timeout_seconds )); then
      printf '%s %s timeout\n' "$(now_ns)" "$attempts"
      return 1
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

mkdir -p "$OUT_DIR"
RUN_ID=$(date +%Y%m%d-%H%M%S)
RUN_DIR="${OUT_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"
EVENT_FILE="${RUN_DIR}/events.jsonl"
SUMMARY_FILE="${OUT_DIR}/long-lived-drain-${RUN_ID}.csv"

cat > "$SUMMARY_FILE" <<'EOF'
run_id,hold_seconds,label_remove_ns,endpoint_removed_ns,hold_active_ns,pre_release_end_ns,hold_released_ns,post_release_checkpoint_success_ns,pre_release_checkpoint_attempts,pre_release_result,post_release_checkpoint_attempts,release_to_checkpoint_success_ms,total_label_to_checkpoint_success_ms
EOF

event "$EVENT_FILE" "experiment_start" "$(now_ns)" "hold_seconds=$HOLD_SECONDS"
reset_namespace

SERVICE_HOST="${SERVICE}.${NAMESPACE}.svc.cluster.local"
log "Waiting for Service /ready to be reachable from client"
wait_until "Service readiness from client" 60 service_request_once >/dev/null

log "Starting long-lived request through Service for ${HOLD_SECONDS}s"
kubectl exec -n "$NAMESPACE" client -- \
  curl -sS --no-buffer --connect-timeout 2 --max-time "$((HOLD_SECONDS + 20))" \
  "http://${SERVICE_HOST}/hold?seconds=${HOLD_SECONDS}" \
  >"${RUN_DIR}/hold.out" 2>"${RUN_DIR}/hold.err" &
HOLD_KUBECTL_PID=$!
event "$EVENT_FILE" "hold_request_started" "$(now_ns)" "kubectl_pid=$HOLD_KUBECTL_PID"

if ! HOLD_ACTIVE_NS=$(wait_for_active_holds 1 20); then
  dump_hold_client_state
  exit 1
fi
event "$EVENT_FILE" "hold_active" "$HOLD_ACTIVE_NS" "active_holds=$(active_holds)"

log "Removing $SOURCE_POD from Service selector"
LABEL_REMOVE_NS=$(now_ns)
kubectl label pod "$SOURCE_POD" app- -n "$NAMESPACE" --overwrite
event "$EVENT_FILE" "label_removed" "$LABEL_REMOVE_NS" ""

ENDPOINT_REMOVED_NS=$(wait_until "source endpoint removal" 60 source_endpoint_removed)
event "$EVENT_FILE" "source_endpoint_removed" "$ENDPOINT_REMOVED_NS" "$(endpoint_lines)"

log "Trying checkpoint while long-lived connection is still active"
set +e
read -r PRE_RELEASE_END_NS PRE_RELEASE_ATTEMPTS PRE_RELEASE_RESULT < <(
  try_checkpoint_for_window pre_release "$INITIAL_CHECKPOINT_WINDOW_SECONDS" "$RUN_DIR" "$EVENT_FILE"
)
PRE_RELEASE_RC=$?
set -e

log "Releasing long-lived request"
kill "$HOLD_KUBECTL_PID" 2>/dev/null || true
wait "$HOLD_KUBECTL_PID" 2>/dev/null || true
HOLD_RELEASED_NS=$(wait_for_active_holds 0 30)
event "$EVENT_FILE" "hold_released" "$HOLD_RELEASED_NS" "pre_release_rc=$PRE_RELEASE_RC"

log "Trying checkpoint after the long-lived connection is gone"
read -r POST_RELEASE_CHECKPOINT_SUCCESS_NS POST_RELEASE_ATTEMPTS POST_RELEASE_RESULT < <(
  try_checkpoint_for_window post_release "$POST_RELEASE_CHECKPOINT_TIMEOUT_SECONDS" "$RUN_DIR" "$EVENT_FILE"
)

kubectl get pod -n "$NAMESPACE" -o wide > "${RUN_DIR}/pods.txt"
kubectl get endpointslice -n "$NAMESPACE" \
  -l "kubernetes.io/service-name=$SERVICE" \
  -o yaml > "${RUN_DIR}/endpointslice.yaml"
kubectl get events -n "$NAMESPACE" \
  --sort-by=.metadata.creationTimestamp > "${RUN_DIR}/k8s-events.txt"

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$RUN_ID" \
  "$HOLD_SECONDS" \
  "$LABEL_REMOVE_NS" \
  "$ENDPOINT_REMOVED_NS" \
  "$HOLD_ACTIVE_NS" \
  "$PRE_RELEASE_END_NS" \
  "$HOLD_RELEASED_NS" \
  "$POST_RELEASE_CHECKPOINT_SUCCESS_NS" \
  "$PRE_RELEASE_ATTEMPTS" \
  "$PRE_RELEASE_RESULT" \
  "$POST_RELEASE_ATTEMPTS" \
  "$(ns_to_ms "$HOLD_RELEASED_NS" "$POST_RELEASE_CHECKPOINT_SUCCESS_NS")" \
  "$(ns_to_ms "$LABEL_REMOVE_NS" "$POST_RELEASE_CHECKPOINT_SUCCESS_NS")" >> "$SUMMARY_FILE"

if [[ "$PRE_RELEASE_RESULT" == "timeout" && "$POST_RELEASE_RESULT" == "success" ]]; then
  log "Confirmed: checkpoint was blocked while the long-lived connection was active, then succeeded after release."
else
  log "Result needs inspection: pre_release=$PRE_RELEASE_RESULT post_release=$POST_RELEASE_RESULT"
fi

if [[ "$CLEANUP_AFTER" == "1" ]]; then
  log "Deleting namespace $NAMESPACE"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
fi

log "Wrote summary to $SUMMARY_FILE"
log "Wrote details to $RUN_DIR"
