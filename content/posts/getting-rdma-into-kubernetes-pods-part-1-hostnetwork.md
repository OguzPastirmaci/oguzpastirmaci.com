+++
title = "Getting RDMA into Kubernetes Pods, Part 1: hostNetwork"
date = "2026-11-12"
draft = false
ogImage = "/images/og/getting-rdma-into-kubernetes-pods-part-1-hostnetwork.png"
tags = ["rdma", "kubernetes", "nccl", "gpu", "oke"]
description = "Part 1 of a series on RDMA in Kubernetes pods for GPU training. What a hostNetwork pod needs for RDMA, the NCCL baseline on two A100 nodes, and what the extra settings cost."
+++

There are four common ways to give a Kubernetes pod RDMA for GPU training:

1. The pod shares the network of the node with `hostNetwork`.
2. The pod gets an SR-IOV virtual function (VF) on each rail.
3. The pod gets the RDMA devices of the rails and an IPvlan interface on each rail.
4. A DRA driver gives the pod its own interface on each rail.

This series tests all four on A100 nodes with the same setup, so the results can be compared. This part ran on a second pair of nodes in a new cluster.

This first part covers `hostNetwork`. It is the simplest way, and it gets the full bandwidth of the nodes. NCCL `all_reduce` reached 190 GB/s bus bandwidth at 8 GiB on 16 GPUs. But `hostNetwork: true` alone does not give a pod RDMA. The settings that make it work have costs, and one of them is easy to miss. A privileged pod can use every GPU on the node, not only the GPUs it asked for. This post also shows a fix that works without `privileged`.

Earlier posts cover some parts of this topic, so this post links to them:

- [Why torchrun Can't Find Node Two on the Host Network](/posts/why-torchrun-cant-find-node-two-on-the-host-network/) covers the host name problem with PyTorch.
- [ARP, rp_filter and accept_ra for RDMA Pods on Kubernetes](/posts/arp-rp-filter-and-accept-ra-for-rdma-pods-on-kubernetes/) covers the sysctls of the rails.
- [Why Pods See Zero RoCE GIDs on DOCA-OFED](/posts/why-pods-see-zero-roce-gids-on-doca-ofed/) covers why a pod off the host network needs its own netdevs.

Every manifest and script in this post ran on the test cluster. Long files are collapsed, so click a file name to open it.

## The test setup

- 4 x BM.GPU.B4.8 on OKE v1.36.4, with CRI-O 1.36.3.
- Each node has 8 A100-SXM4-40GB GPUs and 16 RoCE rails at 100 Gb/s, `rdma0` to `rdma15`. The rails are the two ports of 8 ConnectX-5 Ex NICs, all in one IPv4 subnet.
- Ubuntu 24.04 with kernel 6.17, DOCA-OFED 3.5.0 and NVIDIA driver 595.112.07, with `nvidia_peermem` loaded
- The NVIDIA GPU Operator 26.3.3, which gives GPUs to pods through CDI, and the MPI Operator 0.8.2
- The public image `iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0`, with NCCL 2.32.3, nccl-tests 2.21.1, perftest 6.28 and Open MPI 5.0.10rc2

These results are for a single plane network with IPv4 rails, like the one these nodes use. The same logic applies to Oracle Cloud shapes on the multiplanar network, but their configuration is different.

The node configuration already sets `arp_ignore=1`, `arp_announce=2` and `rp_filter=0` on every rail. The ARP post explains which of these values matter.

All test pods and jobs ran in a namespace named `rdma-hostnet`, which I created first.

## What the pod needs

I started with a plain pod and added one setting at a time. Each step ran one pod on each node. This is the step with all the settings:

{{< code language="yaml" title="rdma-probe-privileged.yaml" open="false" >}}
---
apiVersion: v1
kind: Pod
metadata:
  name: rdma-probe-privileged-n1
  namespace: rdma-hostnet
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: "10.140.86.84"
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  containers:
    - name: rdma
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
      volumeMounts:
        - { name: dev-infiniband, mountPath: /dev/infiniband }
  volumes:
    - name: dev-infiniband
      hostPath: { path: /dev/infiniband }
---
apiVersion: v1
kind: Pod
metadata:
  name: rdma-probe-privileged-n2
  namespace: rdma-hostnet
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: "10.140.89.190"
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  containers:
    - name: rdma
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
      volumeMounts:
        - { name: dev-infiniband, mountPath: /dev/infiniband }
  volumes:
    - name: dev-infiniband
      hostPath: { path: /dev/infiniband }
{{< /code >}}

In each pod, I ran this script:

{{< code language="bash" title="probe.sh" open="false" >}}
#!/bin/bash
# Print what an RDMA test needs to see inside the pod.
rails=(/sys/class/net/rdma*)
[ -e "${rails[0]}" ] || rails=()
devs=(/dev/infiniband/*)
[ -e "${devs[0]}" ] || devs=()
echo "hostname: $(hostname)"
echo "resolv.conf: $(grep -E '^(nameserver|search)' /etc/resolv.conf | tr '\n' ' ')"
echo "rdma netdevs: ${#rails[@]}"
echo "/dev/infiniband: ${#devs[@]} files"
echo "ibv_devices: $(ibv_devices 2>&1 | awk 'NR>2 {print $1}' | tr '\n' ' ')"
echo "ibv_devinfo mlx5_5:"
ibv_devinfo -d mlx5_5 2>&1 | head -4
echo "CapEff: $(grep CapEff /proc/self/status | awk '{print $2}')"
echo "memlock: $(ulimit -l)"
{{< /code >}}

Both nodes gave the same results:

| Pod | Rail netdevs | Files in `/dev/infiniband` | `ibv_devices` | `ibv_devinfo -d mlx5_5` |
|---|---|---|---|---|
| Pod network | 0 | 0 | None | `IB device 'mlx5_5' wasn't found` |
| `hostNetwork` | 16 | 0 | None | `IB device 'mlx5_5' wasn't found` |
| Plus a `hostPath` mount of `/dev/infiniband` | 16 | 39 | 18 devices | `Failed to open device` |
| Plus `privileged` | 16 | 39 | 18 devices | Works |
| `hostNetwork` and `privileged`, no `hostPath` mount | 16 | 37 | 18 devices | Works |

`hostNetwork` gives the pod the rail netdevs, but not the RDMA devices. `ibv_devices` listed no devices until the character devices in `/dev/infiniband` were in the container.

The `hostPath` mount adds the files, but the pod still cannot open them. The file permissions allow it:

```
crw-rw-rw- 1 root root 231, 192 Nov 13 09:44 /dev/infiniband/uverbs0
```

But `open()` fails:

```
PermissionError: [Errno 1] Operation not permitted: '/dev/infiniband/uverbs0'
```

The device cgroup of the container blocks it. A container can only open the devices that its runtime allows. A `hostPath` mount does not add to that list.

`privileged` removes that limit, and it also adds every device of the node to the container. That is why the last row works without the `hostPath` mount. It has 37 files, the 18 `uverbs` devices, the 18 `umad` devices and `rdma_cm`. The `hostPath` mount also brings the `by-ibdev` and `by-path` directories. CRI-O does this because `privileged_without_host_devices` is `false`, the default. Keep this in mind, because it matters again in the GPU section.

The pod also has to lock memory, because RDMA pins the buffers that it registers with the NIC. The usual way is the `IPC_LOCK` capability. `privileged` gives all capabilities, so `CapEff` went from `00000000a80425fb` to `000001ffffffffff`. On these nodes, a CRI-O drop-in also sets an unlimited `memlock` limit for every container. Stock CRI-O does not do that. So `ulimit -l` showed `unlimited` in every pod, privileged or not.

A device plugin can give a pod the RDMA devices without `privileged`. [The next part](/posts/getting-rdma-into-kubernetes-pods-part-2-sriov-vfs/) uses one. The fix section below shows another way, with CRI-O.

### Host name and DNS

A `hostNetwork` pod also gets the host name and the DNS settings of the node:

```
hostname: oke-cdhzek5e6za-niqfkyrmiba-s3zwzog2wia-0
resolv.conf: search njagol.oraclevcn.com nameserver 169.254.169.254
```

The pod on the pod network had its own name and the cluster DNS:

```
hostname: rdma-probe-pod-network-n1
resolv.conf: search rdma-hostnet.svc.cluster.local svc.cluster.local cluster.local njagol.oraclevcn.com nameserver 10.96.5.5
```

With the DNS settings of the node, the pod cannot resolve cluster names. In a `hostNetwork` pod, `getent hosts kubernetes.default.svc.cluster.local` got no answer. With `dnsPolicy: ClusterFirstWithHostNet`, it returned `10.96.0.1`. The host name stays the name of the node, and the torchrun post shows how that breaks PyTorch.

## The rails

Before NCCL, I tested each rail with `ib_write_bw` between the two probe pods:

{{< code language="bash" title="rails.sh" open="false" >}}
#!/bin/bash
# ib_write_bw on each rail, from the probe pod on node one to the probe pod on node two.
set -u
ns=rdma-hostnet
srv=rdma-probe-privileged-n2
cli=rdma-probe-privileged-n1
port=18515
for i in $(seq 0 15); do
  dev=$(kubectl -n $ns exec $srv -- ls "/sys/class/net/rdma$i/device/infiniband")
  ip=$(kubectl -n $ns exec $srv -- ip -4 -o addr show "rdma$i" | awk '{print $4}' | cut -d/ -f1)
  kubectl -n $ns exec $srv -- ib_write_bw -d "$dev" -x 3 -F --report_gbits -D 5 --tclass=41 -p $port >/dev/null 2>&1 &
  sleep 2
  out=$(kubectl -n $ns exec $cli -- ib_write_bw -d "$dev" -x 3 -F --report_gbits -D 5 --tclass=41 -p $port "$ip" 2>&1)
  wait
  echo "rdma$i $dev $ip $(echo "$out" | awk '/^ 65536/ {print $4" Gb/s"}')"
  printf '%s\n' "$out" >&2
  port=$((port + 1))
done
{{< /code >}}

My first run did not have `--tclass=41`, and it was uneven. The 16 rails gave 49.44 to 60.08 Gb/s. Other options without `--tclass` gave 55.75 to 97.95 Gb/s on `rdma0`. The NCCL jobs below set `NCCL_IB_TC=41`, and `ib_write_bw` uses traffic class 0 unless you pass `--tclass`. With `--tclass=41`, every rail gave 96.86 to 96.88 Gb/s.

## The NCCL baseline

The NCCL test is an MPIJob with two workers, one on each node, and 8 GPUs each:

{{< code language="yaml" title="nccl-hostnet.yaml" open="false" >}}
# NCCL all_reduce on 2 nodes x 8 GPUs. The workers use the node's network namespace.
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-hostnet
  namespace: rdma-hostnet
spec:
  slotsPerWorker: 8
  launcherCreationPolicy: WaitForWorkersReady
  runPolicy:
    cleanPodPolicy: Running
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          containers:
            - name: launcher
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              env:
                # Open MPI 5 takes the ssh port of the workers from this variable.
                - { name: PRTE_MCA_plm_ssh_args, value: "-p 2222" }
              command: ["bash", "-c"]
              args:
                - |
                  mpirun --allow-run-as-root \
                    -mca coll ^hcoll -mca plm_rsh_args "-p 2222" --hostfile /etc/mpi/hostfile \
                    -mca coll_hcoll_enable 0 \
                    -np 16 -npernode 8 --bind-to numa \
                    -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=INIT,NET \
                    -x NCCL_IB_SPLIT_DATA_ON_QPS=0 \
                    -x NCCL_IB_QPS_PER_CONNECTION=4 \
                    -x NCCL_IB_GID_INDEX=3 \
                    -x NCCL_IB_HCA==mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_14,mlx5_15,mlx5_16,mlx5_17,mlx5_9,mlx5_10,mlx5_11,mlx5_12 \
                    -x NCCL_IB_TC=41 \
                    -x NCCL_IB_SL=0 \
                    -x NCCL_IB_TIMEOUT=22 \
                    -x HCOLL_ENABLE_MCAST_ALL=0 \
                    -x UCX_TLS=tcp \
                    -x UCX_NET_DEVICES=eth0 \
                    /workspace/nccl-tests/build/all_reduce_perf -b 1G -e 8G -f 2 -g 1
    Worker:
      replicas: 2
      template:
        spec:
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
          tolerations:
            - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
          containers:
            - name: worker
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              # The node's own sshd already listens on port 22.
              command: ["bash", "-c", "mkdir -p /run/sshd && exec /usr/sbin/sshd -De -p 2222"]
              ports:
                - { name: ssh, containerPort: 2222 }
              securityContext:
                privileged: true
              resources:
                limits:
                  nvidia.com/gpu: 8
              volumeMounts:
                - { name: dev-infiniband, mountPath: /dev/infiniband }
                - { name: dshm, mountPath: /dev/shm }
          volumes:
            - { name: dev-infiniband, hostPath: { path: /dev/infiniband } }
            - { name: dshm, emptyDir: { medium: Memory } }
{{< /code >}}

The workers have the settings from the steps above, and three more:

- `dnsPolicy: ClusterFirstWithHostNet`, so that the workers can resolve the names of the job.
- sshd on port 2222, because the sshd of the node already uses port 22. The next section shows what happens on port 22.
- A memory-backed `emptyDir` on `/dev/shm`. A container gets 64 MiB by default, and NCCL needs more.

The `hostPath` mount is not needed on these nodes, as the steps showed.

The launcher stays on the pod network. It reaches the workers through the headless service of the job. For a `hostNetwork` worker, that name resolves to the IP address of the node.

This is the result, trimmed to the sizes from 2 GiB:

```
#       size         count      type   redop    root     time   algbw   busbw  #wrong     time   algbw   busbw  #wrong
  2147483648     536870912     float     sum      -1  21550.8   99.65  186.84       0  21308.0  100.78  188.97       0
  4294967296    1073741824     float     sum      -1  42386.7  101.33  189.99       0  42547.0  100.95  189.27       0
  8589934592    2147483648     float     sum      -1  84527.4  101.62  190.54       0  84638.4  101.49  190.29       0
```

At 8 GiB, the bus bandwidth was 190.54 GB/s.

NCCL used all 16 rails, with GPUDirect RDMA. It merged the two ports of each NIC into one virtual device of 200 Gb/s:

```
NCCL INFO NET/IB : Made virtual device [16] name=mlx5_5+mlx5_6 speed=200000 ndevs=2 rail=-1 plane=16385
NCCL INFO Channel 00/0 : 9[1] -> 0[0] [receive] via NET/IB/16/GDRDMA/flush=Always
```

The image also has an NCCL net plugin called SPCX. It is the [Spectrum-X NCCL plugin](https://networking-docs.nvidia.com/hpcxum/2.51/spectrum-x-nccl-plugin), and Oracle Cloud shapes on the multiplanar network use it. Here, it printed one `NET/MLX5` warning for each rail and then failed to initialize. The warnings are harmless. NCCL then used its built-in IB transport:

```
NCCL WARN NET/MLX5: Call to mlx5dv_devx_general_cmd failed with error Remote I/O error
NCCL ATTN Failed to initialize NET plugin SPCX
NCCL INFO Using network IB
```

### Without the memory-backed /dev/shm

I ran the same job without the `/dev/shm` volume. The workers had the default size:

```
Filesystem      Size  Used Avail Use% Mounted on
shm              64M     0   64M   0% /dev/shm
```

The launcher failed on every attempt, and the job ended as `Failed`. NCCL could not create its shared memory segments. Each one was larger than 64 MiB by itself:

```
NCCL WARN Error while creating shared memory segment /dev/shm/nccl-4ilNyk (size 68420264), error: No space left on device (28)
```

## What it costs

### Ports

A `hostNetwork` pod shares the ports of the node. By default, mpirun connects to sshd on port 22 of each worker. The node already runs its own sshd there. I ran the same job with sshd on port 22:

{{< code language="yaml" title="nccl-port22.yaml" open="false" >}}
# The same job with sshd on its default port 22.
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-port22
  namespace: rdma-hostnet
spec:
  slotsPerWorker: 8
  launcherCreationPolicy: WaitForWorkersReady
  runPolicy:
    cleanPodPolicy: Running
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          containers:
            - name: launcher
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              command: ["bash", "-c"]
              args:
                - |
                  mpirun --allow-run-as-root \
                    -mca coll ^hcoll -mca plm_rsh_args "-p 22" --hostfile /etc/mpi/hostfile \
                    -mca coll_hcoll_enable 0 \
                    -np 16 -npernode 8 --bind-to numa \
                    -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=INIT,NET \
                    -x NCCL_IB_SPLIT_DATA_ON_QPS=0 \
                    -x NCCL_IB_QPS_PER_CONNECTION=4 \
                    -x NCCL_IB_GID_INDEX=3 \
                    -x NCCL_IB_HCA==mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_14,mlx5_15,mlx5_16,mlx5_17,mlx5_9,mlx5_10,mlx5_11,mlx5_12 \
                    -x NCCL_IB_TC=41 \
                    -x NCCL_IB_SL=0 \
                    -x NCCL_IB_TIMEOUT=22 \
                    -x HCOLL_ENABLE_MCAST_ALL=0 \
                    -x UCX_TLS=tcp \
                    -x UCX_NET_DEVICES=eth0 \
                    /workspace/nccl-tests/build/all_reduce_perf -b 1G -e 8G -f 2 -g 1
    Worker:
      replicas: 2
      template:
        spec:
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
          tolerations:
            - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
          containers:
            - name: worker
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              command: ["bash", "-c", "mkdir -p /run/sshd && exec /usr/sbin/sshd -De"]
              ports:
                - { name: ssh, containerPort: 22 }
              securityContext:
                privileged: true
              resources:
                limits:
                  nvidia.com/gpu: 8
              volumeMounts:
                - { name: dev-infiniband, mountPath: /dev/infiniband }
                - { name: dshm, mountPath: /dev/shm }
          volumes:
            - { name: dev-infiniband, hostPath: { path: /dev/infiniband } }
            - { name: dshm, emptyDir: { medium: Memory } }
{{< /code >}}

Both workers stopped right away:

```
Bind to port 22 on 0.0.0.0 failed: Address already in use.
Bind to port 22 on :: failed: Address already in use.
Cannot bind any address.
```

The launcher failed too. A worker that is not Ready drops out of the headless service, so its name did not resolve:

```
ssh: Could not resolve hostname nccl-port22-worker-1.nccl-port22.rdma-hostnet.svc: Name or service not known
```

`launcherCreationPolicy: WaitForWorkersReady` did not stop this. The events show that the workers started, and the operator created the launcher one second later. The workers have no readiness probe, so they were Ready as soon as their containers started.

The scheduler only knows about the ports that pods declare. It does not know about the sshd of the node, so it placed both workers. It does know about ports of other pods. I started two jobs with 4 GPUs per node, and both declared port 2222. The nodes had 4 free GPUs each, but the workers of the second job stayed Pending:

```
0/7 nodes are available: 2 node(s) didn't have free ports for the requested pod ports, 2 node(s) were unschedulable, 3 Insufficient nvidia.com/gpu.
```

The 2 unschedulable nodes are the GPU nodes that I cordoned. The other 3 nodes have no GPUs. So two `hostNetwork` jobs can share a node only if each one uses its own ports. That includes the sshd port, and any port that your training code listens on.

### GPUs

I moved the second job to port 2223, and both jobs started. Each one asked for 4 GPUs on each node. But both jobs ran on the same 4 GPUs. This is from the second job:

```
#  Rank  0 Group  0 Pid   3027 on oke-cdhzek5e6za-niqfkyrmiba-s3zwzog2wia-0 device  0 [0000:0f:00] NVIDIA A100-SXM4-40GB
#  Rank  1 Group  0 Pid   3028 on oke-cdhzek5e6za-niqfkyrmiba-s3zwzog2wia-0 device  1 [0000:15:00] NVIDIA A100-SXM4-40GB
#  Rank  2 Group  0 Pid   3029 on oke-cdhzek5e6za-niqfkyrmiba-s3zwzog2wia-0 device  2 [0000:50:00] NVIDIA A100-SXM4-40GB
#  Rank  3 Group  0 Pid   3030 on oke-cdhzek5e6za-niqfkyrmiba-s3zwzog2wia-0 device  3 [0000:53:00] NVIDIA A100-SXM4-40GB
```

The first job listed the same 4 PCI addresses. Both launchers failed at first. The second job's launcher then kept failing while the first job ran:

```
NCCL WARN Cuda failure 2 'out of memory'
```

It succeeded only on an attempt that started after the first job had finished. Kubernetes saw nothing wrong. The scheduler counted 4 + 4 GPUs on each node. The device plugin gave each pod its own 4 GPUs.

The cause is the same as in the `privileged` step above. To check it, I started two pods with 4 GPUs each on one node. I ran them with `privileged`, and then without it:

{{< code language="yaml" title="gpu4-privileged.yaml" open="false" >}}
---
apiVersion: v1
kind: Pod
metadata:
  name: gpu4-privileged-1
  namespace: rdma-hostnet
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: "10.140.86.84"
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  containers:
    - name: gpu
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
      resources:
        limits:
          nvidia.com/gpu: 4
---
apiVersion: v1
kind: Pod
metadata:
  name: gpu4-privileged-2
  namespace: rdma-hostnet
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: "10.140.86.84"
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  containers:
    - name: gpu
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
      resources:
        limits:
          nvidia.com/gpu: 4
{{< /code >}}

The plain pods are the same, without `privileged`.

| Pods | `/dev/nvidiaN` files | GPUs in `nvidia-smi` |
|---|---|---|
| `gpu4-privileged-1` | 8 | All 8 |
| `gpu4-privileged-2` | 8 | All 8 |
| `gpu4-plain-1` | 4 | `0F`, `15`, `D6`, `DA` |
| `gpu4-plain-2` | 4 | `50`, `53`, `8C`, `91` |

The GPU Operator gives a pod its GPUs through CDI. It adds only the device files of those GPUs to the container. `privileged` adds every device of the node on top of that, and CUDA uses every GPU it can open. So CUDA device 0 in a privileged pod is the first GPU of the node. It does not matter which GPUs the device plugin gave the pod.

So with `privileged`, two jobs on one node are not separated on GPUs. They also share the NICs. Nothing gives NICs to pods, and each job saw all 16 rails. NCCL picked the NICs closest to its GPUs, and in this test both jobs used `rdma0` to `rdma7`.

### A fix without privileged

The GPU problem comes from `privileged`, so the fix is to drop it. The pod still needs the RDMA devices, and a `hostPath` mount alone does not work. CRI-O can add host devices to a container through the `io.kubernetes.cri-o.Devices` annotation. Two settings must allow it. The device must be in `allowed_devices`, and the runtime handler of the pod must accept the annotation.

I did not want to change the default handler of the nodes. So I added a copy of the `runc` handler, `runc-nohostdev`, in a drop-in file. I put it in `/etc/crio/crio.conf.d/` on both GPU nodes and restarted CRI-O:

{{< code language="toml" title="50-runc-nohostdev.conf" open="false" >}}
# Pods can ask for the RDMA devices with the io.kubernetes.cri-o.Devices annotation.
# Only the runc-nohostdev handler accepts that annotation.
[crio.runtime]
allowed_devices = ["/dev/fuse", "/dev/net/tun", "/dev/infiniband/uverbs0", "/dev/infiniband/uverbs1", "/dev/infiniband/uverbs2", "/dev/infiniband/uverbs3", "/dev/infiniband/uverbs4", "/dev/infiniband/uverbs5", "/dev/infiniband/uverbs6", "/dev/infiniband/uverbs7", "/dev/infiniband/uverbs8", "/dev/infiniband/uverbs9", "/dev/infiniband/uverbs10", "/dev/infiniband/uverbs11", "/dev/infiniband/uverbs12", "/dev/infiniband/uverbs13", "/dev/infiniband/uverbs14", "/dev/infiniband/uverbs15", "/dev/infiniband/uverbs16", "/dev/infiniband/uverbs17", "/dev/infiniband/rdma_cm"]

# A copy of the runc handler. Privileged containers do not get the devices of the node.
[crio.runtime.runtimes.runc-nohostdev]
runtime_path = "/usr/bin/runc"
runtime_root = "/run/runc"
monitor_path = "/usr/bin/conmon"
monitor_env = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
allowed_annotations = ["io.kubernetes.cri-o.seccompNotifierAction", "io.kubernetes.cri-o.TrySkipVolumeSELinuxLabel", "io.kubernetes.cri-o.Devices"]
privileged_without_host_devices = true
{{< /code >}}

A RuntimeClass lets pods use the new handler:

{{< code language="yaml" title="runtimeclass.yaml" open="false" >}}
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: runc-nohostdev
handler: runc-nohostdev
scheduling:
  nodeSelector:
    nvidia.com/gpu.present: "true"
{{< /code >}}

The annotation does not accept a directory. With `/dev/infiniband`, CRI-O did not create the container:

```
Error: /dev/infiniband is not a valid device: not a device node
```

So the drop-in and the annotation list the 18 `uverbs` devices and `rdma_cm` one by one. The tests did not need the `umad` devices.

The workers of the NCCL job change in four places:

- `runtimeClassName: runc-nohostdev`
- The annotation with the 19 devices
- The `IPC_LOCK` capability in place of `privileged`. These nodes do not need it.
- No `hostPath` mount

{{< code language="yaml" title="nccl-hostnet-fix.yaml" open="false" >}}
# NCCL all_reduce on 2 nodes x 8 GPUs, without privileged. The workers use the node's network namespace.
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-hostnet-fix
  namespace: rdma-hostnet
spec:
  slotsPerWorker: 8
  launcherCreationPolicy: WaitForWorkersReady
  runPolicy:
    cleanPodPolicy: Running
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          containers:
            - name: launcher
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              env:
                # Open MPI 5 takes the ssh port of the workers from this variable.
                - { name: PRTE_MCA_plm_ssh_args, value: "-p 2222" }
              command: ["bash", "-c"]
              args:
                - |
                  mpirun --allow-run-as-root \
                    -mca coll ^hcoll -mca plm_rsh_args "-p 2222" --hostfile /etc/mpi/hostfile \
                    -mca coll_hcoll_enable 0 \
                    -np 16 -npernode 8 --bind-to numa \
                    -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=INIT,NET \
                    -x NCCL_IB_SPLIT_DATA_ON_QPS=0 \
                    -x NCCL_IB_QPS_PER_CONNECTION=4 \
                    -x NCCL_IB_GID_INDEX=3 \
                    -x NCCL_IB_HCA==mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_14,mlx5_15,mlx5_16,mlx5_17,mlx5_9,mlx5_10,mlx5_11,mlx5_12 \
                    -x NCCL_IB_TC=41 \
                    -x NCCL_IB_SL=0 \
                    -x NCCL_IB_TIMEOUT=22 \
                    -x HCOLL_ENABLE_MCAST_ALL=0 \
                    -x UCX_TLS=tcp \
                    -x UCX_NET_DEVICES=eth0 \
                    /workspace/nccl-tests/build/all_reduce_perf -b 1G -e 8G -f 2 -g 1
    Worker:
      replicas: 2
      template:
        metadata:
          annotations:
            # CRI-O adds these devices. The runc-nohostdev handler allows the annotation.
            io.kubernetes.cri-o.Devices: "/dev/infiniband/uverbs0,/dev/infiniband/uverbs1,/dev/infiniband/uverbs2,/dev/infiniband/uverbs3,/dev/infiniband/uverbs4,/dev/infiniband/uverbs5,/dev/infiniband/uverbs6,/dev/infiniband/uverbs7,/dev/infiniband/uverbs8,/dev/infiniband/uverbs9,/dev/infiniband/uverbs10,/dev/infiniband/uverbs11,/dev/infiniband/uverbs12,/dev/infiniband/uverbs13,/dev/infiniband/uverbs14,/dev/infiniband/uverbs15,/dev/infiniband/uverbs16,/dev/infiniband/uverbs17,/dev/infiniband/rdma_cm"
        spec:
          runtimeClassName: runc-nohostdev
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
          tolerations:
            - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
          containers:
            - name: worker
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              # The node's own sshd already listens on port 22.
              command: ["bash", "-c", "mkdir -p /run/sshd && exec /usr/sbin/sshd -De -p 2222"]
              ports:
                - { name: ssh, containerPort: 2222 }
              securityContext:
                capabilities:
                  add: ["IPC_LOCK"]
              resources:
                limits:
                  nvidia.com/gpu: 8
              volumeMounts:
                - { name: dshm, mountPath: /dev/shm }
          volumes:
            - { name: dshm, emptyDir: { medium: Memory } }
{{< /code >}}

Then I ran the two jobs with 4 GPUs per node again. They had the same changes and ports 2222 and 2223. This time they ran at the same time, and both NCCL runs completed:

| Job | GPUs and NICs on node 1 | GPUs and NICs on node 2 | `busbw` at 8 GiB |
|---|---|---|---|
| 8 GPUs, `privileged` | All 8 GPUs, all 16 rails | All 8 GPUs, all 16 rails | 190.54 GB/s |
| 8 GPUs, fix | All 8 GPUs, all 16 rails | All 8 GPUs, all 16 rails | 190.36 GB/s |
| 4 GPUs alone, `privileged` | `0F`, `15`, `50`, `53` on `rdma0` to `rdma7` | `0F`, `15`, `50`, `53` on `rdma0` to `rdma7` | 96.64 GB/s |
| 4 GPUs, fix, first job | `0F`, `15`, `D6`, `DA` on `rdma0` to `rdma3` and `rdma12` to `rdma15` | `0F`, `15`, `50`, `53` on `rdma0` to `rdma7` | 96.40 GB/s |
| 4 GPUs, fix, second job | `50`, `53`, `8C`, `91` on `rdma4` to `rdma11` | `8C`, `91`, `D6`, `DA` on `rdma8` to `rdma15` | 96.36 GB/s |

Each job got its own 4 GPUs, and NCCL picked the NICs closest to them. So the two jobs also used different NICs. The device plugin picked a different set of GPUs for a job on each node. The fix did not cost bandwidth.

The handler also has `privileged_without_host_devices = true`. So CRI-O does not add the devices of the node to a privileged pod on it. I tested that setting first, without the annotation. A privileged pod with the `hostPath` mount got only its own 4 GPUs. But RDMA failed again with `Failed to open device`. CRI-O did not lift the device cgroup limit for it. With the annotation, a privileged pod on this handler also worked.

The fix has limits. It needs a change on the nodes, and it only works with CRI-O. The device list also depends on the node. These nodes have 18 RDMA devices, including the two front-end NICs. Any pod can name the RuntimeClass and set the annotation, and Pod Security checks neither. So I do not recommend this fix in general.

### Pod Security

The Baseline Pod Security Standard does not allow any of the settings that make this work. I applied the probe pod in a namespace with `pod-security.kubernetes.io/enforce: baseline`:

```
Error from server (Forbidden): error when creating "psa-pod.yaml": pods "rdma-probe-privileged-n1" is forbidden: violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true), hostPath volumes (volume "dev-infiniband"), privileged (container "rdma" must not set securityContext.privileged=true)
```

The pod from the fix does not use `privileged` or `hostPath`. Baseline still rejects it:

```
Error from server (Forbidden): error when creating "psa-fix-pod.yaml": pods "gpu4-annot-1" is forbidden: violates PodSecurity "baseline:latest": non-default capabilities (container "gpu" must not include "IPC_LOCK" in securityContext.capabilities.add), host namespaces (hostNetwork=true)
```

So the namespace of the training jobs must use the Privileged level in both cases. A privileged pod on the network of the node has close to full control of that node.

### Sysctls

The pod uses the rails and their sysctls as the node configured them. The ARP post covers which values matter and where they come from.

## When hostNetwork fits

`hostNetwork` worked well for one job per node that uses all of its GPUs. It needs no extra components, and it gets the full bandwidth of the rails. Port and GPU conflicts between jobs do not come up when one job owns the node.

It fits less well when jobs share nodes, or when the cluster has more than one tenant. Then you have to manage ports by hand. You also need the fix above, or something like it, to keep jobs off each other's GPUs. And the namespace has to use the Privileged level of Pod Security.

[The next part](/posts/getting-rdma-into-kubernetes-pods-part-2-sriov-vfs/) runs the same tests with SR-IOV VFs, on the other pair of nodes. Each pod gets its own VF on each rail, through a device plugin and without `privileged`.
