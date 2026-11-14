+++
title = "Getting RDMA into Kubernetes Pods, Part 2: SR-IOV VFs"
date = "2026-11-13"
draft = false
ogImage = "/images/og/getting-rdma-into-kubernetes-pods-part-2-sriov-vfs.png"
tags = ["rdma", "kubernetes", "nccl", "sr-iov", "oke"]
description = "Part 2 of a series on RDMA in Kubernetes pods for GPU training. Each pod gets its own SR-IOV virtual function on each rail, with 1 or 2 VFs per physical function."
+++

This series tests four ways to give a Kubernetes pod RDMA for GPU training, on two pairs of A100 nodes. [Part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/) used `hostNetwork` and set the baseline, on the second pair with the same setup. NCCL `all_reduce` reached 190.54 GB/s bus bandwidth at 8 GiB on 16 GPUs. This part covers SR-IOV VFs, part 3 covers IPvlan, and part 4 covers DRA.

With SR-IOV, each port of a NIC is a physical function (PF) that can create virtual functions (VFs). A VF has its own network interface, MAC address and RDMA device. Each pod gets one VF on each rail, and it stays on the pod network. The pod is not privileged. With 1 VF per PF, it got the same bandwidth as `hostNetwork`. NCCL reached 190.55 GB/s.

The hard part is sharing the rails between pods. With 1 VF per PF, a pod that takes all 16 rails takes them for the whole node. Two jobs can split the rails, with 4 GPUs and 8 VFs each per node. Each PCIe root of these nodes has 2 GPUs and 2 NICs. NCCL uses GPUDirect RDMA only when the NIC is close enough to the GPU. But the kubelet got the GPUs and the VFs from two device plugins, and did not match them. So on one node, NCCL sent the traffic of each job through only the 3 VFs next to its GPUs. On the other node, one job also used NICs on other roots, and that data went through CPU memory. The two jobs got 43.71 and 26.77 GB/s. With the `restricted` Topology Manager policy, the kubelet gave each pod GPUs and VFs on the same NUMA nodes. The two jobs then got 96.28 and 96.35 GB/s at the same time. With 2 VFs per PF and one resource for each rail, every pod got a VF on every rail. Two jobs with 4 GPUs per node then got 96.28 and 96.35 GB/s at the same time. In [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), a job with 4 GPUs per node got 96.64 GB/s.

I also tested the exclusive RDMA namespace mode with the RDMA CNI. By default, the RDMA CNI forced traffic class 0 on each VF, and `ib_write_bw` got about half. With `rdmaQoS` in the network, it got the full bandwidth.

Every manifest and script in this post ran on the test cluster. Long files are collapsed, so click a file name to open it.

## Why each pod needs its own interface

On these nodes, DOCA-OFED lets a process use a RoCE GID only in one case. The interface of the GID must be in the network namespace of the process. [Why Pods See Zero RoCE GIDs on DOCA-OFED](/posts/why-pods-see-zero-roce-gids-on-doca-ofed/) covers this check. The rails `rdma0` to `rdma15` stay in the host namespace. So a pod on the pod network cannot use the GIDs of the rails, even with the RDMA devices.

A VF fixes this. Its network interface moves into the network namespace of the pod. When the interface gets an IP address, the kernel adds a RoCE GID for that address. The GID is on the RDMA device of the VF, so the pod can use it.

These nodes run in the shared RDMA namespace mode of `ib_core`. Their `/etc/modprobe.d/ib_core.conf` sets it with `options ib_core netns_mode=1`. The A100 nodes of the [GID post](/posts/why-pods-see-zero-roce-gids-on-doca-ofed/) ran an older image, which used the exclusive mode by default. In the shared mode, the network does not use the RDMA CNI. That plugin moves the RDMA device of the VF into the pod, but it works only in the exclusive mode. The GID post covers the modes. Near the end of this post, I test the exclusive mode with the RDMA CNI.

## The setup

Most tests ran on the first pair of nodes. The sections that ran on the nodes of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/) say so. The setup and the image are the same as in part 1:

- 2 x BM.GPU.B4.8 on OKE v1.36.4, with CRI-O 1.36.3
- Each node has 8 A100 GPUs and 16 RoCE rails at 100 Gb/s, all in the IPv4 subnet `10.224.0.0/12`
- DOCA-OFED 3.5.0 in the shared RDMA namespace mode
- The NVIDIA GPU Operator 26.3.3
- The image with NCCL 2.32.3 and perftest 6.28 from [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/)

These results are for a single plane network with IPv4 rails, like the one these nodes use. The same logic applies to Oracle Cloud shapes on the multiplanar network, but their configuration is different.

I added the NVIDIA Network Operator 26.7.1, the newest release when I tested. Its SR-IOV Network Operator creates the VFs and runs the SR-IOV device plugin:

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm upgrade --install network-operator nvidia/network-operator \
  --namespace nvidia-network-operator --create-namespace \
  --version 26.7.1 --values values.yaml --wait --timeout 15m
