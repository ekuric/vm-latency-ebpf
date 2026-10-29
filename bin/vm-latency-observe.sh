#!/usr/bin/env bash
# Deploy a privileged node-local Job that measures the CNV VM latency stack
# (block I/O + QEMU run-queue + KVM exit + host net + classic cachestat/biosnoop/runqlat
#  [+ optional guest ping]) for one VMI.
#
# Usage:
#   ./bin/vm-latency-observe.sh -n NAMESPACE -vmi VMI_NAME [--duration 60]
#   ./bin/vm-latency-observe.sh -n NAMESPACE -vm VM_NAME [--duration 60]
#
# Options:
#   --image IMAGE         container image with bpftrace (default: fedora:41)
#   --keep                do not delete Job/ConfigMap after completion
#   --namespace-obs NS    namespace for the observer Job (default: same as VMI ns)
#   --ttl SECONDS         Job ttlSecondsAfterFinished (default: 600)
#   --out-dir DIR         save streamed observer logs under DIR (default: ../results)
#   --ping-guest          also ICMP ping guest IPs (hostNetwork)
#   --guest-ip IP         override/add guest IP for ping
#   --no-classic-tools    skip [5] cachestat / [6] biosnoop / [7] host runqlat
#   --dry-run             print manifests only

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC="${OC:-oc}"
NAMESPACE=""
VMI_NAME=""
VM_NAME=""
DURATION=30
IMAGE="${BPFTRACE_IMAGE:-registry.fedoraproject.org/fedora:41}"
KEEP=0
OBS_NS=""
TTL=600
DRY_RUN=0
PING_GUEST=0
CLASSIC_TOOLS=1
GUEST_IP_OVERRIDE=""
OUT_DIR="${ROOT}/results"
SA_NAME="vm-latency-observer"

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \?//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    -vmi) VMI_NAME="${2:-}"; shift 2 ;;
    -vm) VM_NAME="${2:-}"; shift 2 ;;
    --duration) DURATION="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --namespace-obs) OBS_NS="${2:-}"; shift 2 ;;
    --ttl) TTL="${2:-}"; shift 2 ;;
    --ping-guest) PING_GUEST=1; shift ;;
    --guest-ip) GUEST_IP_OVERRIDE="${GUEST_IP_OVERRIDE:+$GUEST_IP_OVERRIDE,}${2:-}"; shift 2 ;;
    --no-classic-tools) CLASSIC_TOOLS=0; shift ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$NAMESPACE" ]] || usage
[[ -n "$VMI_NAME" || -n "$VM_NAME" ]] || usage
OBS_NS="${OBS_NS:-$NAMESPACE}"

RESOLVE=("${ROOT}/bin/resolve-vmi.sh" -n "$NAMESPACE")
if [[ -n "$VMI_NAME" ]]; then
  RESOLVE+=(-vmi "$VMI_NAME")
else
  RESOLVE+=(-vm "$VM_NAME")
fi

echo "resolving VMI..."
RESOLVED="$("${RESOLVE[@]}")"
echo "$RESOLVED"
# shellcheck disable=SC1090
source <(echo "$RESOLVED" | sed 's/^/export /')

if [[ -n "$GUEST_IP_OVERRIDE" ]]; then
  GUEST_IPS="$GUEST_IP_OVERRIDE"
fi
GUEST_IPS="${GUEST_IPS:-}"

HOST_NETWORK="false"
DNS_POLICY="ClusterFirst"
if [[ "$PING_GUEST" -eq 1 ]]; then
  HOST_NETWORK="true"
  DNS_POLICY="ClusterFirstWithHostNet"
  if [[ -z "$GUEST_IPS" ]]; then
    echo "warning: --ping-guest set but no GUEST_IPS from VMI status; pass --guest-ip" >&2
  fi
fi

JOB_TS="$(date -u +%Y%m%d%H%M%S)"
JOB_NAME="vm-lat-${VMI_NAME}-${JOB_TS}"
JOB_NAME="$(echo "$JOB_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-63 | sed 's/-$//')"
CM_NAME="${JOB_NAME}-tools"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

"$OC" create configmap "$CM_NAME" \
  -n "$OBS_NS" \
  --from-file="${ROOT}/bpf" \
  --dry-run=client -o json \
  | VMI_NAME="$VMI_NAME" python3 -c '
import json, os, sys
cm = json.load(sys.stdin)
cm.setdefault("metadata", {}).setdefault("labels", {})
cm["metadata"]["labels"]["app"] = "vm-latency-observer"
cm["metadata"]["labels"]["vmi"] = os.environ["VMI_NAME"]
json.dump(cm, sys.stdout)
' >"$WORKDIR/cm.json"

sed "s/__NAMESPACE__/${OBS_NS}/g" "${ROOT}/deploy/rbac.yaml" >"$WORKDIR/rbac.yaml"

# Escape commas in GUEST_IPS for sed safety — use a different delimiter and escape &
GUEST_IPS_SED="${GUEST_IPS//&/\\&}"

