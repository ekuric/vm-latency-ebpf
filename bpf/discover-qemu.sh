#!/usr/bin/env bash
# On-node discovery: find QEMU TGID and backing disk maj:min for a CNV VM.
# Requires hostPID (observer sees host /proc).
#
# Env:
#   QEMU_GUEST_NAME      e.g. winx-1_ekuric
#   VMI_NAME / NAMESPACE
#   VIRT_LAUNCHER_UID    virt-launcher pod UID (best cgroup match)
#   VIRT_LAUNCHER_POD    virt-launcher pod name (fallback)
# Prints KEY=VALUE and writes TARGETS_ENV (default /tmp/vm-latency-targets.env)

set -euo pipefail

# QEMU_GUEST_NAME e.g. ekuric_winx-1 (CNV: namespace_vmi)
QEMU_GUEST_NAME="${QEMU_GUEST_NAME:-}"
VMI_NAME="${VMI_NAME:-}"
NAMESPACE="${NAMESPACE:-}"
VIRT_LAUNCHER_UID="${VIRT_LAUNCHER_UID:-}"
VIRT_LAUNCHER_POD="${VIRT_LAUNCHER_POD:-}"
TARGETS_ENV="${TARGETS_ENV:-/tmp/vm-latency-targets.env}"
DEBUG_DISCOVER="${DEBUG_DISCOVER:-1}"

if [[ -z "$QEMU_GUEST_NAME" && -n "$VMI_NAME" && -n "$NAMESPACE" ]]; then
  QEMU_GUEST_NAME="${NAMESPACE}_${VMI_NAME}"
fi

# Alternate order used by some docs / older codepaths
QEMU_GUEST_NAME_ALT=""
if [[ -n "$VMI_NAME" && -n "$NAMESPACE" ]]; then
  QEMU_GUEST_NAME_ALT="${VMI_NAME}_${NAMESPACE}"
fi

if [[ -z "$QEMU_GUEST_NAME" && -z "$VMI_NAME" ]]; then
  echo "error: QEMU_GUEST_NAME or VMI_NAME required" >&2
  exit 1
fi

hex_to_dec() { printf '%d' "0x${1}"; }

mkdev() {
  local maj="$1" min="$2"
  echo $(( (maj << 20) | min ))
}

path_to_majmin() {
  local path="$1"
  local maj_hex min_hex maj min src

  if [[ -b "$path" ]]; then
    maj_hex="$(stat -c '%t' "$path")"
    min_hex="$(stat -c '%T' "$path")"
    maj="$(hex_to_dec "$maj_hex")"
    min="$(hex_to_dec "$min_hex")"
    echo "${maj}:${min}"
    return 0
  fi

  if [[ -e "$path" ]]; then
    src="$(findmnt -n -o SOURCE --target "$path" 2>/dev/null || true)"
    if [[ -z "$src" ]]; then
      src="$(df -P "$path" 2>/dev/null | awk 'NR==2{print $1}')"
    fi
    if [[ -n "$src" && ! -b "$src" && -e "$src" ]]; then
      src="$(readlink -f "$src" 2>/dev/null || echo "$src")"
    fi
    if [[ -n "$src" && -b "$src" ]]; then
      maj_hex="$(stat -c '%t' "$src")"
      min_hex="$(stat -c '%T' "$src")"
      maj="$(hex_to_dec "$maj_hex")"
      min="$(hex_to_dec "$min_hex")"
      echo "${maj}:${min}"
      return 0
    fi
  fi
  return 1
}

is_qemu_cmdline() {
  local cmd="$1"
  # Reject virt-launcher wrappers (they contain --qemu-timeout and fooled substring match)
  case "$cmd" in
    *virt-launcher*|*virtqemud*|*libvirtd*) return 1 ;;
  esac
  # Real emulator binaries only — do NOT match bare "qemu" (hits --qemu-timeout)
  case "$cmd" in
    *qemu-kvm*|*qemu-system-*|*qemu_system_*|*/libexec/qemu*|*/usr/bin/qemu-system*|*/usr/libexec/qemu*)
      return 0
      ;;
  esac
  return 1
}

cmdline_of() {
  tr '\0' ' ' <"$1/cmdline" 2>/dev/null || true
}

