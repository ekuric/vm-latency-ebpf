# eBPF histogram guide — full run walkthrough

**Run:** `ekuric/winx-1` (Windows CNV VM) on `x37-h41-000-r740xd`  
**Time (UTC):** 2026-09-18T10:10:04Z  
**Job:** `vm-lat-winx-1-20260918101002`  
**Window:** 30 s **per** layer (~2 min wall clock)  
**Target:** QEMU TGID `2756104`, disks `252:16` + `252:32`, net `k6t-eth0`/`tap0`

This document explains **every histogram and counter** from that run.

---

## How to read bpftrace `hist()` (applies to all layers)

```
@biolat_us:
[512, 1K)          67584 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
 └─ latency bucket (µs)    └─ event count     └─ bar scaled to tallest bucket
```

| Piece | Meaning |
|-------|---------|
| `[lo, hi)` | Event latency \(t\) with **lo ≤ t &lt; hi** microseconds (`1K` = 1024 µs ≈ 1 ms) |
| Count | How many events landed in that bucket |
| `@` bars | Relative visual only (not a percent axis) |

bpftrace often **prints each map twice** (once in the `END` block, once on exit). Use one copy; ignore the duplicate.

The stack script also prints a **one-line summary** per layer (see next section). Prefer raw hists when percentiles look “stuck” on one bucket (coarse log₂ bins) or when maps were printed twice and the summarizer double-counted — still check the raw table for serious analysis.

---

## How to read the summary lines (`n=` / `p50=` / …)

At the end of a run, `vm_latency_stack.sh` prints lines like:

```
[1] Block I/O (host): n=404  p50=384us  p95=384us  p99=384us  avg=320us  max=384us
[2] run-queue all QEMU: n=120500  p50=3us  p95=6us  p99=6us  avg=3us  max=384us
[2a] run-queue vCPU: n=118022  p50=3us  p95=6us  p99=6us  avg=3us  max=384us
[2b] run-queue IOThread: n=2455  p50=3us  p95=24us  p99=48us  avg=7us  max=384us
[2c] run-queue other: n=241023  p50=3us  p95=6us  p99=6us  avg=3us  max=384us
[3] KVM exit host-time: n=25244804  p50=6us  p95=6us  p99=192us  avg=10us  max=384us
[4] Host net TX queue→xmit: n=334  p50=3us  p95=3us  p99=6us  avg=3us  max=6us
```

### Field meanings (every layer)

| Field | Meaning |
|-------|---------|
| **`n`** | Number of latency **samples** parsed from that layer’s histogram (≈ events that completed with a matched start timestamp in the window) |
| **`p50`** | Median — half of samples were ≤ this latency |
| **`p95`** | 95th percentile — 95% of samples ≤ this |
| **`p99`** | 99th percentile — tail; sensitive to rare slow events |
| **`avg`** | Arithmetic mean of sample mid-bucket values |
| **`max`** | Highest sample (mid-bucket of the top occupied bin) |
| Units | Always **microseconds** (`us`) in these summaries |

How percentiles are built: each hist bucket `[lo, hi)` with count \(c\) contributes \(c\) samples at midpoint \((lo+hi)/2\). So values snap to bin centers (e.g. 3, 6, 24, 48, 192, 384 µs). That is why p50/p95/p99 often look identical when almost all mass sits in one or two bins.

### What each layer’s latency *is*

| Line | Timed interval | High value means… |
|------|----------------|-------------------|
| **[1] Block I/O** | Host `block_rq_issue` → `block_rq_complete` on this VM’s disks | Host/backend disk path is slow |
| **[2] run-queue all** | QEMU thread woken → scheduled on CPU | QEMU threads wait long for CPU (host contention) |
| **[2a] vCPU** | Same, only `CPU */KVM` threads | Guest vCPU runnable but delayed on host |
| **[2b] IOThread** | Same, only IOThread threads (`*iothread*` / `IO *`) | Disk IOThreads wait for CPU (sched side of hop E) |
| **[2c] other** | Same, remaining QEMU threads | Misc QEMU workers delayed |
| **[3] KVM exit** | `kvm_exit` → `kvm_entry` (host time for that exit) | Host spends a long time handling one exit |
| **[4] Net TX** | `net_dev_queue` → `net_dev_xmit` on VM tap path | Host egress qdisc/driver delay |