```

{{< code language="yaml" title="values.yaml" open="false" >}}
nfd:
  # The cluster already runs Node Feature Discovery.
  enabled: false

sriovNetworkOperator:
  enabled: true

sriov-network-operator:
  sriovOperatorConfig:
    deploy: true
    disableDrain: false
    configurationMode: daemon
    # The OCI image already sets the NIC firmware for SR-IOV.
    disablePlugins:
      - mellanox

operator:
  resources:
    requests:
      cpu: 5m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
{{< /code >}}

`values.yaml` turns off the NFD of the chart, because the cluster already runs NFD. It also turns off the `mellanox` plugin of the SR-IOV Network Operator. That plugin changes NIC firmware settings. The firmware here already allows 127 VFs on each PF. With the plugin on, the operator would change that number to match the policy, then drain and reboot each node. Turning the plugin off avoids these reboots.

Oracle Cloud supports at most 2 VFs on each RDMA PF. I tested 1 VF per PF first, and then 2.

The operator configuration then had the `daemon` mode, drains turned on, and the `mellanox` plugin off:

```
daemon false ["mellanox"]
```

The NicClusterPolicy starts Multus, the CNI plugins and NVIDIA IPAM:

{{< code language="yaml" title="nic-cluster-policy.yaml" open="false" >}}
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata:
  name: nic-cluster-policy
spec:
  # The OCI image supplies the DOCA-OFED driver, so no ofedDriver section.
  nvIpam:
    image: nvidia-k8s-ipam
    repository: nvcr.io/nvidia/mellanox
    version: network-operator-v26.7.1
    enableWebhook: false
  secondaryNetwork:
    cniPlugins:
      image: plugins
      repository: nvcr.io/nvidia/mellanox
      version: network-operator-v26.7.1
    multus:
      image: multus-cni
      repository: nvcr.io/nvidia/mellanox
      version: network-operator-v26.7.1
{{< /code >}}

The VF addresses come from a pool in `192.168.0.0/16`. NVIDIA IPAM gives each node a block of 100 addresses:

{{< code language="yaml" title="ip-pool.yaml" open="false" >}}
apiVersion: nv-ipam.nvidia.com/v1alpha1
kind: IPPool
metadata:
  name: sriov-pool
  namespace: nvidia-network-operator
spec:
  subnet: 192.168.0.0/16
  perNodeBlockSize: 100
  gateway: 192.168.0.1
{{< /code >}}

By default, the operator drains one node at a time. This file sets the same limit, as an example:

{{< code language="yaml" title="sriov-network-pool-config.yaml" open="false" >}}
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkPoolConfig
metadata:
  name: rdma-vf
  namespace: nvidia-network-operator
spec:
  # Configure one GPU node at a time.
  maxUnavailable: 1
  nodeSelector:
    matchExpressions:
      - key: node.kubernetes.io/instance-type
        operator: In
        values:
          - BM.GPU.B4.8
{{< /code >}}

The network `rdma-vf` gives a pod one VF interface each time the pod lists it. The `tuning` plugin sets the ARP sysctls of each interface, and the `sbr` plugin adds source routing. The [ARP post](/posts/arp-rp-filter-and-accept-ra-for-rdma-pods-on-kubernetes/) explains the values.

{{< code language="yaml" title="sriov-network-shared.yaml" open="false" >}}
# Shared RDMA mode: no RDMA CNI. It refuses to run unless the mode is exclusive.
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
{{< /code >}}

The node policy lists the 16 rail PFs by PCI address. It leaves out the front-end NICs, which are also RDMA devices from the same vendor. It asks for 1 VF on each PF, with the MTU of the rails:

{{< code language="yaml" title="sriov-network-node-policy.yaml" open="false" >}}
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: bm-gpu-b4-8
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:0c:00.0"
      - "0000:0c:00.1"
      - "0000:16:00.0"
      - "0000:16:00.1"
      - "0000:47:00.0"
      - "0000:47:00.1"
      - "0000:4b:00.0"
      - "0000:4b:00.1"
      - "0000:89:00.0"
      - "0000:89:00.1"
      - "0000:93:00.0"
      - "0000:93:00.1"
      - "0000:c3:00.0"
      - "0000:c3:00.1"
      - "0000:d1:00.0"
      - "0000:d1:00.1"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 1
  priority: 90
  resourceName: rdma-vf
  # The operator creates the VFs. Nothing else may write sriov_numvfs.
  externallyManaged: false
{{< /code >}}

The operator created the VFs on both nodes in about a minute, without a drain or a reboot. Each node then offered 16 `nvidia.com/rdma-vf`.

## What the pod needs

A pod needs four things:

- `nvidia.com/rdma-vf: 16`, for one VF on each rail
- The annotation `k8s.v1.cni.cncf.io/networks` with `rdma-vf` 16 times
- The namespace of the network, which is `default` here
- For NCCL, `NCCL_IB_HCA` with the RDMA devices of its VFs, and `NCCL_IB_GID_INDEX=3`

It does not need `privileged`, `hostNetwork` or a `hostPath` mount. The test pods also add `IPC_LOCK`, but these nodes do not need it. The Pod Security section explains why. These are the two test pods:

{{< code language="yaml" title="vf-pods.yaml" open="false" >}}
# Two pods with 16 VFs each, one per GPU node, for the per-rail ib_write_bw test.
---
apiVersion: v1
kind: Pod
metadata:
  name: vf-n1
  namespace: default
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf
spec:
  nodeSelector:
    kubernetes.io/hostname: "10.140.66.66"
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  containers:
    - name: rdma
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
      resources:
        limits:
          nvidia.com/rdma-vf: 16
---
apiVersion: v1
kind: Pod
metadata:
  name: vf-n2
  namespace: default
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf
spec:
  nodeSelector:
    kubernetes.io/hostname: "10.140.82.106"
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  containers:
    - name: rdma
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
      resources:
        limits:
          nvidia.com/rdma-vf: 16
{{< /code >}}

A check pod with one VF prints the GIDs of the VF:

{{< code language="yaml" title="vf-check.yaml" open="false" >}}
apiVersion: v1
kind: Pod
metadata:
  name: rdma-vf-check
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-vf
spec:
  restartPolicy: Never
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  containers:
    - name: check
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
      resources:
        limits:
          nvidia.com/rdma-vf: 1
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -u
          echo "RDMA netns mode: $(cat /sys/module/ib_core/parameters/netns_mode) (Y = shared, N = exclusive)"
          echo "RDMA devices visible in the pod: $(find /sys/class/infiniband -mindepth 1 -maxdepth 1 | wc -l)"
          echo "Character devices: $(find /dev/infiniband -mindepth 1 -maxdepth 1 -printf '%f ')"
          ip=$(ip -4 -o addr show dev net1 | awk 'NR == 1 { split($4, a, "/"); print a[1] }')
          dev=$(ls /sys/class/net/net1/device/infiniband)
          echo "VF interface net1: ip=$ip rdma_device=$dev"
          for i in 0 1 2 3; do
            echo "  gid $i: $(cat "/sys/class/infiniband/$dev/ports/1/gids/$i") $(cat "/sys/class/infiniband/$dev/ports/1/gid_attrs/types/$i" 2>&1)"
          done
          IFS=. read -r o1 o2 o3 o4 <<< "$ip"
          expected=$(printf '0000:0000:0000:0000:0000:ffff:%02x%02x:%02x%02x' "$o1" "$o2" "$o3" "$o4")
          gid3=$(cat "/sys/class/infiniband/$dev/ports/1/gids/3")
          type3=$(cat "/sys/class/infiniband/$dev/ports/1/gid_attrs/types/3" 2>&1)
          for path in /sys/class/infiniband/*; do
            other=$(basename "$path")
            if [ "$other" != "$dev" ]; then
              echo "Other RDMA device $other gid 3: $(cat "$path/ports/1/gids/3")"
              break
            fi
          done
          if [ "$gid3" = "$expected" ] && [ "$type3" = "RoCE v2" ]; then
            echo "PASS: GID index 3 of $dev is the RoCE v2 GID of $ip"
          else
            echo "FAIL: GID index 3 of $dev is $gid3 ($type3), expected $expected (RoCE v2)"
            exit 1
          fi
{{< /code >}}

It printed this:

```
RDMA netns mode: Y (Y = shared, N = exclusive)
RDMA devices visible in the pod: 34
Character devices: rdma_cm uverbs26 umad26
VF interface net1: ip=192.168.0.34 rdma_device=mlx5_26
  gid 0: fe80:0000:0000:0000:8cca:d1ff:fed4:647d IB/RoCE v1
  gid 1: fe80:0000:0000:0000:8cca:d1ff:fed4:647d RoCE v2
  gid 2: 0000:0000:0000:0000:0000:ffff:c0a8:0022 IB/RoCE v1
  gid 3: 0000:0000:0000:0000:0000:ffff:c0a8:0022 RoCE v2