# Prefer thread-group leader
normalize_tgid() {
  local pid="$1" real
  if [[ -r "/proc/${pid}/status" ]]; then
    real="$(awk '/^Tgid:/{print $2}' "/proc/${pid}/status")"
    [[ -n "$real" ]] && echo "$real" && return 0
  fi
  echo "$pid"
}

# Match strategies against a qemu cmdline
cmdline_matches_vm() {
  local cmd="$1"
  local g
  # CNV: guest=<namespace>_<vmi>  (e.g. guest=ekuric_winx-1)
  for g in "$QEMU_GUEST_NAME" "$QEMU_GUEST_NAME_ALT"; do
    [[ -n "$g" ]] || continue
    [[ "$cmd" == *guest="${g}"* ]] && return 0
    [[ "$cmd" == *guest=${g},* ]] && return 0
    [[ "$cmd" == *guest=${g}\ * ]] && return 0
  done
  if [[ -n "$VMI_NAME" && -n "$NAMESPACE" ]]; then
    [[ "$cmd" == *guest="${NAMESPACE}_${VMI_NAME}"* ]] && return 0
    [[ "$cmd" == *guest=${NAMESPACE}_${VMI_NAME},* ]] && return 0
    [[ "$cmd" == *guest="${VMI_NAME}_${NAMESPACE}"* ]] && return 0
    [[ "$cmd" == *guest=${VMI_NAME}_${NAMESPACE},* ]] && return 0
  fi
  if [[ -n "$VMI_NAME" ]]; then
    [[ "$cmd" == *guest=*"${VMI_NAME}"* ]] && return 0
  fi
  return 1
}

# After matching a candidate, if it is not the emulator, search children / same cgroup for qemu-kvm
resolve_emulator_tgid() {
  local cand="$1"
  local cmd child tgid cgroup pid
  cmd="$(cmdline_of "/proc/${cand}")"
  if is_qemu_cmdline "$cmd"; then
    normalize_tgid "$cand"
    return 0
  fi
  # Children of this PID (virt-launcher-monitor → qemu)
  if [[ -r "/proc/${cand}/task/${cand}/children" ]]; then
    for child in $(cat "/proc/${cand}/task/${cand}/children" 2>/dev/null); do
      cmd="$(cmdline_of "/proc/${child}")"
      if is_qemu_cmdline "$cmd"; then
        normalize_tgid "$child"
        return 0
      fi
    done
  fi
  # Same cgroup: any qemu-kvm
  cgroup="$(cat "/proc/${cand}/cgroup" 2>/dev/null || true)"
  if [[ -n "$cgroup" && -n "$VIRT_LAUNCHER_UID" ]]; then
    for pid in /proc/[0-9]*; do
      [[ -r "$pid/cgroup" ]] || continue
      grep -q "$VIRT_LAUNCHER_UID" "$pid/cgroup" 2>/dev/null || continue
      cmd="$(cmdline_of "$pid")"
      is_qemu_cmdline "$cmd" || continue
      normalize_tgid "$(basename "$pid")"
      return 0
    done
  fi
  return 1
}

# Strongest signal on OCP: cgroup path contains virt-launcher pod UID
find_qemu_by_pod_uid() {
  local uid="$1"
  local pid cmd tgid
  [[ -n "$uid" ]] || return 1

  for pid in /proc/[0-9]*; do
    [[ -r "$pid/cgroup" ]] || continue
    grep -q "$uid" "$pid/cgroup" 2>/dev/null || continue
    [[ -r "$pid/cmdline" ]] || continue
    cmd="$(cmdline_of "$pid")"
    is_qemu_cmdline "$cmd" || continue
    tgid="$(normalize_tgid "$(basename "$pid")")"
    echo "$tgid"
    return 0
  done
  return 1
}

find_qemu_by_cmdline() {
  local pid cmd tgid
  for pid in /proc/[0-9]*; do
    [[ -r "$pid/cmdline" ]] || continue
    cmd="$(cmdline_of "$pid")"
    is_qemu_cmdline "$cmd" || continue
    if cmdline_matches_vm "$cmd"; then
      tgid="$(normalize_tgid "$(basename "$pid")")"
      echo "$tgid"
      return 0
    fi
  done
  return 1
}