These are **different quantities** — do not average them together. Compare **scales** (µs vs ms) and **rates** (`n` / duration).

### Worked example (the summary above)

Assume ~30 s per layer (your `--duration`).

| Line | Read of the numbers | Verdict |
|------|---------------------|---------|
| **[1]** `n=404`, p50=p95=p99=**384 µs**, avg=320 µs | Only **~13 IOPS** visible on the host in that window (`404/30`). Almost all completions sit in the ~384 µs bin. Host disk latency is **sub‑ms**, but **volume is low** (idle, light load, wrong disk filter, or guest not issuing much I/O during *this* probe window). | Host block not “multi‑ms bad”; check whether FIO was running during [1] |
| **[2]** `n=120500`, p50=**3 µs**, p95/p99=**6 µs**, max=384 µs | ~4k wakeups/s; scheduling wait is tiny. Rare max 384 µs does not move p99. | CPU run-queue **healthy** |
| **[2a]** ≈ same as [2], `n=118022` | Most run-queue samples are **vCPU** threads. | Guest vCPUs not stuck waiting for host CPU |
| **[2b]** `n=2455`, p50=3 µs, p95=**24 µs**, p99=**48 µs**, avg=7 µs | Fewer samples (fewer IOThreads than vCPUs). Tail a bit higher than vCPU but still **tens of µs**, not ms. | IOThread sched **fine**; not explaining ms-scale FIO |
| **[2c]** `n=241023`, p50=3 µs | Many “other” QEMU thread wakeups; still µs-scale. (`n` can exceed [2] if bpftrace printed maps twice and the summarizer counted both copies — prefer raw hist counts if `2a+2b+2c` ≫ `2`.) | Not a bottleneck |
| **[3]** `n=25.2M`, p50=p95=**6 µs**, p99=**192 µs**, avg=10 µs | **~840k exits/s** — very chatty (normal under Windows/virtio). Per-exit host time is usually ~6 µs; p99 192 µs is a thin tail. | High **rate**, low **per-exit** cost — not the storage story |
| **[4]** `n=334`, p50=**3 µs**, max=6 µs | Little TX during the window; host queue→xmit is clean. | Net path **not** involved |

**One-line story for this summary:** Host scheduling ([2]) and net ([4]) look excellent. KVM exits ([3]) are frequent but cheap. Host block ([1]) is fast when it happens (~0.3 ms) but **barely active** (`n=404`). If guest FIO reported high latency or low iodepth during the same wall-clock period, the gap is likely **guest-side (A–C)** or **FIO not overlapping the [1] window** — not run-queue or host TX.

### How to compare layers quickly

```
Typical healthy CNV disk run under load
  [1]   hundreds of µs → few ms,   n ≈ IOPS × duration
  [2*]  single-digit µs,           n = wakeups (often ≫ IOPS)
  [3]   single-digit–tens µs,      n = exits (often ≫≫ IOPS)
  [4]   single-digit µs,           n = TX frames (workload-dependent)
```

Red flags:

| Pattern | Meaning |
|---------|---------|
| [1] p50 in **ms+** while [2]/[3] stay µs | Host/backend disk path |
| [2a]/[2b] p95/p99 in **ms** | Host CPU contention / oversubscribed node |
| [3] p50 already **large** (not just p99) | Expensive exits / host handling |
| [1] `n` tiny while guest FIO is hammering | Probe window missed load, or disk `maj:min` discovery wrong |
| Guest FIO clat ≫ [1] p50 | Time is in guest / virtio / QEMU-above-bio (see Hop map) |

---

## Discovery context (not a histogram, but required)

| Field | Value | Why it matters |
|-------|-------|----------------|
| `QEMU_COMM=qemu-kvm` | Real emulator (not virt-launcher-monitor) | Probes attach to the right process |
| `DISK_DEVS=252:16,252:32` | Two **host** block devices (this run) | Layer [1] filters to these only |
| `DISK_MKDEV=…` | Packed `dev_t` = `(maj<<20)\|min` | Same ids bpftrace matches on `args->dev` |
| `NET_IFNAMES=k6t-eth0,tap0` | CNV masquerade path | Layer [4] RX name filter; TX uses QEMU/vhost threads |
| `VHOST_TIDS=…` | 16 vhost worker tids | Layer [4] TX attribution |
| `THREAD_COUNT=30` | QEMU threads | Layer [2] run-queue set |
| `SKIPPED_DISK_PATHS=…` | cloud-init / `*.iso` / config-drive (when present) | Not included in [1] |

