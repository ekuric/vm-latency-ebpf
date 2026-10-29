#!/usr/bin/env bash
# Run the VM latency stack probes on-node and print a correlated report.
# Expected env from the observer Job:
#   VMI_NAME, NAMESPACE, QEMU_GUEST_NAME, DURATION, TOOLS_DIR
#   PING_GUEST (0/1), GUEST_IPS (optional)
# Discovers QEMU/disks/ifaces, generates bpftrace scripts, runs them sequentially.

set -euo pipefail

# Under oc logs -f, stdout is a pipe → fully buffered unless we line-buffer.
if [[ -z "${VM_LATENCY_LINEBUF:-}" ]] && command -v stdbuf >/dev/null 2>&1; then
  export VM_LATENCY_LINEBUF=1
  exec stdbuf -oL -eL bash "$0" "$@"
fi

DURATION="${DURATION:-30}"
TOOLS_DIR="${TOOLS_DIR:-/tools}"
WORKDIR="${WORKDIR:-/tmp/vm-latency-work}"
TARGETS_ENV="${TARGETS_ENV:-/tmp/vm-latency-targets.env}"
DURATION_MS=$((DURATION * 1000))
PING_GUEST="${PING_GUEST:-0}"
GUEST_IPS="${GUEST_IPS:-}"
CLASSIC_TOOLS="${CLASSIC_TOOLS:-1}"
PROBE_TIMEOUT_SLACK_S="${PROBE_TIMEOUT_SLACK_S:-180}"

mkdir -p "$WORKDIR"
export TARGETS_ENV

echo "================================================================"
echo " CNV VM latency stack (eBPF / bpftrace)"
echo "================================================================"
NODE_HOSTNAME="${NODE_NAME:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)}"
echo "time_utc:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "vmi:          ${NAMESPACE:-}/${VMI_NAME:-}"
echo "guest_name:   ${QEMU_GUEST_NAME:-}"
echo "node:         ${NODE_HOSTNAME}"
echo "duration_s:   ${DURATION}"
echo "ping_guest:   ${PING_GUEST}"
echo "classic_tools:${CLASSIC_TOOLS}  (cachestat/biosnoop/runqlat_host)"
PROBE_LAYERS=4
if [[ "$CLASSIC_TOOLS" == "1" || "$CLASSIC_TOOLS" == "true" ]]; then
  PROBE_LAYERS=7
fi
echo "probe_layers: ${PROBE_LAYERS}  (~$((DURATION * PROBE_LAYERS))s window + bpftrace attach overhead)"
echo "guest_ips:    ${GUEST_IPS:-<none>}"
echo "launcher_uid: ${VIRT_LAUNCHER_UID:-<none>}"
echo "tools_dir:    ${TOOLS_DIR}"
echo

# Quick hostPID sanity check before discovery
PROC_VISIBLE="$(find /proc -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | wc -l | tr -d ' ')"
echo "hostpid_check: visible_pids=${PROC_VISIBLE}"
if [[ "${PROC_VISIBLE:-0}" -lt 80 ]]; then
  echo "warning: very few PIDs visible — hostPID may not be active." >&2
  echo "warning: oc get pod \$POD -o jsonpath='{.metadata.annotations.openshift\\.io/scc} {.spec.hostPID}'" >&2
fi
echo

if ! command -v bpftrace >/dev/null 2>&1; then
  echo "error: bpftrace not found in PATH" >&2
  echo "hint: use the provided Dockerfile image or install bpftrace" >&2
  exit 1
fi

if [[ ! -f /sys/kernel/btf/vmlinux ]]; then
  echo "warning: /sys/kernel/btf/vmlinux missing — CO-RE/BTF probes may fail on this node" >&2
fi

DISCOVER="${TOOLS_DIR}/discover-qemu.sh"
if [[ ! -x "$DISCOVER" ]]; then
  echo "error: ${DISCOVER} not found/executable" >&2
  exit 1
fi

echo "--- discovering QEMU / disks / net ifaces ---"
"$DISCOVER"
# shellcheck disable=SC1090
source "$TARGETS_ENV"