# Last resort: qemu-kvm cmdline contains VMI name (never virt-launcher)
find_qemu_by_vmi_string() {
  local pid cmd tgid
  [[ -n "$VMI_NAME" ]] || return 1
  for pid in /proc/[0-9]*; do
    [[ -r "$pid/cmdline" ]] || continue
    cmd="$(cmdline_of "$pid")"
    is_qemu_cmdline "$cmd" || continue
    if [[ "$cmd" == *"${VMI_NAME}"* ]]; then
      tgid="$(normalize_tgid "$(basename "$pid")")"
      echo "$tgid"
      return 0
    fi
  done
  return 1
}

dump_qemu_diagnostics() {
  local proc_count qemu_count=0
  proc_count="$(find /proc -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | wc -l | tr -d ' ')"
  echo "diagnostic: /proc PID dirs visible=${proc_count}" >&2
  if [[ "${proc_count:-0}" -lt 80 ]]; then
    echo "diagnostic: LOW process count — hostPID:true is likely NOT effective (SCC/SA)." >&2
    echo "diagnostic: check: oc get pod <observer> -o jsonpath='{.metadata.annotations.openshift\\.io/scc}'" >&2
  fi
  echo "diagnostic: qemu-kvm/qemu-system processes on this node (truncated cmdline):" >&2
  local pid cmd
  for pid in /proc/[0-9]*; do
    [[ -r "$pid/cmdline" ]] || continue
    cmd="$(cmdline_of "$pid")"
    is_qemu_cmdline "$cmd" || continue
    qemu_count=$((qemu_count + 1))
    echo "  pid=$(basename "$pid") cmd=$(echo "$cmd" | cut -c1-200)" >&2
    if [[ "$qemu_count" -ge 15 ]]; then
      echo "  ... truncated ..." >&2
      break
    fi
  done
  if [[ "$qemu_count" -eq 0 ]]; then
    echo "diagnostic: zero qemu-kvm processes visible — wrong node, no hostPID, or SELinux." >&2
    echo "diagnostic: also listing virt-launcher hits for VMI (should NOT be used as QEMU_TGID):" >&2
    for pid in /proc/[0-9]*; do
      [[ -r "$pid/cmdline" ]] || continue
      cmd="$(cmdline_of "$pid")"
      [[ "$cmd" == *virt-launcher* && "$cmd" == *"${VMI_NAME}"* ]] || continue
      echo "  pid=$(basename "$pid") cmd=$(echo "$cmd" | cut -c1-160)" >&2
    done
  fi
  if [[ -n "$VIRT_LAUNCHER_UID" ]]; then
    local hits
    hits="$(grep -l "$VIRT_LAUNCHER_UID" /proc/*/cgroup 2>/dev/null | wc -l | tr -d ' ')"
    echo "diagnostic: cgroup hits for VIRT_LAUNCHER_UID=${VIRT_LAUNCHER_UID}: ${hits}" >&2
  fi
}

PROC_COUNT="$(find /proc -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | wc -l | tr -d ' ')"
echo "discover: visible host PIDs=${PROC_COUNT} guest=${QEMU_GUEST_NAME} vmi=${VMI_NAME} launcher_uid=${VIRT_LAUNCHER_UID:-none}"

QEMU_TGID=""
MATCH_METHOD=""

if [[ -n "$VIRT_LAUNCHER_UID" ]]; then
  if QEMU_TGID="$(find_qemu_by_pod_uid "$VIRT_LAUNCHER_UID")"; then
    MATCH_METHOD="cgroup_pod_uid"
  fi
fi

if [[ -z "$QEMU_TGID" ]]; then
  if QEMU_TGID="$(find_qemu_by_cmdline)"; then
    MATCH_METHOD="cmdline_guest_name"
  fi
fi

if [[ -z "$QEMU_TGID" ]]; then
  if QEMU_TGID="$(find_qemu_by_vmi_string)"; then
    MATCH_METHOD="cmdline_vmi_substring"
  fi
fi