Guest OS is Windows; all numbers are **host/KVM-side**.

### Where `DISK_DEVS` / `DISK_MKDEV` come from

They are **not** taken from guest `lsblk`. Discovery (`bpf/discover-qemu.sh`) does this on the **node**:

1. Find QEMU TGID for the VMI (`guest=<namespace>_<vmi>`).
2. Collect backing paths from QEMU’s open FDs (`/proc/<tgid>/fd/*`) and cmdline `-blockdev` / `-drive` (`filename` / `file=` / …).
3. Skip noise paths (cloud-init / noCloud / `*.iso` / config-drive / sysprep) — see `SKIPPED_DISK_PATHS`.
4. Resolve each remaining path inside QEMU’s **mount namespace** (`nsenter --mount`) with `stat` → host `maj:min`.
5. Emit:
   - `DISK_DEVS=maj:min,…` — human-readable filter list  
   - `DISK_MKDEV=(maj<<20)|min,…` — packed form used in `vm_biolat.bt` as `@disks[args->dev]`

Example: `251:16` → `(251<<20)|16 = 263192592`.

### Host vs guest: do not confuse with guest `lsblk`

Guest virtio disks and host backing devices are **different** device numbers:

| View | Example | Typical major | Role |
|------|---------|---------------|------|
| **Guest** `lsblk` | `vdb` `252:16`, `vdc` `252:32` | **252** (virtio-blk) | Front-end the guest OS sees |
| **Host** (this tool) | `DISK_DEVS=251:16,251:32` (e.g. RBD) | **251** (often `rbd`) or other host majors | Backing devices QEMU has open; what `block_rq_*` sees |

Minors can look similar (16 / 32) by coincidence; **majors differ by design**. Layer [1] must use the **host** ids. Guest `252:*` never matches host `block_rq_issue` for that PVC path.

On the **node** (not inside the VM), verify:

```bash
lsblk -o NAME,MAJ:MIN,SIZE,TYPE | grep -E '251:16|251:32'   # use the DISK_DEVS from the run
# or: ls -l /dev/rbd*
```

Those host devices are what biolat measures. Guest FIO on `/dev/vdc` still drives I/O through the matching host backing disk — but you filter by the host `maj:min`, not by `vdc`.

---

## === [1] Block I/O latency (host, filtered devices) ===

**Probe:** `block_rq_issue` → `block_rq_complete` on disks from `DISK_DEVS` only (this historical run: `252:16` / `252:32` **on the host**).

### Counters

| Map | Value | Meaning |
|-----|-------|---------|
| `@issued` | 92048 | Host block requests **started** in the 30 s window |
| `@completed` | 92041 | Requests **finished** and matched to a start time |

Gap of 7 ≈ I/Os still in flight when tracing stopped (normal).

**Rate (approx):** 92048 / 30 s ≈ **3068 IOPS** visible on the host for this VM’s disks.

### `rwbs` mix

| `rwbs` | Count | Share | Meaning |
|--------|------:|------:|---------|
| **WS** | 92024 | ~99.97% | Write + Sync (durable / sync write path) |
| **DS** | 10 | ~0.01% | Discard-related / flag combo (tiny) |
| **R** | 7 | ~0.01% | Read |

**Interpretation:** this window is a **write-sync storm**, not a read test. Host sees almost only synchronous writes from this VM’s disks — consistent with FIO write / DB flush / Windows write-through style load.

### Histogram `@biolat_us` (total)

```
[256, 512)           140
[512, 1K)          67584   ← MODE (peak)
[1K, 2K)           17406
[2K, 4K)            6242
[4K, 8K)             562
[8K, 16K)             93
[16K, 32K)             1
[32K, 64K)             3
```