Other RDMA device mlx5_0 gid 3: 0000:0000:0000:0000:0000:0000:0000:0000
PASS: GID index 3 of mlx5_26 is the RoCE v2 GID of 192.168.0.34
```

The VF has a RoCE v2 GID for its address at index 3. In shared mode, the pod sees all 34 RDMA devices of the node in sysfs. They are the 18 PFs and the 16 VFs. The pod has device files only for its own VF. GID 3 of `mlx5_0` read as zero.

## The results with 1 VF per PF

I tested each rail with `ib_write_bw`, one rail at a time, as in [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/). `vf-map.sh` prints the PF, the address and the RDMA device of each VF in a pod. `rails-vf.sh` pairs the VFs of the two pods by their PF:

{{< code language="bash" title="vf-map.sh" open="false" >}}
#!/bin/bash
# Print "<PF PCI address> <interface> <ip> <rdma device>" for each VF interface of a pod.
# Usage: vf-map.sh <pod>
set -u
# shellcheck disable=SC2016
kubectl exec "$1" -- bash -c 'for n in /sys/class/net/net*; do i=${n##*/}; ip=$(ip -4 -o addr show dev "$i" | awk "NR == 1 { split(\$4, a, \"/\"); print a[1] }"); pf=$(readlink -f "$n/device/physfn"); echo "${pf##*/} $i $ip $(ls "$n/device/infiniband")"; done | sort'
{{< /code >}}

{{< code language="bash" title="rails-vf.sh" open="false" >}}
#!/bin/bash
# ib_write_bw on each rail, from the VF of one pod to the VF of another pod on the same PF, one rail at a time.
# Usage: rails-vf.sh [client pod] [server pod]
set -u
cli=${1:-vf-n1}
srv=${2:-vf-n2}
# The rail PFs in rail order (rdma0 to rdma15).
pfs="0c:00.0 0c:00.1 16:00.0 16:00.1 47:00.0 47:00.1 4b:00.0 4b:00.1 89:00.0 89:00.1 93:00.0 93:00.1 c3:00.0 c3:00.1 d1:00.0 d1:00.1"
smap=$(./vf-map.sh "$srv")
cmap=$(./vf-map.sh "$cli")
port=18515
r=0
for pf in $pfs; do
  read -r _ _ sip sdev < <(awk -v pf="0000:$pf" '$1 == pf' <<<"$smap")
  read -r _ cif _ cdev < <(awk -v pf="0000:$pf" '$1 == pf' <<<"$cmap")
  kubectl exec "$srv" -- ib_write_bw -d "$sdev" -x 3 -F --report_gbits -D 5 --tclass=41 -p $port >/dev/null 2>&1 &
  sleep 2
  out=$(kubectl exec "$cli" -- ib_write_bw -d "$cdev" -x 3 -F --report_gbits -D 5 --tclass=41 -p $port "$sip" 2>&1)
  wait
  res=$(echo "$out" | awk '/^ 65536/ {print $4" Gb/s"}')
  [ -z "$res" ] && res="FAILED: $(echo "$out" | grep -m1 -E 'Failed status|Couldn|error' )"
  echo "rdma$r $pf $cif $cdev -> $sip $res"
  printf '%s\n' "$out" >&2
  port=$((port + 1))
  r=$((r + 1))
done
{{< /code >}}

Every rail gave 96.86 to 96.88 Gb/s. In [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), `hostNetwork` gave 96.86 to 96.88 Gb/s.

In the NCCL job, each rank sets `NCCL_IB_HCA` to the RDMA devices of the VFs in its own pod. The worker runs sshd on port 22, which is the default:

{{< code language="yaml" title="nccl-test.yaml" open="false" >}}
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-test-vf
spec:
  slotsPerWorker: 8
  runPolicy:
    cleanPodPolicy: Running
  sshAuthMountPath: /root/.ssh
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          containers:
            - name: mpi-launcher
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              command: ["bash", "-c"]
              args:
                - |
                  set -e -o pipefail
                  NUM_GPUS=8
                  NUM_HOSTS=$(sed -n '$=' /etc/mpi/hostfile)
                  NP=$((NUM_HOSTS * NUM_GPUS))
                  # shellcheck disable=SC2013
                  until (for host in $(awk '{print $1}' /etc/mpi/hostfile); do ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$host" exit 2>/dev/null || exit 1; done); do
                    echo "Waiting for workers to be ready..."
                    sleep 5
                  done
                  # Each rank uses only the RDMA devices of the VFs in its own pod (net1 to net16).
                  # The 40 GB GPUs cannot hold 16 GiB buffers with validation (-c 1), so the test stops at 8 GiB.
                  # shellcheck disable=SC2016
                  mpirun --allow-run-as-root --hostfile /etc/mpi/hostfile \
                    -mca coll ^hcoll \
                    -np "$NP" -npernode "$NUM_GPUS" --bind-to numa \
                    -x NCCL_DEBUG=WARN \
                    -x NCCL_IB_SPLIT_DATA_ON_QPS=0 \
                    -x NCCL_IB_QPS_PER_CONNECTION=4 \
                    -x NCCL_IB_GID_INDEX=3 \
                    -x NCCL_IB_TC=41 \
                    -x NCCL_IB_SL=0 \
                    -x NCCL_IB_TIMEOUT=22 \
                    -x UCX_TLS=tcp \
                    -x UCX_NET_DEVICES=eth0 \
                    bash -c 'export NCCL_IB_HCA="=$(basename -a /sys/class/net/net*/device/infiniband/* | paste -sd, -)"; exec /workspace/nccl-tests/build/all_reduce_perf -b 4G -e 8G -f 2 -g 1 -c 1'
    Worker:
      replicas: 2
      template:
        metadata:
          annotations:
            k8s.v1.cni.cncf.io/networks: rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf,rdma-vf
        spec:
          nodeSelector:
            node.kubernetes.io/instance-type: BM.GPU.B4.8
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          volumes:
            - name: shm
              emptyDir:
                medium: Memory
                sizeLimit: 32Gi
          containers:
            - name: mpi-worker
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              command: ["/bin/bash", "-c", "mkdir -p /var/run/sshd; /usr/sbin/sshd -D"]
              securityContext:
                capabilities:
                  add: ["IPC_LOCK"]
              volumeMounts:
                - name: shm
                  mountPath: /dev/shm
              resources:
                limits:
                  nvidia.com/gpu: 8
                  nvidia.com/rdma-vf: 16
{{< /code >}}

This is the result:

```
#       size         count      type   redop    root     time   algbw   busbw  #wrong     time   algbw   busbw  #wrong
  4294967296    1073741824     float     sum      -1  42530.7  100.99  189.35       0  42573.0  100.88  189.16       0
  8589934592    2147483648     float     sum      -1  84524.1  101.63  190.55       0  84890.4  101.19  189.73       0