# Fallback: locate virt-launcher-monitor for this VMI, then find qemu-kvm child/cgroup peer
if [[ -z "$QEMU_TGID" && -n "$VMI_NAME" ]]; then
  for pid in /proc/[0-9]*; do
    [[ -r "$pid/cmdline" ]] || continue
    cmd="$(cmdline_of "$pid")"
    [[ "$cmd" == *virt-launcher-monitor* ]] || continue
    [[ "$cmd" == *"--name ${VMI_NAME}"* || "$cmd" == *" --name ${VMI_NAME} "* ]] || continue
    if QEMU_TGID="$(resolve_emulator_tgid "$(basename "$pid")")"; then
      MATCH_METHOD="monitor_child_or_cgroup"
      break
    fi
  done
fi

if [[ -z "$QEMU_TGID" ]]; then
  echo "error: QEMU process not found for guest=${QEMU_GUEST_NAME:-} vmi=${VMI_NAME:-}" >&2
  echo "hint: ensure observer has hostPID:true, privileged SCC, and nodeName=${NODE_NAME:-VMI node}" >&2
  dump_qemu_diagnostics
  exit 1
fi

echo "discover: matched qemu_tgid=${QEMU_TGID} via ${MATCH_METHOD}"

QEMU_COMM="$(cat "/proc/${QEMU_TGID}/comm" 2>/dev/null || echo qemu)"
THREAD_COUNT="$(find "/proc/${QEMU_TGID}/task" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"

# Classify QEMU threads for run-queue split (vCPU vs IOThread vs other).
# TASK_COMM_LEN is 15 chars; names are matched with prefixes / substrings.
# Typical: "CPU 0/KVM", "CPU 10/KVM", "IO iothread0", "iothread1", "qemu-kvm", ...
TMP_VCPU="$(mktemp)"
TMP_IOTH="$(mktemp)"
TMP_OTHER="$(mktemp)"
classify_qemu_thread_comm() {
  local comm="$1"
  case "$comm" in
    CPU\ *|CPU*/KVM*|CPU*/kvm*)
      echo vcpu
      ;;
    *iothread*|IO\ *)
      # "IO iothreadN" often truncates under TASK_COMM_LEN
      echo iothread
      ;;
    *)
      echo other
      ;;
  esac
}
if [[ -d "/proc/${QEMU_TGID}/task" ]]; then
  for tid_dir in "/proc/${QEMU_TGID}/task/"*; do
    [[ -r "${tid_dir}/comm" ]] || continue
    tid="$(basename "$tid_dir")"
    tcomm="$(tr -d '\0' <"${tid_dir}/comm" 2>/dev/null || true)"
    role="$(classify_qemu_thread_comm "$tcomm")"
    case "$role" in
      vcpu) echo "$tid" >>"$TMP_VCPU" ;;
      iothread) echo "$tid" >>"$TMP_IOTH" ;;
      *) echo "$tid" >>"$TMP_OTHER" ;;
    esac
    if [[ "${DEBUG_DISCOVER}" == "1" ]]; then
      echo "discover: thread tid=${tid} comm='${tcomm}' role=${role}" >&2
    fi
  done
fi
VCPU_TIDS="$(sort -nu "$TMP_VCPU" 2>/dev/null | paste -sd, - | tr -d '\n')"
IOTHREAD_TIDS="$(sort -nu "$TMP_IOTH" 2>/dev/null | paste -sd, - | tr -d '\n')"
OTHER_QEMU_TIDS="$(sort -nu "$TMP_OTHER" 2>/dev/null | paste -sd, - | tr -d '\n')"
VCPU_COUNT="$(wc -l <"$TMP_VCPU" 2>/dev/null | tr -d ' ')"
IOTHREAD_COUNT="$(wc -l <"$TMP_IOTH" 2>/dev/null | tr -d ' ')"
OTHER_QEMU_COUNT="$(wc -l <"$TMP_OTHER" 2>/dev/null | tr -d ' ')"
VCPU_COUNT="${VCPU_COUNT:-0}"
IOTHREAD_COUNT="${IOTHREAD_COUNT:-0}"
OTHER_QEMU_COUNT="${OTHER_QEMU_COUNT:-0}"
rm -f "$TMP_VCPU" "$TMP_IOTH" "$TMP_OTHER"
echo "discover: thread roles vcpu=${VCPU_COUNT} iothread=${IOTHREAD_COUNT} other=${OTHER_QEMU_COUNT}"