sed \
  -e "s/__NAMESPACE__/${OBS_NS}/g" \
  -e "s/__JOB_NAME__/${JOB_NAME}/g" \
  -e "s/__NODE_NAME__/${NODE_NAME}/g" \
  -e "s/__SA_NAME__/${SA_NAME}/g" \
  -e "s|__IMAGE__|${IMAGE}|g" \
  -e "s/__DURATION__/${DURATION}/g" \
  -e "s/__VMI_NAME__/${VMI_NAME}/g" \
  -e "s/__QEMU_GUEST_NAME__/${QEMU_GUEST_NAME}/g" \
  -e "s/__VIRT_LAUNCHER_UID__/${VIRT_LAUNCHER_UID}/g" \
  -e "s/__VIRT_LAUNCHER_POD__/${VIRT_LAUNCHER_POD}/g" \
  -e "s/__CM_NAME__/${CM_NAME}/g" \
  -e "s/__TTL_SECONDS__/${TTL}/g" \
  -e "s/__PING_GUEST__/${PING_GUEST}/g" \
  -e "s/__CLASSIC_TOOLS__/${CLASSIC_TOOLS}/g" \
  -e "s/__GUEST_IPS__/${GUEST_IPS_SED}/g" \
  -e "s/__HOST_NETWORK__/${HOST_NETWORK}/g" \
  -e "s/__DNS_POLICY__/${DNS_POLICY}/g" \
  "${ROOT}/deploy/observer-job.yaml" >"$WORKDIR/job.yaml"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "--- dry-run manifests ---"
  cat "$WORKDIR/rbac.yaml"
  echo "---"
  cat "$WORKDIR/cm.json"
  echo "---"
  cat "$WORKDIR/job.yaml"
  exit 0
fi

echo "ensuring SCC binding (ignore errors if already set / not cluster-admin)..."
# On OCP, the built-in 'privileged' SCC is what reliably grants hostPID + spc_t
# so the observer can see QEMU in host /proc. Bind it first.
"$OC" adm policy add-scc-to-user privileged \
  -z "$SA_NAME" -n "$OBS_NS" 2>/dev/null || \
  echo "note: could not bind 'privileged' SCC to SA ${OBS_NS}/${SA_NAME} (need cluster-admin)"
"$OC" apply -f "${ROOT}/deploy/scc-vm-latency-observer.yaml" 2>/dev/null || true
"$OC" adm policy add-scc-to-user vm-latency-observer \
  -z "$SA_NAME" -n "$OBS_NS" 2>/dev/null || true

echo "applying RBAC + ConfigMap + Job in ${OBS_NS}..."
"$OC" apply -f "$WORKDIR/rbac.yaml"
"$OC" apply -f "$WORKDIR/cm.json"
"$OC" apply -f "$WORKDIR/job.yaml"

PROBE_LAYERS=4
if [[ "$CLASSIC_TOOLS" == "1" ]]; then
  PROBE_LAYERS=7
fi
echo "expect: ~$((DURATION * PROBE_LAYERS))s probe windows + bpftrace attach (often +1–2 min/layer)"
echo "        classic_tools=${CLASSIC_TOOLS} → use --no-classic-tools for ~$((DURATION * 4))s core-only"
echo "        ConfigMap tools are used (no image rebuild required for .bt/.sh changes)"

cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "keeping Job/${JOB_NAME} and ConfigMap/${CM_NAME} in ${OBS_NS}"
    return 0
  fi
  echo "cleaning up Job and ConfigMap..."
  "$OC" delete job "$JOB_NAME" -n "$OBS_NS" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  "$OC" delete configmap "$CM_NAME" -n "$OBS_NS" --ignore-not-found=true >/dev/null 2>&1 || true
}

trap 'cleanup; rm -rf "$WORKDIR"' EXIT

echo "waiting for observer pod..."
POD=""
for _ in $(seq 1 60); do
  POD="$("$OC" get pod -n "$OBS_NS" -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$POD" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "$POD" ]]; then
  echo "error: observer pod not created; describe job:" >&2
  "$OC" describe job -n "$OBS_NS" "$JOB_NAME" >&2 || true
  exit 1
fi

echo "streaming logs from pod/${POD} ..."
mkdir -p "$OUT_DIR"
LOG_FILE="${OUT_DIR}/${VMI_NAME}-$(date -u +%Y%m%dT%H%M%SZ)-raw.txt"
{
  echo "# CNV VM latency stack raw output"
  echo "# VMI: ${NAMESPACE}/${VMI_NAME}"
  echo "# node: ${NODE_NAME}"
  echo "# job: ${JOB_NAME}"
  echo "# pod: ${POD}"
  echo "# image: ${IMAGE}"
  echo "# saved: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "#"
} >"$LOG_FILE"
echo "saving observer logs to ${LOG_FILE}"

"$OC" wait -n "$OBS_NS" --for=condition=Ready "pod/${POD}" --timeout=120s 2>/dev/null || true
"$OC" logs -n "$OBS_NS" -f "$POD" -c observer 2>&1 | tee -a "$LOG_FILE" || {
  echo "log stream ended; final status:" >&2
  "$OC" get pod -n "$OBS_NS" "$POD" -o wide >&2 || true
  "$OC" logs -n "$OBS_NS" "$POD" -c observer --tail=200 2>&1 | tee -a "$LOG_FILE" >&2 || true
}

# Core probes [1]-[4] (+ optional [5]-[7] classic tools + optional ping).
PROBE_LAYERS=4
if [[ "$CLASSIC_TOOLS" == "1" ]]; then
  PROBE_LAYERS=7
fi
WAIT_TIMEOUT=$((DURATION * PROBE_LAYERS + 360))
"$OC" wait -n "$OBS_NS" --for=condition=complete "job/${JOB_NAME}" --timeout="${WAIT_TIMEOUT}s" 2>/dev/null || \
  "$OC" wait -n "$OBS_NS" --for=condition=failed "job/${JOB_NAME}" --timeout=30s 2>/dev/null || true

echo
echo "observer finished (job=${JOB_NAME})."
echo "raw log saved: ${LOG_FILE}"