| Region | Buckets | What it says |
|--------|---------|----------------|
| **Mode** | `[512, 1K)` ≈ **0.5–1.0 ms** | Typical host completion time (~73% of samples) |
| **Body** | `[1K, 2K)` + `[2K, 4K)` ≈ **1–4 ms** | Large secondary mass (~25%) |
| **Near tail** | `[4K, 8K)` … `[8K, 16K)` | Occasional slower I/Os (ms+) |
| **Far tail** | `[16K, 64K)` | Rare outliers (tens of ms) — hurt p99 / stalls |
| **Left (&lt;256 µs)** | Almost empty | Not a sub‑100 µs device path under this load |

**One-line story:** Host block service time for this Windows VM under sync-write load is **centered near 0.5–1 ms**, with a thick **1–4 ms** shoulder and a thin multi‑ms tail.

### `@biolat_by_rwbs[WS]`

Same shape as `@biolat_us` (expected — WS dominates). Use this when comparing “durable write” host latency across runs/backends.

### `@biolat_by_rwbs[R]`

Only **7** samples — **not statistically meaningful**. Bars look dramatic because the scale is relative to a tiny max count. Do not conclude “reads are slow” from this.

### `@biolat_by_rwbs[DS]`

10 samples, all in **`[1]`–`[4, 8)` µs** — fast, rare; not the workload story.

### What [1] does *not* measure

Guest NTFS/Windows stack, virtio guest half, QEMU before bio issue, or pure network RTT. Guest FIO latency should be **≥** this hist’s body if the bottleneck includes the host disk path.

---

## === [2] vCPU / QEMU run-queue latency ===

**Probe:** wakeup → on-CPU for QEMU threads (`@runqlat_us`), now **split by role**:

| Hist | Threads |
|------|---------|
| `@runqlat_us` | All QEMU TGID threads |
| `@runqlat_vcpu_us` | `comm` like `CPU */KVM` |
| `@runqlat_iothread_us` | `comm` matching `*iothread*` / `IO *` (e.g. `supplementalPool`) |
| `@runqlat_other_us` | Remaining QEMU threads |

Discovery exports `VCPU_TIDS` / `IOTHREAD_TIDS` / counts. If IOThread count is 0, the IOThread hist stays empty and the summary notes it.

**Samples:** `@runq_samples: 375493` in 30 s (all threads; this historical run was pre-split).

### Histogram `@runqlat_us`

```
[0]               141975    # < ~1 µs
[1]               197432    # ~1 µs          ← MODE
[2, 4)             31103
[4, 8)              3770
[8, 16)              632
...
[128K, 256K)           1    # rare extreme
```

| Region | Meaning |
|--------|---------|
| **Mass in `[0]` + `[1]` + `[2, 4)`** (~98%+) | After wakeup, QEMU/vCPU threads almost always get a CPU within a few µs |
| **Small counts `[4, 8)` … `[256, 512)`** | Mild occasional scheduling delay |
| **Tiny far tail (`[1K,…)` / one `[128K, 256K)`)** | Rare long waits — not the norm |

**One-line story:** Host **CPU scheduling is healthy** for this VM. Run-queue delay is **not** explaining multi‑ms I/O; the disk hist [1] is a different (and larger) timescale.

**Contrast with [1]:** run-queue mode ~**1 µs** vs block mode ~**0.5–1 ms** → about **500–1000×** apart. Hypervisor scheduling is fine; block path dominates I/O wait.

---

## === [3] KVM exit host-time ===

**Probe:** `kvm_exit` → `kvm_entry` for QEMU TGID.  
**Volume:** `@exits: 11742722` / `@entries: 11742525` ≈ **391 k exits/s** — a very chatty vCPU/exit path under load (normal for busy Windows + virtio).

### Histogram `@kvm_host_us`

```
[1]               734456
[2, 4)           4736053
[4, 8)           5909238   ← MODE
[8, 16)           118461
[256, 512)        163178   ← noticeable secondary bump
...
[512K, 1M)            19   ← rare very slow exits
```

| Region | Meaning |
|--------|---------|
| **Mode `[4, 8)` µs** (+ strong `[2, 4)`) | Typical exit handled on host in a **few microseconds** |
| **Shoulder `[8, 16)`** | Still fast |
| **Bump `[256, 512)`** | A real secondary population of **~0.25–0.5 ms** host dwell — worth watching if it grows |
| **Far tail to `[512K, 1M)`** | Rare multi‑100 ms host-side exit handling — rare but bad for latency spikes |

