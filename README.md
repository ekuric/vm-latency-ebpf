# CNV VM latency stack (eBPF / bpftrace)

Node-local observer for **OpenShift Virtualization / KubeVirt** VMs. It pins a
privileged Job to the node that runs a given VMI, discovers that VM’s QEMU
process + backing disks + tap/vhost path, then runs a layered bpftrace stack so
you can separate **host block**, **QEMU scheduling**, **KVM exit**, and **host
net** latency from guest-side FIO/DB latency.

Guest OS does not matter for the probes (Linux or Windows): all measurements are
**host / KVM side**. Correlate with guest FIO or HammerDB running during the
same window.

Deep histogram walkthrough of a real Windows CNV run:
[`ebpf-histogram-explain.md`](ebpf-histogram-explain.md).

---

## What it measures

| Layer | Probe | Timed interval | High value means… |
|------:|-------|----------------|-------------------|
| **[1]** | `vm_biolat.bt` | host `block_rq_issue` → `block_rq_complete` on this VM’s disks | Host/backend disk path is slow |
| **[2]** | `vm_runqlat.bt` | QEMU thread wakeup → scheduled on CPU (all / vCPU / IOThread / other) | Host CPU contention for QEMU |
| **[3]** | `vm_kvmlat.bt` | `kvm_exit` → `kvm_entry` (host time in that exit) | Expensive exit handling |
| **[4]** | `vm_netlat.bt` | `net_dev_queue` → `net_dev_xmit` via QEMU/vhost threads | Host egress qdisc/driver delay |
| **[4b]** | `guest-ping.sh` | ICMP RTT to guest IPs (optional, needs `hostNetwork`) | Guest reachability / path RTT |
| **[5]** | `vm_cachestat.bt` | host page-cache hit/miss/dirty rates (node-wide) | Cold cache / reclaim pressure |
| **[6]** | `vm_biosnoop.bt` | per-IO completions on VM disks (prints slow I/Os ≥1 ms) | Individual slow bios |
| **[7]** | `vm_runqlat_host.bt` | system-wide run-queue vs this-VM QEMU | Node contended vs only this VM |

**Not measured (guest-blind):** guest FIO / filesystem / virtio front-end inside
the VM. If guest completion latency ≫ **[1]**, look at guest/virtio/QEMU-above-bio
— not primarily **[2]** / **[4]**.

Disk hop map (from the stack summary):

```text
[A–C] guest FIO / FS / viostor|virtio_blk  — NOT measured
[D]   virtqueue kick / KVM exit host-time  — [3] (indirect)
[E]   QEMU/vhost before host bio           — GAP ([2b] IOThread sched is a proxy)
[F–G] host block_rq issue→complete         — [1]
```

---

## Layout

```text
vm-latency-ebpf/
├── README.md
├── ebpf-histogram-explain.md   # how to read histograms + sample Windows run
├── Dockerfile                  # Fedora 41 + bpftrace (preferred for disconnected OCP)
├── bin/
│   ├── vm-latency-observe.sh   # main entry: resolve VMI → Job → stream logs
│   └── resolve-vmi.sh          # VMI/VM → node, virt-launcher, guest IPs
├── bpf/
│   ├── vm_latency_stack.sh     # on-node orchestrator (Job entrypoint)
│   ├── discover-qemu.sh        # QEMU TGID, disks maj:min, net ifaces, thread roles
│   ├── vm_biolat.bt / vm_runqlat.bt / vm_kvmlat.bt / vm_netlat.bt
│   ├── vm_cachestat.bt / vm_biosnoop.bt / vm_runqlat_host.bt
│   └── guest-ping.sh
├── deploy/
│   ├── observer-job.yaml       # privileged hostPID Job template
│   ├── rbac.yaml               # ServiceAccount + Role
│   └── scc-vm-latency-observer.yaml
└── results/                    # default --out-dir for streamed raw logs
```

Tools are shipped into the Job via a **ConfigMap** (`--from-file=bpf/`), so
`.bt` / `.sh` edits do **not** require an image rebuild.

---

## Prerequisites

- `oc` (or `OC=kubectl`) and cluster access to the VMI namespace
- Cluster-admin (or equivalent) once, to bind SCC to the observer SA:
  - built-in **`privileged`** SCC (reliably grants `hostPID` + `spc_t`)
  - optional custom SCC `vm-latency-observer`
