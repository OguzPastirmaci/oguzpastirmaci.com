+++
title = "Getting RDMA into Kubernetes Pods, Part 4: DRANET"
date = "2026-11-14T15:00:00-08:00"
draft = false
ogImage = "/images/og/getting-rdma-into-kubernetes-pods-part-4-dranet.png"
tags = ["rdma", "kubernetes", "nccl", "dra", "dranet", "oke"]
description = "Part 4 of a series on RDMA in Kubernetes pods for GPU training. DRANET gives a pod an IPvlan child of each rail it claims. A claim can also put GPUs and rails on the same PCIe root."
+++

This series tests four ways to give a Kubernetes pod RDMA for GPU training, on two pairs of A100 nodes. [Part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/) used `hostNetwork` and set the baseline, on the second pair with the same setup. NCCL `all_reduce` reached 190.54 GB/s bus bandwidth at 8 GiB on 16 GPUs. [Part 2](/posts/getting-rdma-into-kubernetes-pods-part-2-sriov-vfs/) used SR-IOV VFs, and [part 3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/) used IPvlan. This last part uses Dynamic Resource Allocation (DRA) with DRANET.

With DRA, the scheduler picks the devices of a pod, not the kubelet. DRANET is a DRA driver for network devices. It publishes each rail of the node, and a pod claims the rails it needs. On these nodes, DRANET gives the pod an IPvlan child of each claimed rail. The pod is not privileged, and NCCL reached 190.63 GB/s.

The big change is in how jobs share the nodes. In [part 3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/), the kubelet split the rails without looking at the GPUs, and only the Topology Manager fixed that. With DRA for the GPUs too, one claim can ask for GPUs and rails on the same PCIe root. Two jobs that shared the nodes got 96.29 and 96.34 GB/s, without the Topology Manager. With GPUs from the device plugin, two jobs of the same shape got 4.27 and 5.77 GB/s in one run. In a second run, they got 48.50 and 48.51 GB/s.

Every manifest and script in this post ran on the test cluster. Long files are collapsed, so click a file name to open it.

## What DRA changes

A device plugin tells the kubelet how many devices of a kind the node has. A pod asks for a count, like `nvidia.com/gpu: 4`. The scheduler only checks the count, because it cannot see where the devices are. The kubelet picks the devices when it starts the pod. Without the Topology Manager, it picks each kind of device on its own. That is why the VFs in [part 2](/posts/getting-rdma-into-kubernetes-pods-part-2-sriov-vfs/) and the PFs in [part 3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/) did not follow the GPUs. With the `restricted` policy of the Topology Manager, a pod that does not fit fails on the node.

