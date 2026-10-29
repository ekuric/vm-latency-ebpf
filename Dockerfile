# Prebuilt observer image with bpftrace (preferred for disconnected OCP).
# Build:
#   podman build -t vm-latency-ebpf:latest -f Dockerfile .
#   podman push <registry>/vm-latency-ebpf:latest
FROM registry.fedoraproject.org/fedora:44

RUN dnf install -y \
      bpftrace \
      findutils \
      util-linux \
      procps-ng \
      python3 \
      iputils \
      iproute \
    && dnf clean all

# Tools are normally mounted from ConfigMap; keep a copy for local/debug runs.
COPY bpf/ /tools/
RUN chmod +x /tools/*.sh

WORKDIR /tmp
ENTRYPOINT ["/tools/vm_latency_stack.sh"]