```

| Setup | `busbw` at 8 GiB |
|---|---|
| `hostNetwork`, `privileged` (part 1) | 190.54 GB/s |
| `hostNetwork`, CRI-O fix (part 1) | 190.36 GB/s |
| 1 VF per PF | 190.55 GB/s |

A second run with `NCCL_DEBUG=INFO` gave 190.78 GB/s. NCCL merged the two VFs of each NIC into one virtual device. It did the same with the PFs in [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/). All 16 channels used GPUDirect RDMA:

```
NCCL INFO NET/IB : Made virtual device [16] name=mlx5_18+mlx5_19 speed=200000 ndevs=2 rail=-1 plane=16385
NCCL INFO Channel 00/0 : 1[1] -> 8[0] [receive] via NET/IB/16/GDRDMA/flush=Always
```

Each VF is its own RDMA device, so its GID index does not depend on other pods. Every VF in these tests had its GID at index 3.

The port problem of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/) is gone, and a pod that asked for GPUs got only its own GPUs. The sshd of each worker used port 22. Each worker in the two-job runs below saw only its own 4 GPUs.

## Trade-offs of 1 VF per PF

### Splitting the rails

With 1 VF per PF, a node has 16 VFs, so only one pod per node can get every rail. For two jobs per node, each job asked for 8 VFs. I ran these jobs on the nodes of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/). Both jobs started. Each pod got 8 VF interfaces, on the rails of its VFs. These are the pods on one node:

| Job | GPUs | Rails of its VFs |
|---|---|---|
| First | 2, 3, 4, 5 | `rdma0`, `rdma1`, `rdma2`, `rdma4`, `rdma8`, `rdma11`, `rdma12`, `rdma14` |
| Second | 0, 1, 6, 7 | `rdma3`, `rdma5`, `rdma6`, `rdma7`, `rdma9`, `rdma10`, `rdma13`, `rdma15` |

By PCIe root, the two jobs got these devices:

[![Which GPUs and VFs the two jobs got on one node, by PCIe root](/images/vf-split-rails.png)](/images/vf-split-rails.png)

The VFs did not follow the GPUs. In [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), NCCL put GPUs 0, 1, 6 and 7 on `rdma0` to `rdma3` and `rdma12` to `rdma15`. The other 4 GPUs used `rdma4` to `rdma11`. Here, each job got VFs on NICs on both sides. The two ports of one NIC sometimes went to different jobs.

On this node, each job had only 3 VFs on the PCIe roots of its GPUs. Those were `rdma4`, `rdma8` and `rdma11` for the first job, and `rdma3`, `rdma13` and `rdma15` for the second. NCCL sent all the network traffic of each job on this node through these 3 VFs, with GPUDirect RDMA. On the other node, the second job also used NICs on other roots for 2 of its GPUs. NCCL uses GPUDirect RDMA only up to a set distance between the NIC and the GPU. `NCCL_NET_GDR_LEVEL` sets that distance, and by default NCCL picks it from the topology. Without GPUDirect RDMA, the data goes through CPU memory.

[![The 4 PCIe roots of one BM.GPU.B4.8 node, each with 2 GPUs and 2 NICs, and the two data paths between a GPU and a NIC](/images/gpu-nic-topology.png)](/images/gpu-nic-topology.png)

The bandwidth dropped:

| Job | `busbw` at 8 GiB, out of place | In place |
|---|---|---|
| First | 43.71 GB/s | 40.72 GB/s |
| Second | 26.77 GB/s | 26.89 GB/s |

With the CRI-O fix of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), two jobs like these got 96.40 and 96.36 GB/s at the same time.

One job alone, with the same request, got 96.22 GB/s. The kubelet gave it GPUs 0 to 3, and 5 or 6 of its 8 VFs on their PCIe roots. Every NCCL channel used GPUDirect RDMA. So without the Topology Manager, the result depends on which VFs the pod gets.

### Aligning the VFs with the Topology Manager

The kubelet has a Topology Manager that aligns devices by NUMA node. It is off by default, with the policy `none`. On these nodes, each NUMA node with GPUs has 2 GPUs and the 2 NICs next to them:

| NUMA node | GPUs | Rails |
|---|---|---|
| 1 | 2, 3 | `rdma4` to `rdma7` |
| 3 | 0, 1 | `rdma0` to `rdma3` |
| 5 | 6, 7 | `rdma12` to `rdma15` |
| 7 | 4, 5 | `rdma8` to `rdma11` |

So on these nodes, aligning by NUMA node also puts each GPU next to its NIC. I added two settings to `/etc/kubernetes/kubelet-config.json` on both GPU nodes and restarted the kubelet:

```json
  "topologyManagerPolicy": "restricted",
  "topologyManagerScope": "pod"