echo
echo "qemu_tgid:       ${QEMU_TGID}"
echo "qemu_comm:       ${QEMU_COMM}"
echo "thread_count:    ${THREAD_COUNT}"
echo "vcpu_tids:       ${VCPU_TIDS:-<none>} (count=${VCPU_COUNT:-0})"
echo "iothread_tids:   ${IOTHREAD_TIDS:-<none>} (count=${IOTHREAD_COUNT:-0})"
echo "other_qemu_tids: ${OTHER_QEMU_TIDS:-<none>} (count=${OTHER_QEMU_COUNT:-0})"
echo "disk_devs:       ${DISK_DEVS:-<none>}"
echo "disk_mkdev:      ${DISK_MKDEV:-<none>}"
echo "skipped_disks:   ${SKIPPED_DISK_PATHS:-<none>}"
echo "file_backed_warn:${FILE_BACKED_WARN:-0}"
echo "net_ifnames:     ${NET_IFNAMES:-<none>}"
echo "net_ifindexes:   ${NET_IFINDEXES:-<none>}"
echo "net_ifindex_list:${NET_IFINDEX_LIST:-<none>}"
echo "net_name_warn:   ${NET_NAME_COLLISION_WARN:-0}"
echo "vhost_tids:      ${VHOST_TIDS:-<none>}"
echo

NOTES=()
if [[ -n "${SKIPPED_DISK_PATHS:-}" ]]; then
  NOTES+=("Skipped noise disks (cloud-init/ISO/config-drive/sysprep): ${SKIPPED_DISK_PATHS}")
fi
if [[ "${FILE_BACKED_WARN:-0}" == "1" ]]; then
  NOTES+=("File-backed disk(s) detected: block latency may include co-tenants on the same filesystem device.")
fi
if [[ -z "${DISK_DEVS:-}" ]]; then
  NOTES+=("No backing disks resolved; block layer probe will be skipped. vCPU/KVM layers still run.")
fi
if [[ "${NET_NAME_COLLISION_WARN:-0}" == "1" ]]; then
  NOTES+=("Generic net iface names (tap0/k6t-eth0): TX latency attributed via QEMU/vhost threads.")
fi
if [[ -z "${NET_IFNAMES:-}" && -z "${VHOST_TIDS:-}" ]]; then
  NOTES+=("No tap/vnet ifaces / vhost threads resolved; host net-path probe may be sparse.")
fi
if [[ "${IOTHREAD_COUNT:-0}" -eq 0 ]]; then
  NOTES+=("No IOThread TIDs discovered (comm match); [2] IOThread hist may be empty — check ioThreadsPolicy / thread names.")
fi
if [[ "${VCPU_COUNT:-0}" -eq 0 ]]; then
  NOTES+=("No vCPU TIDs discovered (comm match 'CPU */KVM'); [2] vCPU hist may be empty.")
fi

gen_disk_init() {
  local mkdev_list="${1:-}"
  local d
  if [[ -z "$mkdev_list" ]]; then
    echo "	/* no disks */"
    return
  fi
  IFS=',' read -ra arr <<<"$mkdev_list"
  for d in "${arr[@]}"; do
    [[ -n "$d" ]] || continue
    echo "	@disks[${d}] = 1;"
  done
}

gen_tid_map_init() {
  # Emit @mapname[tid] = 1; for a comma-separated TID list (or single fallback).
  local mapname="$1"
  local tid_list="${2:-}"
  local fallback="${3:-}"
  local tid
  if [[ -n "$tid_list" ]]; then
    IFS=',' read -ra arr <<<"$tid_list"
    for tid in "${arr[@]}"; do
      [[ -n "$tid" ]] || continue
      echo "	@${mapname}[${tid}] = 1;"
    done
    return
  fi
  if [[ -n "$fallback" ]]; then
    echo "	@${mapname}[${fallback}] = 1;"
  else
    echo "	/* no ${mapname} */"
  fi
}

gen_qthread_init() {
  local tgid="$1"
  local tid
  if [[ ! -d "/proc/${tgid}/task" ]]; then
    echo "	@qthreads[${tgid}] = 1;"
    return
  fi
  for tid in "/proc/${tgid}/task/"*; do
    tid="$(basename "$tid")"
    echo "	@qthreads[${tid}] = 1;"
  done
}

gen_ifname_predicate() {
  local list="${1:-}"
  local n first=1
  if [[ -z "$list" ]]; then
    echo "0"
    return
  fi
  printf '('
  IFS=',' read -ra arr <<<"$list"
  for n in "${arr[@]}"; do
    [[ -n "$n" ]] || continue
    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      printf ' || '
    fi
    # str() avoids type quirks; compare to literal iface name
    printf 'str(args->name) == "%s"' "$n"
  done
  printf ')'
  if [[ "$first" -eq 1 ]]; then
    # empty list
    echo -n '0'
  fi
}