**One-line story:** Most exits cost **~2–8 µs** on the host; there is a **~0.3 ms** secondary bump and a thin slow tail. Exit **rate** is huge; **per-exit** time is usually tiny compared to [1] block latency.

### `@exit_reason[N]` (raw codes)

Counts of exit *types* (Intel VMX or AMD SVM — decode with arch headers). Top in this run:

| Rank | Code | Count (approx) |
|------|------|----------------|
| 1 | **24** | 5 206 763 |
| 2 | **31** | 4 519 210 |
| 3 | **32** | 1 147 649 |
| 4 | **7** | 273 000 |
| 5 | **12** | 253 781 |

These answer *“what kind of traps dominate?”*, not *“how long did I/O take?”*. High 24/31/32-style traffic is common for virtio/MMIO/interrupt-heavy guests; use arch docs to name them on your CPU vendor.

---

## === [4] Host network path (tap/vnet) ===

**TX:** queue by QEMU/vhost thread → `net_dev_xmit`  
**RX:** `netif_receive_skb` with name ∈ `{k6t-eth0, tap0}`

### Counters

| Counter | Value | Meaning |
|---------|------:|---------|
| `@queued` | 1674 | TX skbs queued by this VM’s QEMU/vhost threads |
| `@xmit` | 1186 | Those that reached xmit with a matching start stamp |
| `@rx` | 164 | RX deliveries on tap/k6t names |
| `@net_tx_samples` | 1186 | TX latency samples in the hist |

Queued &gt; xmit is normal (in-flight / unmatched at stop). Activity is **modest** vs block (~1.2 k TX samples vs ~92 k block I/Os) — this window was **disk-heavy, not net-heavy**.

### Histogram `@net_tx_queue_to_xmit_us`

```
[0]                  659   ← MODE  (< ~1 µs)
[1]                  367
[2, 4)               153
[4, 8)                 7
```

| Region | Meaning |
|--------|---------|
| **Almost all in `[0]`–`[2, 4)`** | Host egress from queue to xmit is **very fast** (sub‑µs to a few µs) |
| **Almost no tail** | No evidence of qdisc/driver backlog for this VM’s TX threads in this window |

**One-line story:** Host network TX path for this VM is **clean and low-latency**; it is **not** the bottleneck relative to block I/O.

**Not measured in the eBPF hist above:** guest TCP RTT, OVN east-west latency, or path beyond this node’s tap. Those need **[4b]** (or other tools).

---

## === [4b] Guest ICMP RTT ===

**What it is:** active `ping` from the observer Pod (with `hostNetwork: true`) to the VMI IP from `status.interfaces` (here `10.128.3.226`). **Not eBPF** — synthetic end-to-end ICMP RTT including OVN + guest stack (if the guest answers ICMP).

### How to test (this cluster / this VM)

```bash
cd ioscale_files/vm-latency-ebpf

# 1) Privileged SCC already required for the stack; hostNetwork needs it too
oc adm policy add-scc-to-user privileged -z vm-latency-observer -n ekuric

# 2) Re-run with ping enabled (uses GUEST_IPS from VMI, or override)
./bin/vm-latency-observe.sh -n ekuric -vmi winx-1 --duration 30 --ping-guest \
  --image quay.io/ekuric/vm-latency-ebpf:latest

# Optional: force IP if VMI status has none / wrong address
./bin/vm-latency-observe.sh -n ekuric -vmi winx-1 --duration 30 --ping-guest \
  --guest-ip 10.128.3.226 \
  --image quay.io/ekuric/vm-latency-ebpf:latest
```

### What success looks like in the log

```
=== [4b] Synthetic guest RTT (ICMP ping) ===
--- ping 10.128.3.226 count=20 ---
...
rtt min/avg/max/mdev = 0.2/0.4/1.1/0.1 ms

[4b] Guest ICMP RTT: min=0.2ms avg=0.4ms max=1.1ms
```

Compare **avg ms** (guest path) to **[4] `@net_tx_queue_to_xmit_us`** (host µs only). They are different quantities: ping ≫ host queue→xmit is normal.

### If ping fails