The DRANET paper by Antonio Ojea, [The Kubernetes Network Driver Model](https://arxiv.org/abs/2506.23628), describes this gap. It calls the device plugin model purely quantitative. A device plugin can tell the kubelet the NUMA node of a device, but not its PCIe root.

With DRA, a driver publishes each device with its attributes in a `ResourceSlice`. A pod refers to a `ResourceClaim`, which asks for devices with selectors in the Common Expression Language (CEL). A claim can also have constraints, for example that some devices have the same value of an attribute. The scheduler picks the devices, and the kubelet asks the driver to prepare them. I made an [interactive walkthrough](/how-dranet-works/) of how DRANET finds, allocates, attaches and releases devices.

On OKE, [DRANET](https://github.com/kubernetes-sigs/dranet) has a provider with an `oke-rdma` profile. A claim for a rail gets an IPvlan child of the rail in the pod. The child has its own address, a route table and a source rule. The rail stays on the host. The [DRANET OKE page](https://dranet.sigs.k8s.io/docs/user/oci-oke-rdma/) describes the profile. It needs the shared RDMA namespace mode of `ib_core`, like the IPvlan setup of [part 3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/). In v1.5.0, the `oke-rdma` profile supports only IPv4 rails. Support for IPv6 rails is in progress.

## The setup

All NCCL jobs ran on the nodes of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/). The other tests ran on the first pair of nodes. Before the NCCL jobs, I repeated the installs, the test pods and the rail test there. The setup and the image are the same as in part 1:

- 2 x BM.GPU.B4.8 on OKE v1.36.4, with CRI-O 1.36.3
- Each node has 8 A100 GPUs and 16 RoCE rails at 100 Gb/s, all in the IPv4 subnet `10.224.0.0/12`
- DOCA-OFED 3.5.0 in the shared RDMA namespace mode
- The NVIDIA GPU Operator 26.3.3
- The image with NCCL 2.32.3 and perftest 6.28 from [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/)

These results are for a single plane network with IPv4 rails, like the one these nodes use. The same logic applies to Oracle Cloud shapes on the multiplanar network, but their configuration is different.

DRANET uses NRI, the plugin interface of the container runtime, so it can change containers when they start. CRI-O 1.36.3 has NRI on. This is part of its configuration:

```
[crio.nri]
  enable_nri = true
  nri_listen = "/var/run/nri/nri.sock"
```

I installed DRANET v1.5.0, the newest release when I tested, with its Helm chart:

```bash
kubectl apply -f namespace.yaml -f deviceclass.yaml -f rdma-dranet-tools.yaml
helm install dranet oci://registry.k8s.io/networking/charts/dranet --version v1.5.0 \
  -n kube-system -f dranet-values.yaml --wait --timeout 5m
```

{{< code language="yaml" title="dranet-values.yaml" open="false" >}}
# DRANET Helm values for the two BM.GPU.B4.8 nodes.
image:
  tag: v1.5.0
nodeSelector:
  node.kubernetes.io/instance-type: BM.GPU.B4.8
args:
  cloudProviderHint: OKE
{{< /code >}}

{{< code language="yaml" title="deviceclass.yaml" open="false" >}}
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.net
spec:
  selectors:
    - cel:
        expression: device.driver == "dra.net"
{{< /code >}}

{{< code language="yaml" title="namespace.yaml" open="false" >}}
# All part 4 test pods run here. Pod Security enforces the Baseline level.
apiVersion: v1
kind: Namespace
metadata:
  name: rdma-dranet
  labels:
    pod-security.kubernetes.io/enforce: baseline
{{< /code >}}

The namespace enforces the Baseline Pod Security Standard. Every test pod in this post ran there.

At startup, DRANET found the OKE provider and the shared RDMA mode, and it connected to CRI-O. The RDMA files of Oracle Cloud Agent were not mounted, so DRANET used its defaults. They match these nodes. These are its log lines, trimmed:

```
oke.go:1384] OCA RDMA network file /etc/oracle-cloud-agent/plugins/oci-hpc/oci-hpc-configure/rdma_network.json is not mounted; using 10.224.0.0/12
driver.go:131] RDMA subsystem in mode: shared
level=info msg="Configuring plugin 00-dra.net for runtime cri-o/1.36.3 (NRI version )..."
```

## What DRANET publishes

DRANET published one `ResourceSlice` for each node. It lists the 16 rails, and also the front-end NIC `eth1` and some virtual interfaces. These are the attributes of `rdma0` on one node, trimmed:

```
dra.net/ifName: rdma0
dra.net/rdma: true
dra.net/rdmaDevice: mlx5_5
dra.net/pciAddress: 0000:0c:00.0
dra.net/numaNode: 3
resource.kubernetes.io/numaNode: 3
resource.kubernetes.io/pcieRoot: pci0000:00
oke.dra.net/shape: BM.GPU.B4.8
oke.dra.net/rdmaChildIpv4Cidr: 10.208.0.0/12
```

`resource.kubernetes.io/pcieRoot` and `resource.kubernetes.io/numaNode` are standard attribute names, so other DRA drivers can use them too. The GPU driver below does. On these nodes, each PCIe root with GPUs has 2 GPUs and 2 NICs. Each of these roots is its own NUMA node:

| PCIe root | NUMA node | GPUs | Rails |
|---|---|---|---|
| `pci0000:00` | 3 | 0, 1 | `rdma0` to `rdma3` |
| `pci0000:3e` | 1 | 2, 3 | `rdma4` to `rdma7` |
| `pci0000:7d` | 7 | 4, 5 | `rdma8` to `rdma11` |
| `pci0000:ba` | 5 | 6, 7 | `rdma12` to `rdma15` |

[![The 4 PCIe roots of one BM.GPU.B4.8 node, each with 2 GPUs and 2 NICs, and the two data paths between a GPU and a NIC](/images/gpu-nic-topology.png)](/images/gpu-nic-topology.png)

## What the pod gets

A claim template asks for 16 devices that are rails. Each pod gets its own claim from it. The two test pods have no `privileged`, no added capabilities and no device plugin resources:

{{< code language="yaml" title="dranet-pods.yaml" open="false" >}}
# Two test pods, one on each GPU node. Each pod gets all 16 RDMA NICs through one DRANET claim.
# No privileged, no capabilities and no device plugin resource.
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: all-rails
  namespace: rdma-dranet
spec:
  spec:
    devices:
      requests:
        - name: rails
          exactly:
            deviceClassName: dra.net
            count: 16
            selectors:
              - cel:
                  expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
---
apiVersion: v1
kind: Pod
metadata:
  name: dranet-n1
  namespace: rdma-dranet
spec:
  nodeSelector:
    kubernetes.io/hostname: "10.140.66.66"
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  resourceClaims:
    - name: rails
      resourceClaimTemplateName: all-rails
  containers:
    - name: rdma
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      resources:
        claims:
          - name: rails
      volumeMounts:
        - { name: tools, mountPath: /opt/rdma-dranet, readOnly: true }
  volumes:
    - name: tools
      configMap: { name: rdma-dranet-tools, defaultMode: 0555 }
---
apiVersion: v1
kind: Pod
metadata:
  name: dranet-n2
  namespace: rdma-dranet
spec:
  nodeSelector:
    kubernetes.io/hostname: "10.140.82.106"
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  resourceClaims:
    - name: rails
      resourceClaimTemplateName: all-rails
  containers:
    - name: rdma
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      resources:
        claims:
          - name: rails
      volumeMounts:
        - { name: tools, mountPath: /opt/rdma-dranet, readOnly: true }
  volumes:
    - name: tools
      configMap: { name: rdma-dranet-tools, defaultMode: 0555 }
{{< /code >}}

The pods use a script from a ConfigMap. `rail-map.sh` prints the RDMA device and the GID index of each rail. It is like the script of [part 3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/), with two changes. The interfaces keep the names of their rails. The script also checks that each GID holds the address of the child:

{{< code language="yaml" title="rdma-dranet-tools.yaml" open="false" >}}
# A script that the test pods use to find the RDMA device and GID index of each rail.
# DRANET gives the pod an IPvlan child of each claimed RDMA NIC. The child keeps the name of its parent (rdma0, rdma1, ...).
apiVersion: v1
kind: ConfigMap
metadata:
  name: rdma-dranet-tools
  namespace: rdma-dranet
data:
  rail-map.sh: |
    #!/bin/bash
    # Prints one line for each rdma interface of this pod:
    # interface, IPv4 address, RDMA device, index of its RoCE v2 GID.
    set -u
    declare -A gid_dev gid_idx gid_val
    for path in /sys/class/infiniband/*; do
      dev=${path##*/}
      for f in "$path"/ports/1/gid_attrs/ndevs/*; do
        # The read fails for empty entries and for interfaces in other network namespaces.
        { read -r ndev < "$f"; } 2>/dev/null || continue
        case "$ndev" in rdma[0-9]*) ;; *) continue ;; esac
        idx=${f##*/}
        { read -r gid_type < "$path/ports/1/gid_attrs/types/$idx"; } 2>/dev/null || continue
        [ "$gid_type" = "RoCE v2" ] || continue
        read -r gid < "$path/ports/1/gids/$idx"
        case "$gid" in 0000:0000:0000:0000:0000:ffff:*) ;; *) continue ;; esac
        gid_dev[$ndev]=$dev
        gid_idx[$ndev]=$idx
        gid_val[$ndev]=$gid
      done
    done
    for path in /sys/class/net/rdma*; do
      echo "${path##*/}"
    done | sort -V | while read -r iface; do
      ip=$(ip -4 -o addr show dev "$iface" | awk 'NR == 1 { split($4, a, "/"); print a[1] }')
      idx=${gid_idx[$iface]:-none}
      # The GID must hold the address of the child, not the address of the parent on the host.
      if [ -n "$ip" ]; then
        # shellcheck disable=SC2086
        want=$(printf '0000:0000:0000:0000:0000:ffff:%02x%02x:%02x%02x' ${ip//./ })
        [ "${gid_val[$iface]:-}" = "$want" ] || idx=none
      fi
      echo "$iface ${ip:-none} ${gid_dev[$iface]:-none} $idx"
    done
{{< /code >}}

The scheduler gave each claim the 16 rails of its node. In each pod, the children kept the names of the rails, from `rdma0` to `rdma15`. Each child had the MAC address and the MTU of its rail. Each one also had an address in `10.208.0.0/12`, its own route table and a source rule:

```
rdma0@if22       UNKNOWN        10.208.2.66/12
10.208.0.0/12 dev rdma0 table 100 scope link src 10.208.2.66
32000:	from 10.208.2.66 lookup 100
```

The address follows the address of the node. The node is `10.140.66.66` in a `/19` subnet, so its position in the subnet is `0.0.2.66`. The child of `rdma0` got `10.208.2.66`, and the child of `rdma1` got `10.208.34.66`. Each rail has its own `/19` block in `10.208.0.0/12`. This is the default child range of the OKE provider. I did not change it with `oke.rdma-child-ipv4-cidr` in `--cloud-provider-options`. So DRANET needs no address pool, but the range must not be used anywhere else in the network.

The children also had the ARP settings of the rails, `arp_ignore=1` and `arp_announce=2`. The [ARP post](/posts/arp-rp-filter-and-accept-ra-for-rdma-pods-on-kubernetes/) explains why these matter.

`rail-map.sh` found a RoCE v2 GID for each child at index 5, on the RDMA device of its rail:

```
rdma0 10.208.2.66 mlx5_5 5
rdma1 10.208.34.66 mlx5_6 5
...
rdma15 10.209.226.66 mlx5_12 5
```

`/dev/infiniband` had the 16 `uverbs` devices of the rails, and not the ones of the front-end NICs. DRANET added them through NRI. `ulimit -l` was `unlimited`. `CapEff` was `00000000a80425fb`, the default set. Baseline admitted both pods without changes.

## The results

I tested each rail with `ib_write_bw`, one rail at a time, as in [parts 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/) to [3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/):

{{< code language="bash" title="rails-dranet.sh" open="false" >}}
#!/bin/bash
# ib_write_bw on each DRANET rail, from dranet-n1 to dranet-n2, one rail at a time.
set -u
ns=rdma-dranet
srv=dranet-n2
cli=dranet-n1
smap=$(kubectl -n $ns exec $srv -- /opt/rdma-dranet/rail-map.sh)
cmap=$(kubectl -n $ns exec $cli -- /opt/rdma-dranet/rail-map.sh)
port=18515
for i in $(seq 0 15); do
  read -r _ sip sdev sidx < <(awk -v n="rdma$i" '$1 == n' <<<"$smap")
  read -r _ _ cdev cidx < <(awk -v n="rdma$i" '$1 == n' <<<"$cmap")
  kubectl -n $ns exec $srv -- ib_write_bw -d "$sdev" -x "$sidx" -F --report_gbits -D 5 --tclass=41 -p $port >/dev/null 2>&1 &
  sleep 2
  out=$(kubectl -n $ns exec $cli -- ib_write_bw -d "$cdev" -x "$cidx" -F --report_gbits -D 5 --tclass=41 -p $port "$sip" 2>&1)
  wait
  echo "rdma$i $cdev $sip $(echo "$out" | awk '/^ 65536/ {print $4" Gb/s"}')"
  printf '%s\n' "$out" >&2
  port=$((port + 1))
done
{{< /code >}}

Every rail gave 96.87 or 96.88 Gb/s. In [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), `hostNetwork` gave 96.86 to 96.88 Gb/s.

I deleted the two test pods first, because they held all 16 rails of each node. I kept the `all-rails` template of `dranet-pods.yaml`, because the NCCL job uses it too. The NCCL job sets neither `NCCL_IB_HCA` nor `NCCL_IB_GID_INDEX`. NCCL finds the devices and the GID index itself, as in [part 3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/). The DRANET OKE page also says to leave the GID index unset. The job takes the GPUs from the device plugin and the rails from the claim:

{{< code language="yaml" title="nccl-dranet.yaml" open="false" >}}
# NCCL all_reduce_perf over the 16 DRANET rails of each GPU node.
# The GPUs come from the device plugin. The rails come from one DRANET claim per worker.
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-dranet
  namespace: rdma-dranet
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
                  # The 40 GB GPUs cannot hold 16 GiB buffers with validation (-c 1), so the test stops at 8 GiB.
                  mpirun --allow-run-as-root --hostfile /etc/mpi/hostfile \
                    -mca coll ^hcoll \
                    -np "$NP" -npernode "$NUM_GPUS" --bind-to numa \
                    -x NCCL_DEBUG=WARN \
                    -x NCCL_IB_SPLIT_DATA_ON_QPS=0 \
                    -x NCCL_IB_QPS_PER_CONNECTION=4 \
                    -x NCCL_IB_TC=41 \
                    -x NCCL_IB_SL=0 \
                    -x NCCL_IB_TIMEOUT=22 \
                    -x UCX_TLS=tcp \
                    -x UCX_NET_DEVICES=eth0 \
                    /workspace/nccl-tests/build/all_reduce_perf -b 4G -e 8G -f 2 -g 1 -c 1
    Worker:
      replicas: 2
      template:
        spec:
          nodeSelector:
            node.kubernetes.io/instance-type: BM.GPU.B4.8
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          resourceClaims:
            - name: rails
              resourceClaimTemplateName: all-rails
          volumes:
            - name: shm
              emptyDir:
                medium: Memory
                sizeLimit: 32Gi
          containers:
            - name: mpi-worker
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              command: ["/bin/bash", "-c", "mkdir -p /var/run/sshd; /usr/sbin/sshd -D"]
              volumeMounts:
                - name: shm
                  mountPath: /dev/shm
              resources:
                limits:
                  nvidia.com/gpu: 8
                claims:
                  - name: rails
{{< /code >}}

This is the result:

```
#       size         count      type   redop    root     time   algbw   busbw  #wrong     time   algbw   busbw  #wrong
  4294967296    1073741824     float     sum      -1  42529.3  100.99  189.35       0  42578.6  100.87  189.13       0
  8589934592    2147483648     float     sum      -1  84488.8  101.67  190.63       0  84502.1  101.65  190.60       0
```

| Setup | `busbw` at 8 GiB |
|---|---|
| `hostNetwork`, `privileged` (part 1) | 190.54 GB/s |
| SR-IOV, 1 VF per PF (part 2) | 190.55 GB/s |
| IPvlan with Multus (part 3) | 189.15 GB/s |
| DRANET | 190.63 GB/s |

[Part 2](/posts/getting-rdma-into-kubernetes-pods-part-2-sriov-vfs/) ran these jobs on the first pair of nodes, and the other parts on the second pair.

## Sharing the nodes

### GPUs from the device plugin

Next, I ran two jobs with 4 GPUs per node at the same time. Each worker asked for 4 GPUs from the device plugin and a claim for 8 rails. The two jobs only differ in their names:

{{< code language="yaml" title="nccl-dranet-a-device-plugin.yaml" open="false" >}}
# Two jobs on the same two nodes: job a with 4 GPUs from the device plugin and 8 DRANET rails per node.
# DRA picks the 8 rails without knowing which GPUs the device plugin gives the pod.
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: rails-8-a
  namespace: rdma-dranet
spec:
  spec:
    devices:
      requests:
        - name: rails
          exactly:
            deviceClassName: dra.net
            count: 8
            selectors:
              - cel:
                  expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
---
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-dranet-a
  namespace: rdma-dranet
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
                  mpirun --allow-run-as-root --hostfile /etc/mpi/hostfile \
                    -mca coll ^hcoll \
                    -np "$NP" -npernode "$NUM_GPUS" --bind-to numa \
                    -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=INIT,NET \
                    -x NCCL_IB_SPLIT_DATA_ON_QPS=0 \
                    -x NCCL_IB_QPS_PER_CONNECTION=4 \
                    -x NCCL_IB_TC=41 \
                    -x NCCL_IB_SL=0 \
                    -x NCCL_IB_TIMEOUT=22 \
                    -x UCX_TLS=tcp \
                    -x UCX_NET_DEVICES=eth0 \
                    /workspace/nccl-tests/build/all_reduce_perf -b 8G -e 8G -n 300 -g 1 -c 1
    Worker:
      replicas: 2
      template:
        spec:
          nodeSelector:
            node.kubernetes.io/instance-type: BM.GPU.B4.8
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          # One worker on each node.
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      training.kubeflow.org/job-name: nccl-dranet-a
                      training.kubeflow.org/job-role: worker
                  topologyKey: kubernetes.io/hostname
          resourceClaims:
            - name: rails
              resourceClaimTemplateName: rails-8-a
          volumes:
            - name: shm
              emptyDir:
                medium: Memory
                sizeLimit: 32Gi
          containers:
            - name: mpi-worker
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              command: ["/bin/bash", "-c", "mkdir -p /var/run/sshd; /usr/sbin/sshd -D"]
              volumeMounts:
                - name: shm
                  mountPath: /dev/shm
              resources:
                limits:
                  nvidia.com/gpu: 4
                claims:
                  - name: rails
{{< /code >}}

A rail goes to one claim at a time, so the two jobs got different rails. In both runs below, job a got `rdma0` to `rdma7`, on the roots `00` and `3e`. Job b got `rdma8` to `rdma15`, on the roots `7d` and `ba`. The device plugin gave the jobs these GPUs:

| Run | Node | GPUs of job a | GPUs of job b |
|---|---|---|---|
| 1 | `10.140.86.84` | 4, 5, 6, 7 | 0, 1, 2, 3 |
| 1 | `10.140.89.190` | 2, 3, 4, 5 | 0, 1, 6, 7 |
| 2 | `10.140.86.84` | 0, 1, 2, 3 | 4, 5, 6, 7 |
| 2 | `10.140.89.190` | 2, 3, 4, 5 | 0, 1, 6, 7 |

The scheduler picked the rails before the kubelet picked the GPUs. So the rails followed the GPUs only by chance. In run 2, both jobs on `10.140.86.84` happened to get GPUs on the roots of their rails.

In run 2, NCCL used the NICs of only one root on each node. Each job had 4 channels, all with GPUDirect RDMA. On `10.140.89.190`, job a used the NICs of `rdma4` to `rdma7`:

```
NCCL INFO NET/IB : Made virtual device [10] name=mlx5_1+mlx5_2 speed=200000 ndevs=2 rail=-1 plane=16385
NCCL INFO NET/IB : Made virtual device [11] name=mlx5_3+mlx5_4 speed=200000 ndevs=2 rail=-1 plane=16385
NCCL INFO Channel 00/0 : 5[1] -> 0[0] [send] via NET/IB/10/GDRDMA
```

So each job used only 4 of the 8 rails it claimed.

In run 1, no GPU of either job shared a root with its rails on `10.140.86.84`. So NCCL could not use GPUDirect RDMA there, and the channels of that node went through CPU memory:

```
NCCL INFO Channel 00/0 : 5[1] -> 0[0] [send] via NET/IB/8
```

The data also crossed between the two CPU sockets of the node. The two runs gave very different results:

| Run | Job | `busbw` at 8 GiB, out of place | In place |
|---|---|---|---|
| 1 | a | 4.27 GB/s | 6.06 GB/s |
| 1 | b | 5.77 GB/s | 5.77 GB/s |
| 2 | a | 48.50 GB/s | 48.51 GB/s |
| 2 | b | 48.51 GB/s | 48.51 GB/s |

In run 2, each job got about half of the bandwidth of [part 3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/) with the Topology Manager. So the result depends on which GPUs the device plugin picks.

### GPUs from DRA

To align the GPUs with the rails, the GPUs must come from DRA too. I installed the NVIDIA DRA driver for GPUs 0.5.1. I also turned off the device plugin of the GPU Operator on the two nodes:

```bash
helm install dra-driver-nvidia-gpu oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu \
  --version 0.5.1 -n dra-driver-nvidia-gpu --create-namespace -f gpu-dra-values.yaml --wait --timeout 5m
kubectl label node 10.140.66.66 10.140.82.106 nvidia.com/gpu.deploy.device-plugin=false --overwrite
```

{{< code language="yaml" title="gpu-dra-values.yaml" open="false" >}}
# NVIDIA GPU DRA driver values for the two BM.GPU.B4.8 nodes.
# GPUs only. The GPU Operator device plugin is turned off on these nodes with a node label.
nvidiaDriverRoot: /
gpuResourcesEnabledOverride: true
resources:
  gpus:
    enabled: true
  computeDomains:
    enabled: false
kubeletPlugin:
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
{{< /code >}}

The GPU Operator had already set the label to `true`, so the label needs `--overwrite`. After that, the nodes had 0 allocatable `nvidia.com/gpu`. The driver published the 8 GPUs of each node with `resource.kubernetes.io/pcieRoot`:

```
gpu-0  0000:50:00.0  pci0000:3e
gpu-1  0000:53:00.0  pci0000:3e
```

The driver numbers the GPUs in its own order. So `gpu-0` is GPU 2 in this post, the GPU at bus `50`.

A claim can now ask for 2 GPUs and 4 rails with the same `pcieRoot`. I tried it with one pod:

{{< code language="yaml" title="pair-check.yaml" open="false" >}}
# One pod with 2 GPUs and the 4 rails on the same PCIe root, from one claim.
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: pair-check
  namespace: rdma-dranet
spec:
  devices:
    requests:
      - name: gpus
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 2
      - name: rails
        exactly:
          deviceClassName: dra.net
          count: 4
          selectors:
            - cel:
                expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
    constraints:
      - requests: ["gpus", "rails"]
        matchAttribute: resource.kubernetes.io/pcieRoot
---
apiVersion: v1
kind: Pod
metadata:
  name: pair-check
  namespace: rdma-dranet
spec:
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  resourceClaims:
    - name: pair
      resourceClaimName: pair-check
  containers:
    - name: test
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      resources:
        claims:
          - name: pair
      volumeMounts:
        - { name: tools, mountPath: /opt/rdma-dranet, readOnly: true }
  volumes:
    - name: tools
      configMap: { name: rdma-dranet-tools, defaultMode: 0555 }
{{< /code >}}

The claim got GPUs 2 and 3, and the rails `rdma4` to `rdma7`. All of them are on `pci0000:3e`. The pod saw only those 2 GPUs and the 4 `uverbs` devices of its rails. Then I deleted the pod and its claim.

A worker with 8 GPUs needs 4 such pairs, one on each root:

{{< code language="yaml" title="nccl-dranet-aligned.yaml" open="false" >}}
# NCCL all_reduce_perf over the 16 DRANET rails of each GPU node, with the GPUs also from DRA.
# One claim per worker: 4 pairs of 2 GPUs and 4 rails, each pair on one PCIe root.
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: aligned-8gpu-16rails
  namespace: rdma-dranet
spec:
  spec:
    devices:
      requests:
        - name: gpus-1
          exactly:
            deviceClassName: gpu.nvidia.com
            count: 2
        - name: rails-1
          exactly:
            deviceClassName: dra.net
            count: 4
            selectors:
              - cel:
                  expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
        - name: gpus-2
          exactly:
            deviceClassName: gpu.nvidia.com
            count: 2
        - name: rails-2
          exactly:
            deviceClassName: dra.net
            count: 4
            selectors:
              - cel:
                  expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
        - name: gpus-3
          exactly:
            deviceClassName: gpu.nvidia.com
            count: 2
        - name: rails-3
          exactly:
            deviceClassName: dra.net
            count: 4
            selectors:
              - cel:
                  expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
        - name: gpus-4
          exactly:
            deviceClassName: gpu.nvidia.com
            count: 2
        - name: rails-4
          exactly:
            deviceClassName: dra.net
            count: 4
            selectors:
              - cel:
                  expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
      # Each pair of GPU and rail requests must be on one PCIe root.
      constraints:
        - requests: ["gpus-1", "rails-1"]
          matchAttribute: resource.kubernetes.io/pcieRoot
        - requests: ["gpus-2", "rails-2"]
          matchAttribute: resource.kubernetes.io/pcieRoot
        - requests: ["gpus-3", "rails-3"]
          matchAttribute: resource.kubernetes.io/pcieRoot
        - requests: ["gpus-4", "rails-4"]
          matchAttribute: resource.kubernetes.io/pcieRoot
---
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-dranet-aligned
  namespace: rdma-dranet
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
                  # The 40 GB GPUs cannot hold 16 GiB buffers with validation (-c 1), so the test stops at 8 GiB.
                  mpirun --allow-run-as-root --hostfile /etc/mpi/hostfile \
                    -mca coll ^hcoll \
                    -np "$NP" -npernode "$NUM_GPUS" --bind-to numa \
                    -x NCCL_DEBUG=WARN \
                    -x NCCL_IB_SPLIT_DATA_ON_QPS=0 \
                    -x NCCL_IB_QPS_PER_CONNECTION=4 \
                    -x NCCL_IB_TC=41 \
                    -x NCCL_IB_SL=0 \
                    -x NCCL_IB_TIMEOUT=22 \
                    -x UCX_TLS=tcp \
                    -x UCX_NET_DEVICES=eth0 \
                    /workspace/nccl-tests/build/all_reduce_perf -b 4G -e 8G -f 2 -g 1 -c 1
    Worker:
      replicas: 2
      template:
        spec:
          nodeSelector:
            node.kubernetes.io/instance-type: BM.GPU.B4.8
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          resourceClaims:
            - name: gpus-rails
              resourceClaimTemplateName: aligned-8gpu-16rails
          volumes:
            - name: shm
              emptyDir:
                medium: Memory
                sizeLimit: 32Gi
          containers:
            - name: mpi-worker
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              command: ["/bin/bash", "-c", "mkdir -p /var/run/sshd; /usr/sbin/sshd -D"]
              volumeMounts:
                - name: shm
                  mountPath: /dev/shm
              resources:
                claims:
                  - name: gpus-rails
{{< /code >}}

Each pair got the 2 GPUs and the 4 rails of one root, and NCCL reached 190.13 GB/s. A job with 4 GPUs per node needs 2 pairs. Again, the two jobs only differ in their names:

{{< code language="yaml" title="nccl-dranet-a-aligned.yaml" open="false" >}}
# Two jobs on the same two nodes: job a with 2 pairs of 2 GPUs and 4 rails per node, each pair on one PCIe root.
# The GPUs and the rails come from one claim per worker.
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: aligned-4gpu-8rails-a
  namespace: rdma-dranet
spec:
  spec:
    devices:
      requests:
        - name: gpus-1
          exactly:
            deviceClassName: gpu.nvidia.com
            count: 2
        - name: rails-1
          exactly:
            deviceClassName: dra.net
            count: 4
            selectors:
              - cel:
                  expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
        - name: gpus-2
          exactly:
            deviceClassName: gpu.nvidia.com
            count: 2
        - name: rails-2
          exactly:
            deviceClassName: dra.net
            count: 4
            selectors:
              - cel:
                  expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
      # Each pair of GPU and rail requests must be on one PCIe root.
      constraints:
        - requests: ["gpus-1", "rails-1"]
          matchAttribute: resource.kubernetes.io/pcieRoot
        - requests: ["gpus-2", "rails-2"]
          matchAttribute: resource.kubernetes.io/pcieRoot
---
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-dranet-a
  namespace: rdma-dranet
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
                  mpirun --allow-run-as-root --hostfile /etc/mpi/hostfile \
                    -mca coll ^hcoll \
                    -np "$NP" -npernode "$NUM_GPUS" --bind-to numa \
                    -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=INIT,NET \
                    -x NCCL_IB_SPLIT_DATA_ON_QPS=0 \
                    -x NCCL_IB_QPS_PER_CONNECTION=4 \
                    -x NCCL_IB_TC=41 \
                    -x NCCL_IB_SL=0 \
                    -x NCCL_IB_TIMEOUT=22 \
                    -x UCX_TLS=tcp \
                    -x UCX_NET_DEVICES=eth0 \
                    /workspace/nccl-tests/build/all_reduce_perf -b 8G -e 8G -n 300 -g 1 -c 1
    Worker:
      replicas: 2
      template:
        spec:
          nodeSelector:
            node.kubernetes.io/instance-type: BM.GPU.B4.8
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          # One worker on each node.
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      training.kubeflow.org/job-name: nccl-dranet-a
                      training.kubeflow.org/job-role: worker
                  topologyKey: kubernetes.io/hostname
          resourceClaims:
            - name: gpus-rails
              resourceClaimTemplateName: aligned-4gpu-8rails-a
          volumes:
            - name: shm
              emptyDir:
                medium: Memory
                sizeLimit: 32Gi
          containers:
            - name: mpi-worker
              image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
              command: ["/bin/bash", "-c", "mkdir -p /var/run/sshd; /usr/sbin/sshd -D"]
              volumeMounts:
                - name: shm
                  mountPath: /dev/shm
              resources:
                claims:
                  - name: gpus-rails
{{< /code >}}

The jobs did not get the same roots on both nodes. On one node, job a got the roots `00` and `3e`. On the other node, it got `7d` and `ba`. But every pair was on one root. Each job had 8 channels, all with GPUDirect RDMA.

| Run with 4 GPUs and 8 rails per node | `busbw` at 8 GiB |
|---|---|
| Part 3, Topology Manager `none` | 58.84 and 56.03 GB/s |
| Part 3, Topology Manager `restricted` | 96.36 and 96.29 GB/s |
| DRANET, GPUs from the device plugin, run 1 | 4.27 and 5.77 GB/s |
| DRANET, GPUs from the device plugin, run 2 | 48.50 and 48.51 GB/s |
| DRANET and DRA for the GPUs | 96.29 and 96.34 GB/s |

These are the devices of the jobs on `10.140.89.190`. Both runs with the device plugin gave the same devices there:

[![Which GPUs and rails the two jobs got on one node, with GPUs from the device plugin and with GPUs from DRA](/images/dranet-alignment.png)](/images/dranet-alignment.png)

The Topology Manager stayed at `none` on all four nodes for all DRANET runs.

The DRANET paper measured the same effect on Google Cloud, with B200 GPUs. Each NCCL process there had one GPU and one NIC. With the GPU from the device plugin, `all_reduce` reached 29.68 GB/s at 8 GB. The paper repeated each test 100 times. With the GPU and the NIC on the same PCIe root, it reached 46.93 GB/s, 58.1% more. Here, with 4 GPUs and 8 rails per job, the aligned jobs got twice the bandwidth of run 2.

### The shape the Topology Manager rejected

In [part 3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/), `restricted` rejected a job with 4 GPUs and 16 PFs per node. The scheduler placed its workers, and then the kubelet rejected them. I asked DRA for the same devices, once with all of them on one root and once without a constraint:

{{< code language="yaml" title="shape-4gpu-16rails.yaml" open="false" >}}
# The shape that the restricted Topology Manager policy rejected in part 3: 4 GPUs and all 16 rails.
# shape-root asks for all of them on one PCIe root. shape-any has no constraint.
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: shape-root
  namespace: rdma-dranet
spec:
  devices:
    requests:
      - name: gpus
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 4
      - name: rails
        exactly:
          deviceClassName: dra.net
          count: 16
          selectors:
            - cel:
                expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
    constraints:
      - requests: ["gpus", "rails"]
        matchAttribute: resource.kubernetes.io/pcieRoot
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: shape-any
  namespace: rdma-dranet
spec:
  devices:
    requests:
      - name: gpus
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 4
      - name: rails
        exactly:
          deviceClassName: dra.net
          count: 16
          selectors:
            - cel:
                expression: has(device.attributes["dra.net"].ifName) && device.attributes["dra.net"].ifName.startsWith("rdma") && device.attributes["dra.net"].rdma
---
apiVersion: v1
kind: Pod
metadata:
  name: shape-root
  namespace: rdma-dranet
spec:
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  resourceClaims:
    - name: devices
      resourceClaimName: shape-root
  containers:
    - name: test
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      resources:
        claims:
          - name: devices
---
apiVersion: v1
kind: Pod
metadata:
  name: shape-any
  namespace: rdma-dranet
spec:
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  tolerations:
    - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  resourceClaims:
    - name: devices
      resourceClaimName: shape-any
  containers:
    - name: test
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      command: ["sleep", "infinity"]
      resources:
        claims:
          - name: devices
{{< /code >}}

No root has 4 GPUs and 16 rails, so `shape-root` stayed Pending. The scheduler did not place it on a node:

```
0/5 nodes are available: 2 cannot allocate all claims, 3 node(s) didn't match Pod's node affinity/selector.
```

`shape-any` started. It got GPUs on 3 different roots, because its claim did not ask for alignment.

The rule of `shape-root` is stricter than `restricted`, so the test does not compare the two rules. It shows where each one says no. DRA says no in the scheduler, before the pod has a node. In [part 3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/), the kubelet said no after the scheduler had placed the pod.

## The release and main

DRANET main was 79 commits ahead of v1.5.0, at `b734321`. I upgraded to the staging build of that commit:

```bash
helm upgrade dranet oci://gcr.io/k8s-staging-networking/charts/dranet --version 1.5.0-79-gb734321 \
  -n kube-system -f dranet-values-main.yaml --wait --timeout 5m
```

{{< code language="yaml" title="dranet-values-main.yaml" open="false" >}}
# DRANET Helm values for the two BM.GPU.B4.8 nodes, with the staging build of main at b734321.
image:
  repository: gcr.io/k8s-staging-networking/dranet
  tag: v1.5.0-79-gb734321
nodeSelector:
  node.kubernetes.io/instance-type: BM.GPU.B4.8
args:
  cloudProviderHint: OKE
{{< /code >}}

On main, I checked the `ResourceSlice` and the test pods. I also ran the rail test and the NCCL jobs with aligned claims. The `ResourceSlice` had the same devices and attributes as with v1.5.0. The pods got the same addresses, route tables, rules and GID indexes. The startup log showed a newer NRI library, v0.12.5 instead of v0.12.3. Most OKE changes on main since v1.5.0 are for IPv6 fabrics, which these nodes do not have. One new check runs on every fabric, but only for a PCI function with several netdevs. Each rail here has its own PCI function.

| Test | v1.5.0 | main |
|---|---|---|
| `ib_write_bw`, one rail at a time | 96.87 to 96.88 Gb/s | 96.85 to 96.88 Gb/s |
| NCCL, 8 GPUs, `busbw` at 8 GiB | 190.13 GB/s | 190.83 GB/s |
| NCCL, two jobs with 4 GPUs, `busbw` at 8 GiB | 96.29 and 96.34 GB/s | 96.37 and 96.39 GB/s |

The results are within 1% of each other. I found no difference between main and v1.5.0 in these tests.

## The trade-offs

### Two drivers

The alignment needs DRA for the GPUs too. That means a second DRA driver, and the device plugin of the GPU Operator turned off on those nodes. Pods then ask for GPUs with claims, not with `nvidia.com/gpu`.

### Longer claims

The claims say a lot. The worker with 8 GPUs has 8 requests and 4 constraints. Each rail request repeats the same selector. In return, the claim says exactly which devices belong together.

### The addresses

The children get addresses from the position of the node in its primary VNIC subnet. So all nodes on the same RDMA network must use one primary VNIC subnet and the same child range. Each pod also has an on-link route for the whole range. So no subnet, pod CIDR or service CIDR may use the child range. The [DRANET OKE page](https://dranet.sigs.k8s.io/docs/user/oci-oke-rdma/) lists the checks and the option to change the range.

### Pod Security

Baseline admitted every test pod in this post. These nodes do not need `IPC_LOCK`. A CRI-O drop-in on them sets an unlimited `memlock` limit for every container. On nodes with a lower limit, the pod needs a higher `memlock` limit or `IPC_LOCK`. `IPC_LOCK` needs the Privileged level.

## When DRANET fits

DRANET gave the pods the full bandwidth of `hostNetwork`, without `privileged` and without a device plugin for the rails. The pods kept their own names, DNS and ports, as in [parts 2](/posts/getting-rdma-into-kubernetes-pods-part-2-sriov-vfs/) and [3](/posts/getting-rdma-into-kubernetes-pods-part-3-ipvlan/). Each pod got interfaces only on the rails it claimed.

The bigger gain is for jobs that share nodes. With the GPUs and the rails in one claim, the scheduler put each GPU next to its rails. Two jobs got the full bandwidth at the same time, without the Topology Manager. [Part 2](/posts/getting-rdma-into-kubernetes-pods-part-2-sriov-vfs/) got there too, with 2 VFs per PF and a VF on every rail for each pod. A shape that cannot be aligned waits in the scheduler instead of failing on the node.