gen_ifindex_init() {
  local list="${1:-}"
  local d
  if [[ -z "$list" ]]; then
    echo "	/* no ifindexes */"
    return
  fi
  IFS=',' read -ra arr <<<"$list"
  for d in "${arr[@]}"; do
    [[ -n "$d" ]] || continue
    echo "	@ifindexes[${d}] = 1;"
  done
}

gen_txthread_init() {
  local tgid="$1"
  local vhost_list="${2:-}"
  local tid
  # All QEMU threads
  if [[ -d "/proc/${tgid}/task" ]]; then
    for tid in "/proc/${tgid}/task/"*; do
      tid="$(basename "$tid")"
      echo "	@txthreads[${tid}] = 1;"
    done
  else
    echo "	@txthreads[${tgid}] = 1;"
  fi
  # vhost workers
  if [[ -n "$vhost_list" ]]; then
    IFS=',' read -ra arr <<<"$vhost_list"
    for tid in "${arr[@]}"; do
      [[ -n "$tid" ]] || continue
      echo "	@txthreads[${tid}] = 1;"
    done
  fi
}

run_probe() {
  local name="$1"
  local src="$2"
  local out="$3"
  local rendered="${WORKDIR}/${name}.bt"
  local initdir="${WORKDIR}/init-${name}"
  mkdir -p "$initdir"

  gen_disk_init "${DISK_MKDEV:-}" >"${initdir}/disk"
  gen_qthread_init "$QEMU_TGID" >"${initdir}/qthread"
  gen_tid_map_init "vcpu_threads" "${VCPU_TIDS:-}" >"${initdir}/vcpu"
  gen_tid_map_init "iothread_threads" "${IOTHREAD_TIDS:-}" >"${initdir}/iothread"
  gen_tid_map_init "other_threads" "${OTHER_QEMU_TIDS:-}" >"${initdir}/other"
  gen_txthread_init "$QEMU_TGID" "${VHOST_TIDS:-}" >"${initdir}/txthread"
  gen_ifname_predicate "${NET_IFNAMES:-}" >"${initdir}/ifpred"

  python3 - "$src" "$rendered" "$DURATION_MS" "$QEMU_TGID" "$initdir" <<'PY'
import pathlib, sys, re
src, out, dur, tgid, initdir = sys.argv[1:6]
text = pathlib.Path(src).read_text()
def load(name, default="/* none */"):
    p = pathlib.Path(initdir, name)
    t = p.read_text() if p.exists() else default
    return t if t.strip() else default
repl = {
    "@@DURATION_MS@@": dur,
    "@@QEMU_TGID@@": tgid,
    "@@DISK_INIT@@": load("disk"),
    "@@QTHREAD_INIT@@": load("qthread"),
    "@@VCPU_THREAD_INIT@@": load("vcpu"),
    "@@IOTHREAD_THREAD_INIT@@": load("iothread"),
    "@@OTHER_THREAD_INIT@@": load("other"),
    "@@TX_THREAD_INIT@@": load("txthread"),
    "@@IFNAME_PREDICATE@@": load("ifpred", "0").strip(),
}
# Never expand tokens inside // comment lines (multiline injects break the program)
lines = []
for line in text.splitlines(keepends=True):
    if re.match(r'^\s*//', line):
        lines.append(line)
        continue
    for k, v in repl.items():
        line = line.replace(k, v)
    lines.append(line)
pathlib.Path(out).write_text(''.join(lines))
PY

  echo ">>> running ${name} for ${DURATION}s (start=$(date -u +%H:%M:%S)Z)"
  echo "    (bpftrace compile/attach can take 10–90s; then ${DURATION}s window)"
  local soft_to=$((DURATION + PROBE_TIMEOUT_SLACK_S))
  local rc=0
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground --signal=INT --kill-after=20s "$soft_to" \
      bpftrace "$rendered" 2>"${out}.err" | tee "$out"
    rc=${PIPESTATUS[0]}
  else
    bpftrace "$rendered" 2>"${out}.err" | tee "$out"
    rc=${PIPESTATUS[0]}
  fi
  set -e
  echo "<<< ${name} finished rc=${rc} end=$(date -u +%H:%M:%S)Z"
  if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    echo "error: bpftrace ${name} timed out after ${soft_to}s" >&2
    cat "${out}.err" >&2 || true
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "error: bpftrace ${name} failed rc=${rc}" >&2
    cat "${out}.err" >&2 || true
    echo "---- rendered program (head) ----" >&2
    head -n 40 "$rendered" >&2 || true
    return 1
  fi
  if [[ -s "${out}.err" ]]; then
    grep -v '^$' "${out}.err" | head -n 20 || true
  fi
  echo
}