- Node must expose BTF (`/sys/kernel/btf/vmlinux`) for modern bpftrace
- Image with **bpftrace** available on the node:
  - default: `registry.fedoraproject.org/fedora:41` (installs packages if network works)
  - preferred offline: build/push the local `Dockerfile`

---

## Quick start

```bash
cd ioscale_files/vm-latency-ebpf

# By VMI name
./bin/vm-latency-observe.sh -n NAMESPACE -vmi VMI_NAME --duration 30

# By VirtualMachine name (resolves to the running VMI)
./bin/vm-latency-observe.sh -n NAMESPACE -vm VM_NAME --duration 30
```

What happens:

1. `resolve-vmi.sh` finds `nodeName`, virt-launcher pod UID, QEMU guest name
   (`<namespace>_<vmi>`), and guest IPs.
2. Creates ConfigMap from `bpf/`, applies RBAC + Job pinned to that node
   (`hostPID: true`, privileged, `spc_t`).
3. Streams observer logs to stdout and saves
   `results/<vmi>-<UTC>-raw.txt`.
4. Deletes Job/ConfigMap unless `--keep`.

Dry-run (print manifests only):

```bash
./bin/vm-latency-observe.sh -n ekuric -vmi winx-1 --dry-run
```

---

## Useful options

| Flag | Meaning |
|------|---------|
| `--duration N` | Seconds **per** probe layer (default `30`) |
| `--image IMAGE` | Observer image (override `BPFTRACE_IMAGE`) |
| `--keep` | Leave Job + ConfigMap after completion |
| `--namespace-obs NS` | Run Job in a different namespace than the VMI |
| `--ttl SECONDS` | Job `ttlSecondsAfterFinished` (default `600`) |
| `--out-dir DIR` | Where to save raw logs (default `./results`) |
| `--ping-guest` | Enable ICMP to guest IPs (`hostNetwork: true`) |
| `--guest-ip IP` | Override/add guest IP for ping (repeatable via comma list) |
| `--no-classic-tools` | Skip **[5]/[7]** → ~`4 × duration` instead of `7 × duration` |
| `--dry-run` | Print RBAC / ConfigMap / Job YAML only |

Wall-clock guidance (from the script):

```text
~ duration × probe_layers   + bpftrace attach overhead (often +1–2 min per layer)
classic_tools=1 → 7 layers
--no-classic-tools → 4 layers
```

Example with prebuilt image + guest ping + keep artifacts:

```bash
./bin/vm-latency-observe.sh \
  -n ekuric -vmi winx-1 \
  --duration 30 \
  --image quay.io/example/vm-latency-ebpf:latest \
  --ping-guest \
  --keep \
  --out-dir ./results
```

---

## Build the observer image (recommended for disconnected clusters)

```bash
podman build -t vm-latency-ebpf:latest -f Dockerfile .
podman push <registry>/vm-latency-ebpf:latest

./bin/vm-latency-observe.sh -n NS -vmi VMI --image <registry>/vm-latency-ebpf:latest
```

The image is Fedora 41 + `bpftrace` and copies `bpf/` to `/tools` for local/debug
runs. On-cluster, the Job still prefers the ConfigMap mount at `/tools`.

---

## Discovery (what the Job finds on-node)

`bpf/discover-qemu.sh` (requires **hostPID** so host `/proc` is visible):

1. Locate real **qemu-kvm** TGID for `guest=<namespace>_<vmi>` (rejects
   virt-launcher wrappers that only mention qemu in cmdline).
2. Classify QEMU threads: **vCPU** (`CPU */KVM`), **IOThread**, other.
3. Resolve backing disk paths from QEMU FDs/cmdline; skip noise
   (cloud-init / `*.iso` / config-drive / sysprep).
4. Map remaining paths → host **`maj:min`** (`DISK_DEVS` / packed `DISK_MKDEV`).
5. Find tap / `k6t-*` ifaces and **vhost** worker TIDs for net TX attribution.

### Host vs guest device numbers

Do **not** filter biolat with guest `lsblk` majors. Example:

| View | Example | Role |
|------|---------|------|
| Guest `lsblk` | `vdb` `252:16` | virtio front-end inside guest |
| Host `DISK_DEVS` | `251:16` (e.g. RBD) | backing device QEMU has open; what `block_rq_*` sees |