```

The kubelet logged the new policy:

```
"Creating topology manager with policy per scope" topologyPolicyName="restricted" topologyScopeName="pod" topologyPolicyOptions={"PreferClosestNUMA":false,"MaxAllowableNUMANodes":8}
```

With `restricted`, the kubelet admits a pod only if it can align all of its devices. They must fit on the smallest set of NUMA nodes. Otherwise, it rejects the pod. I ran the same jobs again:

| Run with 4 GPUs and 8 VFs per node | Policy `none` | Policy `restricted` |
|---|---|---|
| One job alone | 96.22 GB/s | 96.66 GB/s |
| Two jobs at the same time | 43.71 and 26.77 GB/s | 96.28 and 96.35 GB/s |

Every pod got its 4 GPUs and its 8 VFs on the same 2 NUMA nodes. In the two-job run, one job got NUMA nodes 5 and 7, and the other got 1 and 3. Every NCCL channel used GPUDirect RDMA. The results match the CRI-O fix of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/).

`restricted` has a downside too, because it rejects pods that it cannot align. A job with 4 GPUs and 16 VFs per node is an example. The VFs need all 4 NUMA nodes with NICs, but the GPUs need only 2. The scheduler placed its workers, and then the kubelet rejected them:

```
Warning   TopologyAffinityError   Resources cannot be allocated with Topology locality
```

The scheduler does not know about NUMA nodes, so it cannot avoid this. The job with 8 GPUs and 16 VFs still ran, at 189.06 GB/s.

The policy `best-effort` does not reject pods. It looks for the same alignment, but the kubelet admits the pod even when it cannot align it. The pod then gets some devices from other NUMA nodes, with no error. Such a job can run as slowly as with `none`. I did not test `best-effort`, but the [Topology Manager documentation](https://kubernetes.io/docs/tasks/administer-cluster/topology-manager/) describes it.

I changed the kubelet configuration by hand on the two nodes, and I put it back after the tests. For real use, the change belongs in the node setup.

## Two VFs per PF

With 2 VFs per PF, two pods per node can each get a VF on every rail. I changed `numVfs` to 2 in the node policy:

{{< code language="yaml" title="sriov-network-node-policy-2vf.yaml" open="false" >}}
# Same as sriov-network-node-policy.yaml, with 2 VFs per PF.
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: bm-gpu-b4-8
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:0c:00.0"
      - "0000:0c:00.1"
      - "0000:16:00.0"
      - "0000:16:00.1"
      - "0000:47:00.0"
      - "0000:47:00.1"
      - "0000:4b:00.0"
      - "0000:4b:00.1"
      - "0000:89:00.0"
      - "0000:89:00.1"
      - "0000:93:00.0"
      - "0000:93:00.1"
      - "0000:c3:00.0"
      - "0000:c3:00.1"
      - "0000:d1:00.0"
      - "0000:d1:00.1"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf
  # The operator creates the VFs. Nothing else may write sriov_numvfs.
  externallyManaged: false
{{< /code >}}

This time the operator drained each node, one at a time, for about 2 minutes each. Neither node rebooted. Each node then offered 32 `nvidia.com/rdma-vf`.

### One resource of 32 VFs

I started two pods per node with 16 VFs each. The kubelet does not know which rail a VF is on. Each pod got both VFs of 4 or 5 PFs, and no VF on 4 or 5 other rails. Pods 1 and 2 ran on one node, and pods 3 and 4 on the other:

| Pod | Rails with 2 VFs | Rails with no VF |
|---|---|---|
| 1 | 4 | `rdma0`, `rdma2`, `rdma3`, `rdma6` |
| 2 | 4 | `rdma5`, `rdma10`, `rdma11`, `rdma12` |
| 3 | 5 | `rdma3`, `rdma5`, `rdma7`, `rdma9`, `rdma12` |
| 4 | 5 | `rdma1`, `rdma4`, `rdma6`, `rdma10`, `rdma11` |

### One resource for each rail

The fix is one resource for each rail. I replaced the node policy with 16 policies, one for each PF. Each one asks for 2 VFs and has its own resource name, from `rdma-vf-0` to `rdma-vf-15`:

{{< code language="yaml" title="sriov-node-policies-per-rail.yaml" open="false" >}}
# One policy per rail PF (rdma0 to rdma15), each with 2 VFs and its own resource.
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-0
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:0c:00.0"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-0
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-1
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:0c:00.1"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-1
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-2
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:16:00.0"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-2
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-3
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:16:00.1"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-3
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-4
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:47:00.0"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-4
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-5
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:47:00.1"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-5
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-6
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:4b:00.0"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-6
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-7
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:4b:00.1"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-7
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-8
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:89:00.0"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-8
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-9
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:89:00.1"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-9
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-10
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:93:00.0"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-10
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-11
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:93:00.1"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-11
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-12
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:c3:00.0"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-12
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-13
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:c3:00.1"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-13
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-14
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:d1:00.0"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-14
  externallyManaged: false
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-15
  namespace: nvidia-network-operator
spec:
  deviceType: netdevice
  mtu: 4220
  nicSelector:
    vendor: "15b3"
    rootDevices:
      - "0000:d1:00.1"
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  isRdma: true
  numVfs: 2
  priority: 90
  resourceName: rdma-vf-15
  externallyManaged: false
{{< /code >}}

Each resource gets its own network:

{{< code language="yaml" title="sriov-networks-per-rail.yaml" open="false" >}}
# One network per rail, for the resource of that rail.
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-0
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-0
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-1
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-1
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-2
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-2
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-3
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-3
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-4
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-4
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-5
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-5
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-6
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-6
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-7
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-7
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-8
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-8
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-9
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-9
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-10
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-10
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-11
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-11
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-12
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-12
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-13
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-13
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-14
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-14
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf-15
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf-15
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
{{< /code >}}

A pod asks for 1 VF of each resource and lists the 16 networks in rail order. This is the first of the two jobs:

{{< code language="yaml" title="nccl-vf-a-per-rail.yaml" open="false" >}}
# Job a with 4 GPUs and one VF on every rail per node. Two such jobs run at the same time.
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-vf-a
spec:
  slotsPerWorker: 4
  runPolicy:
    cleanPodPolicy: Running
  sshAuthMountPath: /root/.ssh
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          containers:
            - name: mpi-launcher
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              command: ["bash", "-c"]
              args:
                - |
                  set -e -o pipefail
                  NUM_GPUS=4
                  NUM_HOSTS=$(sed -n '$=' /etc/mpi/hostfile)
                  NP=$((NUM_HOSTS * NUM_GPUS))
                  # shellcheck disable=SC2013
                  until (for host in $(awk '{print $1}' /etc/mpi/hostfile); do ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$host" exit 2>/dev/null || exit 1; done); do
                    echo "Waiting for workers to be ready..."
                    sleep 5
                  done
                  # Each rank uses only the RDMA devices of the VFs in its own pod (net1 to net16).
                  # The 40 GB GPUs cannot hold 16 GiB buffers with validation (-c 1), so the test stops at 8 GiB.
                  # shellcheck disable=SC2016
                  mpirun --allow-run-as-root --hostfile /etc/mpi/hostfile \
                    -mca coll ^hcoll \
                    -np "$NP" -npernode "$NUM_GPUS" --bind-to numa \
                    -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=INIT,NET \
                    -x NCCL_IB_SPLIT_DATA_ON_QPS=0 \
                    -x NCCL_IB_QPS_PER_CONNECTION=4 \
                    -x NCCL_IB_GID_INDEX=3 \
                    -x NCCL_IB_TC=41 \
                    -x NCCL_IB_SL=0 \
                    -x NCCL_IB_TIMEOUT=22 \
                    -x UCX_TLS=tcp \
                    -x UCX_NET_DEVICES=eth0 \
                    bash -c 'export NCCL_IB_HCA="=$(basename -a /sys/class/net/net*/device/infiniband/* | paste -sd, -)"; exec /workspace/nccl-tests/build/all_reduce_perf -b 8G -e 8G -n 300 -g 1 -c 1'
    Worker:
      replicas: 2
      template:
        metadata:
          annotations:
            k8s.v1.cni.cncf.io/networks: rdma-vf-0,rdma-vf-1,rdma-vf-2,rdma-vf-3,rdma-vf-4,rdma-vf-5,rdma-vf-6,rdma-vf-7,rdma-vf-8,rdma-vf-9,rdma-vf-10,rdma-vf-11,rdma-vf-12,rdma-vf-13,rdma-vf-14,rdma-vf-15
        spec:
          nodeSelector:
            node.kubernetes.io/instance-type: BM.GPU.B4.8
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          volumes:
            - name: shm
              emptyDir:
                medium: Memory
                sizeLimit: 32Gi
          containers:
            - name: mpi-worker
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              command: ["/bin/bash", "-c", "mkdir -p /var/run/sshd; /usr/sbin/sshd -D"]
              securityContext:
                capabilities:
                  add: ["IPC_LOCK"]
              volumeMounts:
                - name: shm
                  mountPath: /dev/shm
              resources:
                limits:
                  nvidia.com/gpu: 4
                  nvidia.com/rdma-vf-0: 1
                  nvidia.com/rdma-vf-1: 1
                  nvidia.com/rdma-vf-2: 1
                  nvidia.com/rdma-vf-3: 1
                  nvidia.com/rdma-vf-4: 1
                  nvidia.com/rdma-vf-5: 1
                  nvidia.com/rdma-vf-6: 1
                  nvidia.com/rdma-vf-7: 1
                  nvidia.com/rdma-vf-8: 1
                  nvidia.com/rdma-vf-9: 1
                  nvidia.com/rdma-vf-10: 1
                  nvidia.com/rdma-vf-11: 1
                  nvidia.com/rdma-vf-12: 1
                  nvidia.com/rdma-vf-13: 1
                  nvidia.com/rdma-vf-14: 1
                  nvidia.com/rdma-vf-15: 1
{{< /code >}}

I deleted the old policy first, so the operator created these VFs from zero. With 2 pods per node, every pod got one VF on every rail. `net1` to `net16` were in rail order.

Then I ran the two jobs with 4 GPUs per node at the same time:

| Job | `busbw` at 8 GiB, out of place | In place |
|---|---|---|
| First | 96.28 GB/s | 96.32 GB/s |
| Second | 96.35 GB/s | 96.37 GB/s |

Each worker used the 4 NICs next to its GPUs. The worker with GPUs 4 to 7 used the NICs of `rdma8` to `rdma15`. The worker with GPUs 0 to 3 used `rdma0` to `rdma7`. All 8 channels of each job used GPUDirect RDMA. The results match the CRI-O fix of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/). The Topology Manager of the kubelet stayed at its default policy, `none`.

A job with 8 GPUs per node on the same setup got 190.04 GB/s.

## Trade-offs of 2 VFs per PF

### Two pods share each port

The two VFs of a PF share its port. I ran `ib_write_bw` on two VF pairs of the same PF at the same time:

{{< code language="bash" title="share-rail.sh" open="false" >}}
#!/bin/bash
# Two VF pairs on the same rail at the same time: vf-n1a to vf-n2a and vf-n1b to vf-n2b.
# Usage: share-rail.sh <PF PCI address, for example 0c:00.0>
set -u
pf="0000:$1"
declare -A ip dev
for p in vf-n1a vf-n1b vf-n2a vf-n2b; do
  read -r _ _ ip[$p] dev[$p] < <(./vf-map.sh "$p" | awk -v pf="$pf" '$1 == pf')
  echo "$p ${dev[$p]} ${ip[$p]}"
done
kubectl exec vf-n2a -- ib_write_bw -d "${dev[vf-n2a]}" -x 3 -F --report_gbits -D 10 --tclass=41 -p 18600 >/dev/null 2>&1 &
kubectl exec vf-n2b -- ib_write_bw -d "${dev[vf-n2b]}" -x 3 -F --report_gbits -D 10 --tclass=41 -p 18601 >/dev/null 2>&1 &
sleep 2
kubectl exec vf-n1a -- ib_write_bw -d "${dev[vf-n1a]}" -x 3 -F --report_gbits -D 10 --tclass=41 -p 18600 "${ip[vf-n2a]}" > /tmp/share-a.log 2>&1 &
kubectl exec vf-n1b -- ib_write_bw -d "${dev[vf-n1b]}" -x 3 -F --report_gbits -D 10 --tclass=41 -p 18601 "${ip[vf-n2b]}" > /tmp/share-b.log 2>&1 &
wait
echo "pair a: $(awk '/^ 65536/ {print $4" Gb/s"}' /tmp/share-a.log)"
echo "pair b: $(awk '/^ 65536/ {print $4" Gb/s"}' /tmp/share-b.log)"
cat /tmp/share-a.log /tmp/share-b.log >&2
{{< /code >}}

| Rail | One pair alone | Two pairs at the same time |
|---|---|---|
| `rdma0` | 96.88 Gb/s | 48.96 and 49.00 Gb/s |
| `rdma8` | 96.87 Gb/s | 49.02 and 48.99 Gb/s |

In the NCCL test, the two jobs used different NICs on each node, so they did not share a port. Two jobs that use the same NICs split the bandwidth of each port.

### Changing the VF count drains the nodes

Going from 1 to 2 VFs per PF drained each node for about 2 minutes. Creating VFs on PFs that had none did not drain them. A cluster that runs jobs has to plan for these drains.

### Deleting the node policy can reset the MTU

I deleted the node policy after the `rdmaQoS` tests, on the nodes of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/). About two minutes later, the VFs were gone. All 16 rails also had MTU 1500 instead of 4220. The `ResetSriovDevice` function of the config daemon sets the MTU of the PF and removes its VFs. It uses 1500 when it has no saved MTU for the PF. The RoCE MTU of the rails dropped from 4096 to 1024 bytes. One flow on a rail then gave 88.58 Gb/s instead of 96.87 Gb/s. NCCL `all_reduce` on 16 GPUs dropped from about 190 to 168 GB/s. After a reboot, the rails had MTU 4220 again.

### More moving parts

Per-rail resources need 16 policies and 16 networks, and every pod lists 16 resources. Many parts have to work for a pod to get its rails. They are the SR-IOV Network Operator, its config daemon, the device plugin, Multus, the CNI plugins and NVIDIA IPAM. On the 3 nodes without GPUs, Multus restarted 2 to 4 times right after it started. The last restart on each of them was `OOMKilled`. Its default memory limit is 50Mi.

### Pod Security

The Baseline Pod Security Standard rejects the pod only for `IPC_LOCK`:

```
Error from server (Forbidden): error when creating "psa-vf-pod.yaml": pods "vf-n1" is forbidden: violates PodSecurity "baseline:latest": non-default capabilities (container "rdma" must not include "IPC_LOCK" in securityContext.capabilities.add)
```

These nodes do not need `IPC_LOCK`. A CRI-O drop-in on them sets an unlimited `memlock` limit for every container. Baseline admitted the pod without it:

```
pod/vf-n1 created (server dry run)
```

On nodes with a lower limit, the pod needs a higher `memlock` limit or `IPC_LOCK`. `IPC_LOCK` needs the Privileged level.

## The exclusive mode with the RDMA CNI

Everything above ran in the shared RDMA namespace mode. The RDMA CNI was installed on the nodes, but the network did not call it. I also tested the other setup. It is the exclusive mode, with the RDMA CNI in the chain. I tested it with 1 VF per PF.

The mode is the `netns_mode` parameter of `ib_core`. On these nodes, `/etc/modprobe.d/ib_core.conf` sets it, and the initramfs has a copy of that file. So I changed the file, ran `update-initramfs` and rebooted the node:

```bash
echo "options ib_core netns_mode=0" | sudo tee /etc/modprobe.d/ib_core.conf
sudo update-initramfs -u -k "$(uname -r)"
sudo systemctl reboot
```

After the reboot, `rdma system show` printed `netns exclusive`. The operator created the VFs again by itself.

The network is the same as before, with the RDMA CNI added. It moves the RDMA device of the VF into the pod:

{{< code language="yaml" title="sriov-network-exclusive.yaml" open="false" >}}
# Exclusive RDMA mode: the RDMA CNI moves the VF RDMA device into the pod.
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "rdma"
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
{{< /code >}}

The same check pod printed this:

```
RDMA netns mode: N (Y = shared, N = exclusive)
RDMA devices visible in the pod: 1
Character devices: rdma_cm uverbs31 umad31 
VF interface net1: ip=192.168.0.18 rdma_device=mlx5_31
  gid 0: fe80:0000:0000:0000:4044:00ff:fecb:f958 IB/RoCE v1
  gid 1: fe80:0000:0000:0000:4044:00ff:fecb:f958 RoCE v2
  gid 2: 0000:0000:0000:0000:0000:ffff:c0a8:0012 IB/RoCE v1
  gid 3: 0000:0000:0000:0000:0000:ffff:c0a8:0012 RoCE v2