BIO_OUT="${WORKDIR}/biolat.txt"
RUNQ_OUT="${WORKDIR}/runqlat.txt"
KVM_OUT="${WORKDIR}/kvmlat.txt"
NET_OUT="${WORKDIR}/netlat.txt"
PING_OUT="${WORKDIR}/guest_ping.txt"
CACHE_OUT="${WORKDIR}/cachestat.txt"
BIOSNOOP_OUT="${WORKDIR}/biosnoop.txt"
RUNQ_HOST_OUT="${WORKDIR}/runqlat_host.txt"

if [[ -n "${DISK_MKDEV:-}" ]]; then
  run_probe "vm_biolat" "${TOOLS_DIR}/vm_biolat.bt" "$BIO_OUT" || NOTES+=("Block probe failed (see logs).")
else
  echo ">>> skipping vm_biolat (no DISK_MKDEV)"
  echo "(skipped: no disks)" >"$BIO_OUT"
fi

run_probe "vm_runqlat" "${TOOLS_DIR}/vm_runqlat.bt" "$RUNQ_OUT" || NOTES+=("Run-queue probe failed.")
run_probe "vm_kvmlat" "${TOOLS_DIR}/vm_kvmlat.bt" "$KVM_OUT" || NOTES+=("KVM probe failed.")

if [[ -n "${NET_IFNAMES:-}" || -n "${VHOST_TIDS:-}" ]]; then
  run_probe "vm_netlat" "${TOOLS_DIR}/vm_netlat.bt" "$NET_OUT" || NOTES+=("Net-path probe failed.")
else
  echo ">>> skipping vm_netlat (no NET_IFNAMES/VHOST_TIDS)"
  echo "(skipped: no net ifaces)" >"$NET_OUT"
fi

if [[ "$PING_GUEST" == "1" || "$PING_GUEST" == "true" ]]; then
  echo ">>> running guest ICMP ping"
  GUEST_IPS="$GUEST_IPS" "${TOOLS_DIR}/guest-ping.sh" "$PING_OUT" || NOTES+=("Guest ping failed or unreachable.")
  cat "$PING_OUT"
  echo
else
  echo "(skipped guest ping; pass --ping-guest to enable)" >"$PING_OUT"
fi

if [[ "$CLASSIC_TOOLS" == "1" || "$CLASSIC_TOOLS" == "true" ]]; then
  run_probe "vm_cachestat" "${TOOLS_DIR}/vm_cachestat.bt" "$CACHE_OUT" || NOTES+=("Cachestat probe failed (kernel may lack some kprobes).")
  if [[ -n "${DISK_MKDEV:-}" ]]; then
    run_probe "vm_biosnoop" "${TOOLS_DIR}/vm_biosnoop.bt" "$BIOSNOOP_OUT" || NOTES+=("Biosnoop probe failed.")
  else
    echo ">>> skipping vm_biosnoop (no DISK_MKDEV)"
    echo "(skipped: no disks)" >"$BIOSNOOP_OUT"
  fi
  run_probe "vm_runqlat_host" "${TOOLS_DIR}/vm_runqlat_host.bt" "$RUNQ_HOST_OUT" || NOTES+=("Host runqlat probe failed.")
else
  echo ">>> skipping classic tools (CLASSIC_TOOLS=${CLASSIC_TOOLS})"
  echo "(skipped)" >"$CACHE_OUT"
  echo "(skipped)" >"$BIOSNOOP_OUT"
  echo "(skipped)" >"$RUNQ_HOST_OUT"
fi