| Symptom | Likely cause |
|---------|----------------|
| `ping failed` / 100% loss | Windows Firewall blocking ICMPv4; OVN NetworkPolicy; IP not on node underlay |
| No `GUEST_IPS` | VMI has no IP in status — pass `--guest-ip` |
| Job won’t schedule / SCC | Need `privileged` (allows `hostNetwork`) on `vm-latency-observer` SA |

**Windows guest quick allow (inside VM, admin):** enable “File and Printer Sharing (Echo Request - ICMPv4-In)” in Windows Defender Firewall, or temporarily allow ICMP.

**Sanity from the node** (optional, separate from the Job):

```bash
oc debug node/x37-h41-000-r740xd -- chroot /host ping -c 5 10.128.3.226
```

### What [4b] still does *not* cover

- TCP/HTTP app RTT (use `curl`/`sockperf`/FIO network or in-guest tools)
- East-west between two VMs (ping **from** another VM or run two observers / `oc exec` into a debug pod on the same network)
- OVN flow tracing (`ovn-trace`, `ofproto/trace`) — separate from this toolkit

---

## Cross-layer comparison (this run)

| Layer | What | Typical scale here | Bottleneck? |
|-------|------|--------------------|-------------|
| **[1] Block** | Host disk issue→complete | **0.5–4 ms** body | **Yes — dominant for storage** |
| **[2] Run-queue** | vCPU scheduling wait | **~1 µs** | No |
| **[3] KVM exit** | Host time per exit | **~2–8 µs** (mode) | No (high rate, low per-exit cost) |
| **[4] Net TX** | queue→xmit | **&lt;4 µs** | No |

```
Guest FIO / app latency
    │
    ├─ guest OS + virtio          (not in these hists)
    ├─ [3] KVM exit               ~µs (frequent)
    ├─ [2] run-queue              ~µs (healthy)
    ├─ [1] block host             ~0.5–4 ms  ← main storage signal
    └─ [4] net host TX            ~µs (quiet / healthy)
```

**Bottom line for `winx-1` this run:** Under sync-write load, the **host block layer** shows **~0.5–1 ms typical** completions with a **1–4 ms** shoulder. **CPU scheduling and host net TX look healthy** at microsecond scales. If guest FIO is much worse than ~1–4 ms, look next at **guest Windows/virtio path** and QEMU above the bio — not primarily at run-queue or net queue→xmit.

---

## Hop map: where eBPF can observe each hop

Treat one guest disk I/O (e.g. FIO) as a **pipeline of hops**. For each hop ask: can host eBPF time it, and with which probe? That turns “virtio is slow” into **subtractable layers**.

### Disk path hops (virtio-blk)

```
[A] FIO submit                    guest userspace
[B] Windows/Linux FS + block      guest kernel
[C] viostor / virtio_blk          guest virtio driver
[D] virtqueue kick / notify       shared ring → KVM exit
[E] QEMU / vhost-blk handle       host userspace or vhost
[F] host bio / request            host block layer
[G] backend (RBD/LVM/NVMe/…)      host storage
[H] completion reverse path       G → … → A
```

### Coverage vs this toolkit

| Hop | Host eBPF? | Today (`vm-latency-ebpf`) | Notes |
|-----|------------|---------------------------|--------|
| **A–C** guest FIO / NTFS / `viostor` | **No** | Blind | Guest FIO JSON, ETW/WPA, or in-guest tools |
| **D** virtqueue kick | **Indirect** | **[3]** `vm_kvmlat` | Exit host-time / reasons — not “queue #3” labeled |
| **E** QEMU/vhost before bio | **Partial / hard** | **Gap** (+ **[2b]** proxy) | Full E needs USDT/uprobe; IOThread runqlat approximates sched wait |
| **F→G** host request lifetime | **Yes** | **[1]** `vm_biolat` | `block_rq_issue` → `complete` on VM `maj:min` |
| QEMU thread sched delay | **Yes** | **[2]** `vm_runqlat` | Split: all / **[2a]** vCPU / **[2b]** IOThread / **[2c]** other |
| Host net egress (not disk) | **Yes** | **[4]** `vm_netlat` | Different path; useful as control |
| Guest ICMP RTT | Not eBPF | **[4b]** ping | Reachability / coarse RTT only |