if [[ "${DEBUG_DISCOVER}" == "1" ]]; then
  echo "discover: cmdline=$(cmdline_of /proc/${QEMU_TGID} | cut -c1-240)"
fi

TMP_DISKS="$(mktemp)"
TMP_SKIPPED_DISKS="$(mktemp)"
FILE_BACKED_WARN=0
trap 'rm -f "$TMP_DISKS" "$TMP_SKIPPED_DISKS"' EXIT

add_dev() {
  local d="$1"
  [[ -n "$d" ]] || return 0
  grep -qxF "$d" "$TMP_DISKS" 2>/dev/null || echo "$d" >>"$TMP_DISKS"
}

# Cloud-init / config-drive / ISO / sysprep are not workload storage.
# Their file-backed paths often resolve to the node's root FS maj:min and pollute biolat.
is_noise_disk_path() {
  local path="$1"
  local lower
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.iso|*.iso\?*|*.iso,*) return 0 ;;
  esac
  case "$lower" in
    *cloud-init*|*cloudinit*|*nocloud*|*config-drive*|*configdrive* \
    |*sysprep*|*kubevirt-ephemeral-disks/cloud-init*|*ua-cloudinit* \
    |*/cdrom*|*device=cdrom*|*media=cdrom*)
      return 0
      ;;
  esac
  return 1
}

note_skipped_disk() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  if grep -qxF "$path" "$TMP_SKIPPED_DISKS" 2>/dev/null; then
    return 0
  fi
  echo "$path" >>"$TMP_SKIPPED_DISKS"
  echo "discover: skip noise disk path=${path}" >&2
}