Layer **[1]** must use **host** `maj:min`. Wrong filter → tiny `n` while guest FIO is busy.

---

## How to read the summary

At the end of a run, `vm_latency_stack.sh` prints lines like:

```text
[1] Block I/O (host): n=404  p50=384us  p95=384us  p99=384us  avg=320us  max=384us
[2] run-queue all QEMU: n=120500  p50=3us  p95=6us  p99=6us  ...
[3] KVM exit host-time: n=25244804  p50=6us  p95=6us  p99=192us  ...
[4] Host net TX queue→xmit: n=334  p50=3us  ...
```

| Field | Meaning |
|-------|---------|
| `n` | Samples parsed from that layer’s histogram |
| `p50` / `p95` / `p99` | Percentiles (µs); snap to log₂ bin midpoints |
| `avg` / `max` | Mean / highest mid-bucket |

Layers are **different quantities** — do not average them. Compare scales (µs vs ms)
and rates (`n / duration`).

Quick health picture under load:

```text
[1]   hundreds of µs → few ms,   n ≈ IOPS × duration
[2*]  single-digit µs,           n = wakeups (often ≫ IOPS)
[3]   single-digit–tens µs,      n = exits (often ≫≫ IOPS)
[4]   single-digit µs,           n = TX frames (workload-dependent)
```

| Pattern | Likely cause |
|---------|----------------|
| **[1]** p50 in **ms+**, **[2]/[3]** stay µs | Host/backend disk |
| **[2a]/[2b]** p95/p99 in **ms** | Host CPU oversubscription |
| **[3]** p50 already large | Expensive exits |
| **[1]** `n` tiny while guest FIO hammers | Missed load window, or wrong `DISK_DEVS` |
| Guest FIO clat ≫ **[1]** p50 | Time in guest / virtio / above-bio (**A–C**, **E**) |

bpftrace often prints each `hist()` twice; prefer raw tables for serious analysis
if summary `n` looks double-counted. Full narrative:
[`ebpf-histogram-explain.md`](ebpf-histogram-explain.md).

---

## OpenShift / SCC notes

The observer needs **`hostPID: true`**, privileged, hostPath `/sys` +
`/lib/modules`, and SELinux type **`spc_t`** so it can read other PIDs’
`/proc/*/cmdline`.

`vm-latency-observe.sh` tries:

```bash
oc adm policy add-scc-to-user privileged -z vm-latency-observer -n <ns>
oc apply -f deploy/scc-vm-latency-observer.yaml
oc adm policy add-scc-to-user vm-latency-observer -z vm-latency-observer -n <ns>
```

If discovery sees very few PIDs (`hostpid_check: visible_pids < 80`), hostPID
did not stick — check:

```bash
oc get pod -n <ns> <observer-pod> \
  -o jsonpath='{.metadata.annotations.openshift\.io/scc} {.spec.hostPID}{"\n"}'
```

---

## Tips for good runs

1. Generate load **during** the probe windows (guest FIO / HammerDB). Layers run
   **sequentially**; a short FIO burst may miss **[1]** if it finishes early.
2. Use `--duration 30` (or more) under steady load so histograms fill.
3. Use `--no-classic-tools` for a faster core-only pass (**[1]–[4]**).
4. Keep `--keep` while debugging Job/SCC; inspect
   `oc logs -n <ns> job/<job> -c observer`.
5. Compare Linux vs Windows guests with the **same** host storage class and load
   shape; this tool isolates whether the gap is host-side or guest-side.

---

## Sample artifacts

| File | Content |
|------|---------|
| `results/*-raw.txt` | Streamed observer stdout from `vm-latency-observe.sh` |
| `results/winx-1-20260918T101004Z-NOTE.txt` | Pointer to analyzed Windows run |
| `ebpf-histogram-explain.md` | Bucket-by-bucket explanation of that run |

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `couldn't find remote ref` / wrong cluster | Wrong kubecontext; need access to the CNV cluster |
| Observer pod Pending | Node name, tolerations, SCC, image pull |
| `bpftrace not found` | Pass `--image` built from `Dockerfile` |
| No disks / biolat skipped | Discovery failed; `SKIPPED_DISK_PATHS` ate everything; or file-backed warn |
| Empty net hist | No tap/vhost resolved for this network mode |
| Permission / few PIDs | Not on `privileged` SCC; `hostPID` false; missing `spc_t` |