PASS: GID index 3 of mlx5_31 is the RoCE v2 GID of 192.168.0.18
```

The pod now sees only its own VF. The GID is the same as in the shared mode.

### The differences

I ran both setups on the same day, with one pod of 16 VFs on each node. Only the shared-mode result with the RDMA CNI comes from an earlier test:

| | Shared mode, no RDMA CNI | Exclusive mode, RDMA CNI |
|---|---|---|
| RDMA devices of the pod in sysfs | 34 (18 PFs and 16 VFs) | 16, its own VFs |
| `rdma dev` and `rdma link` in the pod | 34 | 16 |
| RDMA devices the pod can open | 16 | 16 |
| GID index 3 of each VF | RoCE v2 GID of its address | The same |
| RDMA devices on the node while the pod runs | 34 | 18, only the PFs |
| A `privileged` `hostNetwork` pod | Sees 34 devices and can open the VF of another pod | Sees 18 devices, and the VF `wasn't found` |
| A VF pod with no RDMA CNI in its network | Works | Gets the interface and an address, but 0 RDMA devices |
| A network with the RDMA CNI | The pod stays in `ContainerCreating` | Works |
| `ib_write_bw` on each rail | 96.87 to 96.88 Gb/s | 43.20 to 59.45 Gb/s |

So the exclusive mode isolates better. A pod sees no RDMA device of the node or of another pod. In the shared mode, the pod sees them all in sysfs. It has device files only for its own VFs. The `privileged` `hostNetwork` pod of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/) is different. It has every device file, so it could open the VF of another pod.