# Resolve path → maj:min inside QEMU's mount namespace (paths often invisible on host)
path_to_majmin_in_qemu_mnt() {
  local path="$1"
  local out
  if [[ ! -e "/proc/${QEMU_TGID}/ns/mnt" ]] || ! command -v nsenter >/dev/null 2>&1; then
    path_to_majmin "$path"
    return $?
  fi
  out="$(nsenter --mount="/proc/${QEMU_TGID}/ns/mnt" -F bash -c '
    p="$1"
    to_majmin() {
      local node="$1" maj min
      maj=$((16#$(stat -c %t "$node")))
      min=$((16#$(stat -c %T "$node")))
      echo "${maj}:${min}"
    }
    if [[ -b "$p" ]]; then
      to_majmin "$p"
      exit 0
    fi
    if [[ -e "$p" ]]; then
      if [[ -f "$p" ]]; then
        echo FILE_BACKED >&2
      fi
      src=$(findmnt -n -o SOURCE --target "$p" 2>/dev/null || true)
      if [[ -z "$src" ]]; then
        src=$(df -P "$p" 2>/dev/null | awk "NR==2{print \$1}")
      fi
      if [[ -n "$src" && -e "$src" && ! -b "$src" ]]; then
        src=$(readlink -f "$src" 2>/dev/null || echo "$src")
      fi
      if [[ -n "$src" && -b "$src" ]]; then
        to_majmin "$src"
        exit 0
      fi
    fi
    exit 1
  ' bash "$path" 2>/tmp/vm-lat-mnt-err.$$)" || {
    rm -f /tmp/vm-lat-mnt-err.$$
    return 1
  }
  if grep -q FILE_BACKED /tmp/vm-lat-mnt-err.$$ 2>/dev/null; then
    FILE_BACKED_WARN=1
  fi
  rm -f /tmp/vm-lat-mnt-err.$$
  [[ -n "$out" ]] || return 1
  echo "$out"
}

if [[ -d "/proc/${QEMU_TGID}/fd" ]]; then
  for fd in "/proc/${QEMU_TGID}/fd/"*; do
    target="$(readlink "$fd" 2>/dev/null || true)"
    [[ -n "$target" ]] || continue
    case "$target" in
      /dev/null|/dev/zero|/dev/urandom|/dev/random|/dev/ptmx|/dev/tty|/dev/console) continue ;;
      /dev/net/*|/dev/vfio/*|/dev/kvm|/dev/shm/*|/dev/mqueue/*) continue ;;
      socket:*|pipe:*|anon_inode:*|[/]*memfd:*) continue ;;
    esac
    # Skip obvious non-disk paths
    case "$target" in
      /etc/*|/usr/*|/lib/*|/lib64/*|/proc/*|/sys/*|/dev/pts/*) continue ;;
    esac
    if is_noise_disk_path "$target"; then
      note_skipped_disk "$target"
      continue
    fi
    if d="$(path_to_majmin_in_qemu_mnt "$target" 2>/dev/null)"; then
      add_dev "$d"
    fi
  done
fi

# Parse -blockdev / -drive JSON and path args from cmdline (inside qemu mnt ns)
if [[ -r "/proc/${QEMU_TGID}/cmdline" ]]; then
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if is_noise_disk_path "$path"; then
      note_skipped_disk "$path"
      continue
    fi
    if d="$(path_to_majmin_in_qemu_mnt "$path" 2>/dev/null)"; then
      add_dev "$d"
    fi
  done < <(
    python3 - "$QEMU_TGID" <<'PY'
import re, sys
tgid = sys.argv[1]
raw = open(f"/proc/{tgid}/cmdline", "rb").read().split(b"\0")
args = [a.decode("utf-8", "replace") for a in raw if a]
paths = []
for a in args:
    # JSON blockdev/drive blobs
    for m in re.finditer(r'"(?:filename|file|path)"\s*:\s*"([^"]+)"', a):
        paths.append(m.group(1))
    if a.startswith("file="):
        paths.append(a.split("=", 1)[1].split(",")[0])
    if a.startswith("path="):
        paths.append(a.split("=", 1)[1].split(",")[0])
    if a.startswith("/") and any(x in a for x in (
        "/disk", "/dev/", ".raw", ".qcow2", "kubevirt", "persistent-volumes",
        "disk.img", "pvc", "volume",
    )):
        paths.append(a.split(",")[0])
# unique preserve order; noise filtered in bash via is_noise_disk_path
seen = set()
for p in paths:
    if p not in seen:
        seen.add(p)
        print(p)
PY
  )
fi

DISK_DEVS="$(sort -u "$TMP_DISKS" | paste -sd, - | tr -d '\n')"
DISK_MKDEV=""
while IFS=: read -r maj min; do
  [[ -n "${maj:-}" ]] || continue
  # maj/min may already be decimal from nsenter helper
  d="$(mkdev "$maj" "$min")"
  if [[ -z "$DISK_MKDEV" ]]; then
    DISK_MKDEV="$d"
  else
    DISK_MKDEV="${DISK_MKDEV},${d}"
  fi
done < <(sort -u "$TMP_DISKS")

SKIPPED_DISK_PATHS="$(paste -sd, "$TMP_SKIPPED_DISKS" 2>/dev/null | tr -d '\n' || true)"
if [[ -n "$SKIPPED_DISK_PATHS" ]]; then
  echo "discover: skipped noise disks (${SKIPPED_DISK_PATHS})" >&2
fi

if [[ -z "$DISK_DEVS" ]]; then
  echo "discover: warning: no disks resolved (tried fds + blockdev JSON in qemu mount ns)" >&2
fi
# --- Network interfaces (tap / vnet) in QEMU's netns ---
# Prefer ifindex (int) over name strings — RHEL9 bpftrace string map keys are unreliable.
TMP_IFACES="$(mktemp)"
TMP_IFIDX="$(mktemp)"
NET_NAME_COLLISION_WARN=0
NET_IFNAMES=""
NET_IFINDEXES=""
NET_IFINDEX_LIST=""

add_iface() {
  local name="$1"
  [[ -n "$name" ]] || return 0
  case "$name" in
    lo|virbr*|docker*|cni*|flannel*|cali*|ovn-k8s-mp*|genev*|vxlan*) return 0 ;;
  esac
  grep -qxF "$name" "$TMP_IFACES" 2>/dev/null || echo "$name" >>"$TMP_IFACES"
}

if [[ -r "/proc/${QEMU_TGID}/cmdline" ]]; then
  while IFS= read -r name; do
    add_iface "$name"
  done < <(
    tr '\0' '\n' <"/proc/${QEMU_TGID}/cmdline" \
      | sed -n 's/.*ifname=\([^,]*\).*/\1/p'
  )
fi

if [[ -e "/proc/${QEMU_TGID}/ns/net" ]] && command -v nsenter >/dev/null 2>&1; then
  # ip -o link: "2: tap0: <...>" — ifindex is reliable across bpftrace versions
  while IFS= read -r line; do
    idx="$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')"
    name="$(echo "$line" | awk -F': ' '{print $2}' | awk '{print $1}' | sed 's/@.*//')"
    case "$name" in
      tap*|vnet*|k6t-*)
        add_iface "$name"
        if [[ -n "$idx" && "$idx" =~ ^[0-9]+$ ]]; then
          echo "${idx}" >>"$TMP_IFIDX"
          echo "${name}=${idx}" >>"${TMP_IFIDX}.map"
        fi
        ;;
    esac
  done < <(nsenter --net="/proc/${QEMU_TGID}/ns/net" -F ip -o link show 2>/dev/null || true)