```
Guest half (blind to host eBPF)     Host half (this toolkit)
───────────────────────────────     ────────────────────────
A FIO                               D KVM exit time      [3]
B FS/block                          E (gap: QEMU→bio)
C viostor  ──virtqueue──►           F→G block_rq         [1]
                                    + QEMU runqlat       [2]
```

### How to use the map on a run (this `winx-1` example)

1. Read **[1]** body → host storage service time (~0.5–4 ms here).
2. Read **[2]** / **[3]** → if µs-scale, hops “wait for CPU” and “exit host-time” are not the story.
3. Compare **guest FIO `clat`** (from FIO JSON) to **[1]**:
   - FIO ≈ [1] → bottleneck is largely host block / backend.
   - FIO ≫ [1] → missing time is mostly **A–C + E** (guest stack / `viostor` / QEMU above bio).
4. For Windows vs Linux **iodepth** questions: same VM YAML + similar [1]/[2]/[3] ⇒ depth gap is almost certainly guest (`windowsaio` / NTFS / `viostor`), not host virtqueue YAML.

This is why [1]’s “What [1] does *not* measure” section matters: the hop map makes that gap explicit instead of accidental.

---

## Draft changes for `vm-latency-ebpf`

Goal: make the hop map first-class in docs/output, close easy host-side gaps, and keep guest hops explicitly out of scope (or optional later).

### Status

| Item | Status |
|------|--------|
| Hop-map section in README | **Done** |
| Hop coverage footer in stack summary | **Done** (`vm_latency_stack.sh`) |
| IOThread vs vCPU runqlat split | **Done** (`discover-qemu.sh` + `vm_runqlat.bt`) |
| Richer [3] exit docs | Pending |
| Optional finer block split | Pending |
| Linux vs Windows compare-two-VMI helper | Pending |
| QEMU USDT hop **E** | Explicit non-goal / experimental later |

### Doc / report

| Change | Where | Why |
|--------|-------|-----|
| ~~Add hop-map section to README~~ | `README.md` | **Done** |
| ~~Print hop coverage in stack summary footer~~ | `bpf/vm_latency_stack.sh` | **Done** |
| Optional: correlate note when FIO summary path passed | observe script / future flag | “If guest p50 ≫ [1] p50 → look at A–C/E” |

### Probe / discovery

| Change | Files | What it adds |
|--------|-------|----------------|
| ~~Split QEMU runqlat by thread role~~ | `discover-qemu.sh`, `vm_runqlat.bt`, stack script | **Done** — hists [2]/[2a]/[2b]/[2c]; roles from `/proc/<tid>/comm` |
| **Richer [3] exit attribution** | `vm_kvmlat.bt`, summary | Keep top exit reasons; document which are virtio/MMIO-ish |
| **Optional block split** | new `vm_biolat_*.bt` or flags | queued-vs-service if stable on RHCOS |
| **Linux vs Windows compare mode** | `bin/vm-latency-observe.sh` | Two VMIs back-to-back, side-by-side [1]/[2]/[3] |

### Explicit non-goals (keep unless product asks)

| Out of scope | Reason |
|--------------|--------|
| In-guest ETW / `viostor` DPC / FIO `iodepth_level` | Needs guest agent or manual guest tooling |
| Stable QEMU USDT for “virtqueue → bio” (hop **E**) | Version-fragile; experimental if attempted |
| Claiming [1] == guest FIO latency | Already a non-goal; hop map reinforces it |

### Suggested next steps

1. ~~Docs + summary footer~~
2. ~~IOThread vs vCPU runqlat split~~
3. **Compare-two-VMI helper** for Linux vs Windows on identical disk config.
4. Only then experiment with hop-**E** QEMU/vhost probes if [1]≪FIO still unexplained after guest checks.

### Acceptance checks

- [x] Summary mentions hops A–C blind and [1]=F→G.
- [x] With `supplementalPool`, runqlat can show IOThread vs vCPU separately (or note when none discovered).
- [ ] Linux + Windows VMI on same storage class: [1] similar while guest FIO/`iodepth_level` differs → report points to guest hops.
- [x] No new claim that host eBPF measures `viostor` or Windows `windowsaio` depth.