### The traffic class in the exclusive mode

The last row is the problem. In the exclusive mode, every rail gave about half of its bandwidth. I ran the 16 rails 5 times, once in the other direction. Every result was between 43.20 and 59.45 Gb/s. The PFs of the same nodes still gave 96.87 to 96.88 Gb/s in `hostNetwork` pods.

The VF traffic left the node with the wrong traffic class. The tests ask for traffic class 41, which is DSCP 10. On these NICs, DSCP 10 maps to priority 0, and DSCP 0 maps to priority 1. I ran `ib_write_bw --tclass=41` for 10 seconds on one rail and read the counters of the PF with `ethtool -S`:

| Sender | Packets on priority 0 | Packets on priority 1 | Result |
|---|---|---|---|
| PF, `hostNetwork` pod, exclusive mode | 29,563,232 | 22 | 96.87 Gb/s |
| VF, exclusive mode | 0 | 29,676,723 | 51.78 Gb/s |
| VF, shared mode | 29,563,058 | 0 | 96.87 Gb/s |

So the VF sent its packets with DSCP 0 in the exclusive mode. The network between the nodes dropped part of them. In one run, the sender sent 29,684,122 packets and the receiver got 29,566,844. Neither NIC counted a discard. The receiver counted 11,649 out-of-sequence packets in another run of 10 seconds.