fi

while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  case "$name" in
    tap0|tap1|k6t-eth0) NET_NAME_COLLISION_WARN=1 ;;
  esac
done <"$TMP_IFACES"

NET_IFNAMES="$(paste -sd, "$TMP_IFACES" 2>/dev/null | tr -d '\n')"
NET_IFINDEX_LIST="$(sort -nu "$TMP_IFIDX" 2>/dev/null | paste -sd, - | tr -d '\n')"
if [[ -f "${TMP_IFIDX}.map" ]]; then
  NET_IFINDEXES="$(sort -u "${TMP_IFIDX}.map" | paste -sd, - | tr -d '\n')"
fi
rm -f "$TMP_IFACES" "$TMP_IFIDX" "${TMP_IFIDX}.map"

if [[ -z "$NET_IFINDEX_LIST" && -n "$NET_IFNAMES" ]]; then
  echo "discover: warning: have ifnames (${NET_IFNAMES}) but no ifindexes" >&2
fi

TMP_VHOST="$(mktemp)"
for tid_dir in /proc/[0-9]*/task/[0-9]*; do
  [[ -r "${tid_dir}/comm" ]] || continue
  comm="$(cat "${tid_dir}/comm" 2>/dev/null || true)"
  if [[ "$comm" == "vhost-${QEMU_TGID}" || "$comm" == "vhost-${QEMU_TGID}"* ]]; then
    basename "$tid_dir" >>"$TMP_VHOST"
  fi
done
VHOST_TIDS="$(sort -u "$TMP_VHOST" 2>/dev/null | paste -sd, - | tr -d '\n')"
rm -f "$TMP_VHOST"

cat >"$TARGETS_ENV" <<EOF
QEMU_TGID=${QEMU_TGID}
QEMU_COMM=${QEMU_COMM}
QEMU_GUEST_NAME=${QEMU_GUEST_NAME}
VMI_NAME=${VMI_NAME}
NAMESPACE=${NAMESPACE}
THREAD_COUNT=${THREAD_COUNT}
VCPU_TIDS=${VCPU_TIDS}
IOTHREAD_TIDS=${IOTHREAD_TIDS}
OTHER_QEMU_TIDS=${OTHER_QEMU_TIDS}
VCPU_COUNT=${VCPU_COUNT}
IOTHREAD_COUNT=${IOTHREAD_COUNT}
OTHER_QEMU_COUNT=${OTHER_QEMU_COUNT}
DISK_DEVS=${DISK_DEVS}
DISK_MKDEV=${DISK_MKDEV}
FILE_BACKED_WARN=${FILE_BACKED_WARN}
SKIPPED_DISK_PATHS=${SKIPPED_DISK_PATHS}
NET_IFNAMES=${NET_IFNAMES}
NET_IFINDEXES=${NET_IFINDEXES}
NET_IFINDEX_LIST=${NET_IFINDEX_LIST}
NET_NAME_COLLISION_WARN=${NET_NAME_COLLISION_WARN}
VHOST_TIDS=${VHOST_TIDS}
MATCH_METHOD=${MATCH_METHOD}
EOF

cat "$TARGETS_ENV"