summarize_hist() {
  local file="$1"
  local label="$2"
  local section_re="${3:-}"
  python3 - "$file" "$label" "$section_re" <<'PY' || true
import re, sys, math
path, label, section_re = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = open(path).read()
except FileNotFoundError:
    print(f"{label}: (no data)")
    sys.exit(0)

if section_re:
    m = re.search(section_re, text, re.I)
    if not m:
        print(f"{label}: (section not found — see raw hist above)")
        sys.exit(0)
    text = text[m.start():]
    # Stop before the next hist/samples section or layer header
    nxt = re.search(
        r'\n(?:run-queue latency histogram —|samples \(|===\s)',
        text[1:],
        re.I,
    )
    if nxt:
        text = text[: nxt.start() + 1]

pat = re.compile(r'\[\s*(\d+),\s*(\d+)\)\s+(\d+)')
samples = []
for lo, hi, cnt in pat.findall(text):
    lo, hi, cnt = int(lo), int(hi), int(cnt)
    mid = (lo + hi) / 2.0
    samples.extend([mid] * cnt)

if not samples:
    print(f"{label}: (no hist samples parsed — see raw hist above)")
    sys.exit(0)

samples.sort()
n = len(samples)

def pct(p):
    idx = min(n - 1, max(0, int(math.ceil(p / 100.0 * n) - 1)))
    return samples[idx]

avg = sum(samples) / n
print(f"{label}: n={n}  p50={pct(50):.0f}us  p95={pct(95):.0f}us  p99={pct(99):.0f}us  avg={avg:.0f}us  max={samples[-1]:.0f}us")
PY
}

echo "================================================================"
echo " VM latency stack summary"
echo "================================================================"
echo "target:    ${NAMESPACE}/${VMI_NAME}  guest=${QEMU_GUEST_NAME}"
echo "node:      ${NODE_HOSTNAME}  qemu_tgid=${QEMU_TGID}  disks=${DISK_DEVS:-none}  net=${NET_IFNAMES:-none}"
echo "threads:   total=${THREAD_COUNT:-?} vcpu=${VCPU_COUNT:-0} iothread=${IOTHREAD_COUNT:-0} other=${OTHER_QEMU_COUNT:-0}"
echo "duration:  ${DURATION}s per probe layer"
echo
summarize_hist "$BIO_OUT"  "[1] Block I/O (host)"
summarize_hist "$RUNQ_OUT" "[2] run-queue all QEMU" "histogram — all QEMU"
summarize_hist "$RUNQ_OUT" "[2a] run-queue vCPU" "histogram — vCPU"
summarize_hist "$RUNQ_OUT" "[2b] run-queue IOThread" "histogram — IOThread"
summarize_hist "$RUNQ_OUT" "[2c] run-queue other" "histogram — other"
summarize_hist "$KVM_OUT"  "[3] KVM exit host-time"
summarize_hist "$NET_OUT"  "[4] Host net TX queue→xmit"
if [[ -f "$PING_OUT" ]]; then
  grep -E '^\[4b\]|Guest ICMP' "$PING_OUT" || echo "[4b] Guest ICMP RTT: (see ping section above / skipped)"
fi
if [[ "$CLASSIC_TOOLS" == "1" || "$CLASSIC_TOOLS" == "true" ]]; then
  echo "[5] Cachestat: see per-second table + totals in section above (host page cache)"
  summarize_hist "$BIOSNOOP_OUT" "[6] Biosnoop (VM disks)" "histogram — all"
  summarize_hist "$RUNQ_HOST_OUT" "[7] Runqlat host-wide" "histogram — all tasks"
  summarize_hist "$RUNQ_HOST_OUT" "[7a] Runqlat this-VM QEMU" "histogram — this VM QEMU"
fi
echo

if [[ -f "$KVM_OUT" ]]; then
  echo "top KVM exit reasons (from probe):"
  awk '
    /exit reasons/ {p=1; next}
    p && /^===/ {p=0}
    p && NF {print}
  ' "$KVM_OUT" | head -n 30 || true
  echo
fi

if ((${#NOTES[@]})); then
  echo "notes:"
  for n in "${NOTES[@]}"; do
    echo "  - $n"
  done
  echo
fi

echo "----------------------------------------------------------------"
echo " Hop coverage (disk path)"
echo "----------------------------------------------------------------"
echo "  [A–C] guest FIO / FS / viostor|virtio_blk  — NOT measured (guest-blind)"
echo "  [D]   virtqueue kick / KVM exit host-time — [3] (indirect)"
echo "  [E]   QEMU/vhost before host bio          — GAP (use [2b] IOThread sched as proxy)"
echo "  [F–G] host block_rq issue→complete        — [1]"
echo "  sched QEMU threads (vCPU / IOThread)      — [2]/[2a]/[2b]"
echo "  host net TX queue→xmit                    — [4] (control path, not disk)"
echo
echo "  If guest FIO clat >> [1] body → look at A–C (+ E), not primarily [2]/[4]."
echo "  See: ebpf-histogram-explain.md (Hop map) / README.md"
echo "----------------------------------------------------------------"
echo
echo "done."
echo "raw outputs: ${WORKDIR}/"