DOCA-OFED has a sysfs file that forces one traffic class for an RDMA device, `/sys/class/infiniband/<device>/tc/1/traffic_class`. It showed the change. My script printed the file of the 16 VFs in brackets, with the count of each value:

```
02:30:43 VF devices:      16 [] 
### in pod vf-n1:      16 [Global tclass=0] 
```

The file was empty for all 16 new VFs. It read `Global tclass=0` for all 16 after the RDMA CNI moved them into a pod. It stayed that way on the node after I deleted the pod. In the shared mode, the file stayed empty on the node, and the pod had no such file.

More queue pairs hid the loss. With 4 queue pairs (`-q 4`), the same rail reached 97.97 Gb/s.

The RDMA CNI writes this file itself. The RDMA CNI in Network Operator 26.7.1 has an optional `rdmaQoS` setting. Before it moves the device into the pod, it writes the `tc` value of that setting to the file. The network above has no `rdmaQoS`, so the RDMA CNI wrote 0. When the pod goes away, it writes back the value that it read first. It reads the empty file as 0, so 0 stays on the node.

So I added `rdmaQoS` with traffic class 41 to the RDMA CNI in the network:

{{< code language="yaml" title="sriov-network-exclusive-qos.yaml" open="false" >}}
# Exclusive RDMA mode: the RDMA CNI moves the VF RDMA device into the pod.
# rdmaQoS sets the traffic class that the RDMA CNI writes for the device.
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vf
  namespace: nvidia-network-operator
spec:
  resourceName: rdma-vf
  networkNamespace: default
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "sriov-pool"
    }
  metaPlugins: |
    {
      "type": "tuning",
      "sysctl": {
        "net.ipv4.conf.all.rp_filter": "0",
        "net.ipv4.conf.IFNAME.arp_announce": "2",
        "net.ipv4.conf.IFNAME.arp_filter": "1",
        "net.ipv4.conf.IFNAME.arp_ignore": "1",
        "net.ipv4.conf.IFNAME.rp_filter": "0",
        "net.ipv4.conf.IFNAME.accept_local": "1"
      }
    },
    {
      "type": "rdma",
      "rdmaQoS": {
        "tc": 41
      }
    },
    {
      "type": "sbr",
      "addSourceHints": true
    }
{{< /code >}}

I ran this on the nodes of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), with the same Network Operator. Both modes ran on the same day. Without `rdmaQoS`, the rails gave 50.60 to 59.02 Gb/s in two runs. With it, every VF in the pods read `Global tclass=41`. Every rail gave 96.78 to 96.88 Gb/s. In the shared mode, the rails gave 96.85 to 96.88 Gb/s. These are the counters of one rail in the exclusive mode, as above:

| Sender | Traffic class file | Packets on priority 0 | Packets on priority 1 | Result |
|---|---|---|---|---|
| VF, no `rdmaQoS` | `Global tclass=0` | 0 | 29,678,580 | 54.40 Gb/s |
| VF, `rdmaQoS` with `tc` 41 | `Global tclass=41` | 29,562,736 | 0 | 96.86 Gb/s |
| PF, `hostNetwork` pod | Empty | 29,563,121 | 22 | 96.87 Gb/s |

The README of the RDMA CNI shows `rdmaQoS` under `args.cni`. I tried that too, and the pods still got `Global tclass=0`. The code reads `rdmaQoS` only at the top level of the plugin, as in the file above. I reported the default of 0 and the README example in [Network Operator issue #3710](https://github.com/Mellanox/network-operator/issues/3710).

### NCCL in both modes

The NCCL job sets 4 queue pairs for each connection. These are the results at 8 GiB, out of place and in place. All of them ran on one day, on the nodes of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/):

| Setup | `busbw` at 8 GiB | Priority of the packets |
|---|---|---|
| Shared mode, no RDMA CNI | 188.87 / 190.02 GB/s | 0 |
| Exclusive mode, RDMA CNI without `rdmaQoS` | 190.77 / 190.71 GB/s | 1 |
| Exclusive mode, RDMA CNI with `rdmaQoS`, first run | 190.68 / 190.62 GB/s | 0 |
| Exclusive mode, RDMA CNI with `rdmaQoS`, second run | 189.86 / 190.55 GB/s | 0 |

I counted the packets on the 16 rails of one node. In each run, at most 83 packets went to the other priority. With 4 queue pairs, NCCL got the full bandwidth even on priority 1.

So the exclusive mode needs `rdmaQoS` with the traffic class of the jobs. With it, `ib_write_bw` got the full bandwidth in both modes, like NCCL.

## When VFs fit

1 VF per PF worked well for one job per node that uses all 16 rails. It got the full bandwidth of `hostNetwork` without `privileged`. The GID index of each VF stayed at 3. With the `restricted` Topology Manager policy, two jobs per node also got the full bandwidth.

All of this is for the shared RDMA mode without the RDMA CNI. In the exclusive mode with the RDMA CNI, the pods saw fewer devices. The network then needs `rdmaQoS`, or the RDMA CNI forces traffic class 0 on each VF.

For two jobs per node, 2 VFs per PF with one resource for each rail worked. Each job got every rail and used the NICs next to its GPUs, at the full bandwidth. In return, it needs 16 policies and networks, and drains when the VF count changes. Two pods also share each port.
