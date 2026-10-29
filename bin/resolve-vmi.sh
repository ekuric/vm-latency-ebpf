#!/usr/bin/env bash
# Resolve a CNV/KubeVirt VMI (or VM) to node + virt-launcher pod metadata.
# QEMU TGID / disk maj:min discovery happens on-node inside the observer (hostPID).
#
# Usage:
#   resolve-vmi.sh -n NAMESPACE -vmi VMI_NAME
#   resolve-vmi.sh -n NAMESPACE -vm VM_NAME
#
# Prints KEY=VALUE lines on stdout for consumption by vm-latency-observe.sh.

set -euo pipefail

NAMESPACE=""
VMI_NAME=""
VM_NAME=""
OC="${OC:-oc}"

usage() {
  cat <<'EOF'
Usage:
  resolve-vmi.sh -n NAMESPACE -vmi VMI_NAME
  resolve-vmi.sh -n NAMESPACE -vm VM_NAME

Environment:
  OC   oc/kubectl binary (default: oc)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    -vmi) VMI_NAME="${2:-}"; shift 2 ;;
    -vm) VM_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$NAMESPACE" ]] || usage
[[ -n "$VMI_NAME" || -n "$VM_NAME" ]] || usage

if ! command -v "$OC" >/dev/null 2>&1; then
  echo "error: '$OC' not found in PATH" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

TMPDIR_RESOLVE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RESOLVE"' EXIT

if [[ -z "$VMI_NAME" && -n "$VM_NAME" ]]; then
  "$OC" get vmi -n "$NAMESPACE" -o json >"$TMPDIR_RESOLVE/vmis.json"
  VMI_NAME="$(python3 - "$TMPDIR_RESOLVE/vmis.json" "$VM_NAME" "$NAMESPACE" <<'PY'
import json, sys
path, want, ns = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
for i in data.get("items", []):
    md = i.get("metadata", {})
    owners = md.get("ownerReferences") or []
    labels = md.get("labels") or {}
    if any(o.get("kind") == "VirtualMachine" and o.get("name") == want for o in owners):
        print(md["name"])
        sys.exit(0)
    if labels.get("vm.kubevirt.io/name") == want:
        print(md["name"])
        sys.exit(0)
for i in data.get("items", []):
    if i.get("metadata", {}).get("name") == want:
        print(want)
        sys.exit(0)
sys.stderr.write(f"error: no VMI found for VM {want} in ns {ns}\n")
sys.exit(1)
PY
)"
fi

"$OC" get vmi -n "$NAMESPACE" "$VMI_NAME" -o json >"$TMPDIR_RESOLVE/vmi.json"

python3 - "$TMPDIR_RESOLVE/vmi.json" >"$TMPDIR_RESOLVE/vmi.env" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    v = json.load(f)
md = v.get("metadata", {})
st = v.get("status", {})
name = md.get("name", "")
ns = md.get("namespace", "")
print(f"VMI_NAME={name}")
print(f"NAMESPACE={ns}")
print(f"VMI_UID={md.get('uid', '')}")
print(f"NODE_NAME={st.get('nodeName') or ''}")
print(f"VMI_PHASE={st.get('phase') or ''}")
print(f"QEMU_GUEST_NAME={ns}_{name}")  # CNV/KubeVirt: namespace_vmi (e.g. ekuric_winx-1)
# Guest IPs from VMI status (for optional synthetic RTT / --ping-guest)
ips = []
for iface in st.get("interfaces") or []:
    ip = iface.get("ipAddress") or ""
    if ip and ip not in ips:
        ips.append(ip)
    for extra in iface.get("ipAddresses") or []:
        if extra and extra not in ips:
            ips.append(extra)
print(f"GUEST_IPS={','.join(ips)}")
PY

# shellcheck disable=SC1090
source "$TMPDIR_RESOLVE/vmi.env"

if [[ -z "${NODE_NAME:-}" ]]; then
  echo "error: VMI ${NAMESPACE}/${VMI_NAME} has no status.nodeName (phase=${VMI_PHASE:-unknown})" >&2
  exit 1
fi

if ! "$OC" get pod -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,vmi.kubevirt.io/id=${VMI_NAME}" \
  -o json >"$TMPDIR_RESOLVE/pods.json" 2>/dev/null; then
  echo '{"items":[]}' >"$TMPDIR_RESOLVE/pods.json"
fi

python3 - "$TMPDIR_RESOLVE/pods.json" "$VMI_NAME" "${VMI_UID}" "$NAMESPACE" "$NODE_NAME" "$OC" \
  >"$TMPDIR_RESOLVE/pod.env" <<'PY'
import json, sys, subprocess

pods_path, vmi, uid, ns, node, oc = sys.argv[1:7]
with open(pods_path) as f:
    data = json.load(f)
items = data.get("items") or []

def match(p):
    md = p.get("metadata", {})
    labels = md.get("labels") or {}
    if labels.get("vmi.kubevirt.io/id") == vmi or labels.get("kubevirt.io/domain") == vmi:
        return True
    for o in md.get("ownerReferences") or []:
        if o.get("kind") == "VirtualMachineInstance" and (o.get("name") == vmi or o.get("uid") == uid):
            return True
    return False

chosen = next((p for p in items if match(p)), None)

if chosen is None:
    raw = subprocess.check_output(
        [oc, "get", "pod", "-n", ns, "-l", "kubevirt.io=virt-launcher",
         "--field-selector", f"spec.nodeName={node}", "-o", "json"],
        text=True,
    )
    data = json.loads(raw)
    items = data.get("items") or []
    chosen = next((p for p in items if match(p)), None)

if chosen is None:
    sys.stderr.write(f"error: virt-launcher pod not found for VMI {vmi}\n")
    sys.exit(1)

md = chosen["metadata"]
st = chosen.get("status", {})
print(f"VIRT_LAUNCHER_POD={md['name']}")
print(f"VIRT_LAUNCHER_UID={md.get('uid', '')}")
print(f"VIRT_LAUNCHER_PHASE={st.get('phase', '')}")
PY

# shellcheck disable=SC1090
source "$TMPDIR_RESOLVE/pod.env"

cat <<EOF
VMI_NAME=${VMI_NAME}
NAMESPACE=${NAMESPACE}
VMI_UID=${VMI_UID}
NODE_NAME=${NODE_NAME}
VMI_PHASE=${VMI_PHASE}
QEMU_GUEST_NAME=${QEMU_GUEST_NAME}
GUEST_IPS=${GUEST_IPS:-}
VIRT_LAUNCHER_POD=${VIRT_LAUNCHER_POD}
VIRT_LAUNCHER_UID=${VIRT_LAUNCHER_UID}
VIRT_LAUNCHER_PHASE=${VIRT_LAUNCHER_PHASE}
EOF
