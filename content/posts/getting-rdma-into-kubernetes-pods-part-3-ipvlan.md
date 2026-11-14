+++
title = "Getting RDMA into Kubernetes Pods, Part 3: IPvlan"
date = "2026-11-14"
draft = false
ogImage = "/images/og/getting-rdma-into-kubernetes-pods-part-3-ipvlan.png"
tags = ["rdma", "kubernetes", "nccl", "ipvlan", "oke"]
description = "Part 3 of a series on RDMA in Kubernetes pods for GPU training. The pod stays on the pod network and gets the RDMA devices of the rails. It also gets an IPvlan interface on each rail."
+++

This series tests four ways to give a Kubernetes pod RDMA for GPU training, on two pairs of A100 nodes. [Part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/) used `hostNetwork` and set the baseline, on the second pair with the same setup. NCCL `all_reduce` reached 190.54 GB/s bus bandwidth at 8 GiB on 16 GPUs. [Part 2](/posts/getting-rdma-into-kubernetes-pods-part-2-sriov-vfs/) covers SR-IOV VFs, this part covers IPvlan, and part 4 covers DRA.

With IPvlan, the pod stays on the pod network. A device plugin gives it the RDMA devices of the rails. Multus calls the IPvlan CNI plugin for each rail, and that plugin adds an IPvlan interface to the pod. NVIDIA IPAM gives each interface its own IP address. The pod is not privileged, and it got the same bandwidth as `hostNetwork`. NCCL reached 189.15 GB/s, and 190.75 GB/s in a second run.

The hard part is sharing the rails between pods. A pod that takes all 16 rails takes them for the whole node. Two jobs can split the rails, with 4 GPUs and 8 PFs each per node. Each PCIe root of these nodes has 2 GPUs and 2 NICs. NCCL uses GPUDirect RDMA only when the NIC is close enough to the GPU. But the kubelet got the GPUs and the PFs from two device plugins, and did not match them. So NCCL sent the traffic of each job through only 3 or 4 of its 8 PFs. Those were the PFs next to its GPUs. The two jobs then got 58.84 and 56.03 GB/s. In [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), a job with 4 GPUs per node got 96.64 GB/s. The Topology Manager of the kubelet fixed this. With it, the two jobs got 96.36 and 96.29 GB/s at the same time.

Every manifest and script in this post ran on the test cluster. Long files are collapsed, so click a file name to open it.

## Why each pod needs its own interface

On these nodes, DOCA-OFED lets a process use a RoCE GID only in one case. The interface of the GID must be in the network namespace of the process. [Why Pods See Zero RoCE GIDs on DOCA-OFED](/posts/why-pods-see-zero-roce-gids-on-doca-ofed/) covers this check. The rails `rdma0` to `rdma15` stay in the host namespace. So a pod on the pod network cannot use the GIDs of the rails, even with the RDMA devices. In sysfs, it sees them as zero.

An IPvlan L2 interface fixes this. It uses the MAC address of its rail, and it lives in the network namespace of the pod. When it gets an IP address, the kernel adds a RoCE GID for that address. The GID is on the RDMA device of the rail. The pod can use that GID.

This only works in the shared RDMA namespace mode of `ib_core`. In that mode, the pod sees the RDMA device of each rail, which stays in the host namespace. In the exclusive mode, each RDMA device belongs to one network namespace. The devices of the rails stay in the host namespace, so the pod would not see them. On these nodes, `/etc/modprobe.d/ib_core.conf` sets the shared mode with `options ib_core netns_mode=1`. The A100 nodes of the [GID post](/posts/why-pods-see-zero-roce-gids-on-doca-ofed/) ran an older image, which used the exclusive mode by default. That post explains both modes.

## The setup

All NCCL jobs ran on the nodes of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/). Most other tests ran on the first pair of nodes. The sections that ran on the nodes of part 1 say so. The setup and the image are the same as in part 1:

- 2 x BM.GPU.B4.8 on OKE v1.36.4, with CRI-O 1.36.3
- Each node has 8 A100 GPUs and 16 RoCE rails at 100 Gb/s, all in the IPv4 subnet `10.224.0.0/12`
- DOCA-OFED 3.5.0 in the shared RDMA namespace mode
- The NVIDIA GPU Operator 26.3.3
- The image with NCCL 2.32.3 and perftest 6.28 from [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/)

These results are for a single plane network with IPv4 rails, like the one these nodes use. The same logic applies to Oracle Cloud shapes on the multiplanar network, but their configuration is different.

I added the NVIDIA Network Operator 26.7.1, the newest release when I tested. It deploys Multus, the CNI plugins, NVIDIA IPAM and the SR-IOV device plugin:

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

# This setup uses the PFs directly, so it does not need the SR-IOV Network Operator.
sriovNetworkOperator:
  enabled: false

operator:
  resources:
    requests:
      cpu: 5m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
{{< /code >}}

`values.yaml` turns off the NFD and the SR-IOV Network Operator of the chart. The cluster already runs NFD, and this setup uses the physical functions (PFs), not VFs. Then the NicClusterPolicy starts the other parts:

{{< code language="yaml" title="nic-cluster-policy.yaml" open="false" >}}
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata:
  name: nic-cluster-policy
spec:
  # The OCI image supplies the DOCA-OFED driver, so no ofedDriver section.
  sriovDevicePlugin:
    image: sriov-network-device-plugin
    repository: nvcr.io/nvidia/mellanox
    version: network-operator-v26.7.1
    # Exposes the 16 RDMA PFs of each BM.GPU.B4.8 node as nvidia.com/hostdev.
    # The front-end NICs (0000:6b:00.0 and 0000:aa:00.0) are RDMA devices too, so the PFs are listed by PCI address.
    config: |
      {
        "resourceList": [
          {
            "resourcePrefix": "nvidia.com",
            "resourceName": "hostdev",
            "selectors": {
              "vendors": ["15b3"],
              "isRdma": true,
              "pciAddresses": [
                "0000:0c:00.0", "0000:0c:00.1", "0000:16:00.0", "0000:16:00.1",
                "0000:47:00.0", "0000:47:00.1", "0000:4b:00.0", "0000:4b:00.1",
                "0000:89:00.0", "0000:89:00.1", "0000:93:00.0", "0000:93:00.1",
                "0000:c3:00.0", "0000:c3:00.1", "0000:d1:00.0", "0000:d1:00.1"
              ]
            }
          }
        ]
      }
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

The device plugin offers the 16 rail PFs of each node as `nvidia.com/hostdev`. It lists them by PCI address, because the front-end NICs are also RDMA devices from the same vendor. Both GPU nodes then offered 16:

```
NAME            HOSTDEV   GPU
10.140.66.66    16        8
10.140.82.106   16        8
```

The IPvlan interfaces need addresses that no host uses. I picked `10.239.255.0/24`, a free range inside the rail subnet `10.224.0.0/12`. From each node of the first pair, I pinged all 254 addresses on all 16 rails. On the nodes of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), I pinged them on `rdma0` and `rdma15`. Nothing answered. NVIDIA IPAM gives each node a block of 32 addresses from the pool:

{{< code language="yaml" title="ip-pool.yaml" open="false" >}}
apiVersion: nv-ipam.nvidia.com/v1alpha1
kind: IPPool
metadata:
  name: rdma-ipvlan-pool
  namespace: nvidia-network-operator
spec:
  # An unused range, here inside the RDMA rail subnet.
  subnet: 10.239.255.0/24
  perNodeBlockSize: 32
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: node.kubernetes.io/instance-type
            operator: In
            values:
              - BM.GPU.B4.8
{{< /code >}}

```
{"allocations":[{"endIP":"10.239.255.32","nodeName":"10.140.66.66","startIP":"10.239.255.1"},{"endIP":"10.239.255.64","nodeName":"10.140.82.106","startIP":"10.239.255.33"}]}
```

Then come 16 networks, one for each rail. The `tuning` plugin sets the ARP sysctls of each interface, and the `sbr` plugin adds source routing. The [ARP post](/posts/arp-rp-filter-and-accept-ra-for-rdma-pods-on-kubernetes/) explains the values.

{{< code language="yaml" title="ipvlan-networks.yaml" open="false" >}}
# One IPvlan L2 child on each RDMA rail. The child uses the MAC address of its rail (rdmaN).
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-0
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-0",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma0",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-1
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-1",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma1",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-2
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-2",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma2",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-3
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-3",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma3",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-4
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-4",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma4",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-5
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-5",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma5",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-6
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-6",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma6",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-7
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-7",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma7",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-8
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-8",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma8",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-9
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-9",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma9",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-10
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-10",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma10",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-11
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-11",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma11",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-12
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-12",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma12",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-13
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-13",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma13",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-14
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-14",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma14",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-ipvlan-15
  namespace: default
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "rdma-ipvlan-15",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "rdma15",
          "mode": "l2",
          "ipam": { "type": "nv-ipam", "poolName": "rdma-ipvlan-pool" }
        },
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
        { "type": "sbr", "addSourceHints": true }
      ]
    }
{{< /code >}}

The last file is a ConfigMap with one script. `rail-map.sh` finds the RDMA device and the GID index of each IPvlan interface. The check pod and the rail test below use it.

{{< code language="yaml" title="rdma-ipvlan-tools.yaml" open="false" >}}
# Script that the test pods use to find the RDMA device and GID index of each IPvlan interface.
apiVersion: v1
kind: ConfigMap
metadata:
  name: rdma-ipvlan-tools
  namespace: default
data:
  rail-map.sh: |
    #!/bin/bash
    # Prints one line for each IPvlan interface of this pod (net1, net2, ...):
    # interface, IPv4 address, RDMA device, index of its RoCE v2 GID.
    set -u
    declare -A gid_dev gid_idx
    for path in /sys/class/infiniband/*; do
      dev=${path##*/}
      for f in "$path"/ports/1/gid_attrs/ndevs/*; do
        # The read fails for empty entries and for interfaces in other network namespaces.
        { read -r ndev < "$f"; } 2>/dev/null || continue
        case "$ndev" in net[0-9]*) ;; *) continue ;; esac
        idx=${f##*/}
        { read -r gid_type < "$path/ports/1/gid_attrs/types/$idx"; } 2>/dev/null || continue
        [ "$gid_type" = "RoCE v2" ] || continue
        read -r gid < "$path/ports/1/gids/$idx"
        case "$gid" in 0000:0000:0000:0000:0000:ffff:*) ;; *) continue ;; esac
        gid_dev[$ndev]=$dev
        gid_idx[$ndev]=$idx
      done
    done
    for path in /sys/class/net/net*; do
      echo "${path##*/}"
    done | sort -V | while read -r iface; do
      ip=$(ip -4 -o addr show dev "$iface" | awk 'NR == 1 { split($4, a, "/"); print a[1] }')
      echo "$iface ${ip:-none} ${gid_dev[$iface]:-none} ${gid_idx[$iface]:-none}"
    done
{{< /code >}}

## What the pod needs

A pod needs three things:

- `nvidia.com/hostdev: 16`, for the 16 rail PFs
- The annotation `k8s.v1.cni.cncf.io/networks` with the 16 networks, in rail order
- The namespace of the networks, which is `default` here

It does not need `privileged`, `hostNetwork` or a `hostPath` mount. The test pods also add `IPC_LOCK`, but these nodes do not need it. The Pod Security section explains why. These are the two test pods:

{{< code language="yaml" title="ipvlan-pods.yaml" open="false" >}}
---
apiVersion: v1
kind: Pod
metadata:
  name: ipvlan-n1
  namespace: default
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-ipvlan-0,rdma-ipvlan-1,rdma-ipvlan-2,rdma-ipvlan-3,rdma-ipvlan-4,rdma-ipvlan-5,rdma-ipvlan-6,rdma-ipvlan-7,rdma-ipvlan-8,rdma-ipvlan-9,rdma-ipvlan-10,rdma-ipvlan-11,rdma-ipvlan-12,rdma-ipvlan-13,rdma-ipvlan-14,rdma-ipvlan-15
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
          nvidia.com/hostdev: 16
      volumeMounts:
        - { name: tools, mountPath: /opt/rdma-ipvlan, readOnly: true }
  volumes:
    - name: tools
      configMap: { name: rdma-ipvlan-tools, defaultMode: 0555 }
---
apiVersion: v1
kind: Pod
metadata:
  name: ipvlan-n2
  namespace: default
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-ipvlan-0,rdma-ipvlan-1,rdma-ipvlan-2,rdma-ipvlan-3,rdma-ipvlan-4,rdma-ipvlan-5,rdma-ipvlan-6,rdma-ipvlan-7,rdma-ipvlan-8,rdma-ipvlan-9,rdma-ipvlan-10,rdma-ipvlan-11,rdma-ipvlan-12,rdma-ipvlan-13,rdma-ipvlan-14,rdma-ipvlan-15
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
          nvidia.com/hostdev: 16
      volumeMounts:
        - { name: tools, mountPath: /opt/rdma-ipvlan, readOnly: true }
  volumes:
    - name: tools
      configMap: { name: rdma-ipvlan-tools, defaultMode: 0555 }
{{< /code >}}

The pods had their own host names and the cluster DNS. `/dev/infiniband` had 16 `uverbs` devices, for the 16 rail PFs and not for the front-end NICs. `CapEff` was `00000000a80465fb`, which is the default set plus `IPC_LOCK`.

Each IPvlan interface had the MAC address of its rail. The interface on `rdma0` had `08:c0:eb:8e:7f:20`, the MAC address of `rdma0`.

A check pod with the same settings prints the RDMA device and GID index of each IPvlan interface:

{{< code language="yaml" title="ipvlan-check.yaml" open="false" >}}
apiVersion: v1
kind: Pod
metadata:
  name: rdma-ipvlan-check
  namespace: default
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-ipvlan-0,rdma-ipvlan-1,rdma-ipvlan-2,rdma-ipvlan-3,rdma-ipvlan-4,rdma-ipvlan-5,rdma-ipvlan-6,rdma-ipvlan-7,rdma-ipvlan-8,rdma-ipvlan-9,rdma-ipvlan-10,rdma-ipvlan-11,rdma-ipvlan-12,rdma-ipvlan-13,rdma-ipvlan-14,rdma-ipvlan-15
spec:
  restartPolicy: Never
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  nodeSelector:
    node.kubernetes.io/instance-type: BM.GPU.B4.8
  volumes:
    - name: tools
      configMap:
        name: rdma-ipvlan-tools
        defaultMode: 0555
  containers:
    - name: check
      image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.4.1-ubuntu-24.04-nccl-2.32.3-100526.0
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
      volumeMounts:
        - name: tools
          mountPath: /opt/rdma-ipvlan
          readOnly: true
      resources:
        limits:
          nvidia.com/hostdev: 16
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -u
          echo "RDMA netns mode: $(cat /sys/module/ib_core/parameters/netns_mode) (Y = shared, N = exclusive)"
          allocated=" ${PCIDEVICE_NVIDIA_COM_HOSTDEV//,/ } "
          echo "Allocated RDMA PFs: $(wc -w <<<"$allocated")"
          echo "interface address device gid_index"
          /opt/rdma-ipvlan/rail-map.sh | tee /tmp/map
          rails=0
          failed=0
          indexes=""
          while read -r iface ip dev idx; do
            rails=$((rails + 1))
            if [ "$dev" = none ] || [ "$idx" = none ]; then
              echo "FAIL: $iface ($ip) has no RoCE v2 GID"
              failed=1
              continue
            fi
            IFS=. read -r o1 o2 o3 o4 <<<"$ip"
            expected=$(printf '0000:0000:0000:0000:0000:ffff:%02x%02x:%02x%02x' "$o1" "$o2" "$o3" "$o4")
            gid=$(cat "/sys/class/infiniband/$dev/ports/1/gids/$idx")
            pci=$(basename "$(readlink -f "/sys/class/infiniband/$dev/device")")
            if [ "$gid" != "$expected" ]; then
              echo "FAIL: $iface GID $idx of $dev is $gid, expected $expected"
              failed=1
            elif [[ "$allocated" != *" $pci "* ]]; then
              echo "FAIL: $dev ($pci) of $iface is not an allocated nvidia.com/hostdev device"
              failed=1
            fi
            indexes="$indexes $idx"
          done < /tmp/map
          dev=$(awk 'NR == 1 {print $3}' /tmp/map)
          echo "Host GID index 3 of $dev in this pod: $(cat "/sys/class/infiniband/$dev/ports/1/gids/3")"
          index_list=$(tr ' ' '\n' <<<"$indexes" | sed '/^$/d' | sort -u | paste -sd' ' -)
          if [ "$rails" -ne 16 ] || [ "$failed" -ne 0 ]; then
            echo "FAIL: $rails IPvlan interfaces found, errors above"
            exit 1
          fi
          echo "PASS: 16 IPvlan interfaces have a RoCE v2 GID on an allocated RDMA PF (GID index: $index_list)"
{{< /code >}}

It printed this, trimmed:

```
RDMA netns mode: Y (Y = shared, N = exclusive)
Allocated RDMA PFs: 16
interface address device gid_index
net1 10.239.255.1 mlx5_5 5
net2 10.239.255.2 mlx5_6 5
...
net16 10.239.255.16 mlx5_12 5
Host GID index 3 of mlx5_5 in this pod: 0000:0000:0000:0000:0000:0000:0000:0000
PASS: 16 IPvlan interfaces have a RoCE v2 GID on an allocated RDMA PF (GID index: 5)
```

Each interface has a RoCE v2 GID at index 5. The GID of the host address at index 3 still reads as zero in the pod.

## The results

I tested each rail with `ib_write_bw`, one rail at a time, as in [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/). The only change is that each side uses the device and GID index from `rail-map.sh`:

{{< code language="bash" title="rails-ipvlan.sh" open="false" >}}
#!/bin/bash
# ib_write_bw on each IPvlan rail, from ipvlan-n1 to ipvlan-n2, one rail at a time.
set -u
srv=ipvlan-n2
cli=ipvlan-n1
smap=$(kubectl exec $srv -- /opt/rdma-ipvlan/rail-map.sh)
cmap=$(kubectl exec $cli -- /opt/rdma-ipvlan/rail-map.sh)
port=18515
for i in $(seq 1 16); do
  read -r _ sip sdev sidx < <(awk -v n="net$i" '$1 == n' <<<"$smap")
  read -r _ _ cdev cidx < <(awk -v n="net$i" '$1 == n' <<<"$cmap")
  kubectl exec $srv -- ib_write_bw -d "$sdev" -x "$sidx" -F --report_gbits -D 5 --tclass=41 -p $port >/dev/null 2>&1 &
  sleep 2
  out=$(kubectl exec $cli -- ib_write_bw -d "$cdev" -x "$cidx" -F --report_gbits -D 5 --tclass=41 -p $port "$sip" 2>&1)
  wait
  echo "net$i $cdev $sip $(echo "$out" | awk '/^ 65536/ {print $4" Gb/s"}')"
  printf '%s\n' "$out" >&2
  port=$((port + 1))
done
{{< /code >}}

Every rail gave 96.86 to 96.88 Gb/s. In [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), `hostNetwork` gave 96.86 to 96.88 Gb/s.

The NCCL job sets neither `NCCL_IB_HCA` nor `NCCL_IB_GID_INDEX`, because NCCL finds them in each pod. [The GID index changes](#the-gid-index-changes) shows why that matters. The worker runs sshd on port 22, which is the default:

{{< code language="yaml" title="nccl-test.yaml" open="false" >}}
# NCCL all_reduce_perf over the 16 IPvlan rails of each GPU node.
# NCCL_IB_HCA and NCCL_IB_GID_INDEX stay unset. NCCL finds the RDMA devices and the GID index of each pod itself.
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-test-ipvlan
  namespace: default
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
        metadata:
          annotations:
            k8s.v1.cni.cncf.io/networks: rdma-ipvlan-0,rdma-ipvlan-1,rdma-ipvlan-2,rdma-ipvlan-3,rdma-ipvlan-4,rdma-ipvlan-5,rdma-ipvlan-6,rdma-ipvlan-7,rdma-ipvlan-8,rdma-ipvlan-9,rdma-ipvlan-10,rdma-ipvlan-11,rdma-ipvlan-12,rdma-ipvlan-13,rdma-ipvlan-14,rdma-ipvlan-15
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
                  nvidia.com/hostdev: 16
{{< /code >}}

This is the result of the first run:

```
#       size         count      type   redop    root     time   algbw   busbw  #wrong     time   algbw   busbw  #wrong
  4294967296    1073741824     float     sum      -1  42368.9  101.37  190.07       0  42611.3  100.79  188.99       0
  8589934592    2147483648     float     sum      -1  85151.9  100.88  189.15       0  84865.9  101.22  189.78       0
```

| Setup | `busbw` at 8 GiB |
|---|---|
| `hostNetwork`, `privileged` (part 1) | 190.54 GB/s |
| `hostNetwork`, CRI-O fix (part 1) | 190.36 GB/s |
| IPvlan | 189.15 GB/s |

A second run gave 190.75 GB/s. A run with `NCCL_DEBUG=INFO` gave 190.41 GB/s. NCCL used the same 8 virtual devices as in [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), with GPUDirect RDMA. Each one is the two ports of a NIC:

```
NCCL INFO NET/IB : Made virtual device [16] name=mlx5_5+mlx5_6 speed=200000 ndevs=2 rail=-1 plane=16385
NCCL INFO Channel 00/0 : 1[1] -> 8[0] [receive] via NET/IB/16/GDRDMA/flush=Always
```

The problems of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/) are gone. The sshd of the worker used port 22 next to the sshd of the node. The pods had their own names and the cluster DNS. And a pod that asked for GPUs got only its own GPUs.

## The trade-offs

### Splitting the rails

A node offers 16 rail PFs, so only one pod per node can get every rail. For two jobs per node, each job asked for 8 PFs. Both jobs started, and each pod still got an IPvlan interface on all 16 rails. These are the pods on one node:

| Job | GPUs | Rails from the device plugin |
|---|---|---|
| First | 2, 3, 4, 5 | `rdma1`, `rdma4`, `rdma5`, `rdma6`, `rdma12`, `rdma13`, `rdma14`, `rdma15` |
| Second | 0, 1, 6, 7 | `rdma0`, `rdma2`, `rdma3`, `rdma7`, `rdma8`, `rdma9`, `rdma10`, `rdma11` |

By PCIe root, the two jobs got these devices:

[![Which GPUs and PFs the two jobs got on one node, by PCIe root](/images/ipvlan-split-rails.png)](/images/ipvlan-split-rails.png)

The PFs did not follow the GPUs. In [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), NCCL put GPUs 0, 1, 6 and 7 on `rdma0` to `rdma3` and `rdma12` to `rdma15`. The other 4 GPUs used `rdma4` to `rdma11`. Here, each job got PFs on three of the four roots. Two of its GPUs had no PF on their root. The two ports of one NIC sometimes went to different jobs.

NCCL only used the PFs that had device files in the pod, 8 in each pod. NCCL uses GPUDirect RDMA only up to a set distance between the NIC and the GPU. `NCCL_NET_GDR_LEVEL` sets that distance, and by default NCCL picks it from the topology. In this run, every network channel used a PF on the root of its GPU, with GPUDirect RDMA. On this node, the first job used only `rdma4`, `rdma5` and `rdma6`. The second job used only `rdma0`, `rdma2` and `rdma3`. So each job sent its traffic through 3 of its 8 PFs. On the other node, each job used 4. This channel from GPU 2 goes through the NIC of `rdma4` and `rdma5`:

```
NCCL INFO Channel 00/0 : 0[0] -> 4[0] [send] via NET/IB/8/GDRDMA
```

[![The 4 PCIe roots of one BM.GPU.B4.8 node, each with 2 GPUs and 2 NICs, and the two data paths between a GPU and a NIC](/images/gpu-nic-topology.png)](/images/gpu-nic-topology.png)

The bandwidth dropped:

| Job | `busbw` at 8 GiB, out of place | In place |
|---|---|---|
| First | 58.84 GB/s | 58.90 GB/s |
| Second | 56.03 GB/s | 55.96 GB/s |

I also ran the first job alone. It got 26.95 GB/s, so sharing the node was not the cause. In that run, the kubelet gave it other PFs, and other GPUs on one node. On one node, 4 of its 8 PFs were next to its GPUs. On the other node, only 3 were. There, two of its GPUs used NICs on another root, without GPUDirect RDMA. Without GPUDirect RDMA, the data goes through CPU memory. This channel from GPU 1 goes through the NIC of `rdma8` and `rdma9`, with no `GDRDMA`:

```
NCCL INFO Channel 01/0 : 5[1] -> 0[0] [send] via NET/IB/9
```

With the CRI-O fix of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), two jobs like these got 96.40 and 96.36 GB/s at the same time.

### Aligning the rails with the Topology Manager

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

| Run with 4 GPUs and 8 PFs per node | Policy `none` | Policy `restricted` |
|---|---|---|
| One job alone | 26.95 GB/s | 96.64 GB/s |
| Two jobs at the same time | 58.84 and 56.03 GB/s | 96.36 and 96.29 GB/s |

Every pod got its 4 GPUs and its 8 PFs on the same 2 NUMA nodes. In the two-job run, one job got NUMA nodes 1 and 3, and the other got 5 and 7. Every NCCL channel used GPUDirect RDMA. The results match the CRI-O fix of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/).

`restricted` has a downside too, because it rejects pods that it cannot align. A job with 4 GPUs and 16 PFs per node is an example. The PFs need all 4 NUMA nodes with NICs, but the GPUs need only 2. The scheduler placed its workers, and then the kubelet rejected them:

```
Warning   TopologyAffinityError   Resources cannot be allocated with Topology locality
```

The scheduler does not know about NUMA nodes, so it cannot avoid this. The job with 8 GPUs and 16 PFs still ran, at 190.12 GB/s.

The policy `best-effort` does not reject pods. It looks for the same alignment, but the kubelet admits the pod even when it cannot align it. The pod then gets some devices from other NUMA nodes, with no error. Such a job can run as slowly as with `none`. I did not test `best-effort`, but the [Topology Manager documentation](https://kubernetes.io/docs/tasks/administer-cluster/topology-manager/) describes it.

I changed the kubelet configuration by hand on the two nodes, and I put it back after the tests. For real use, the change belongs in the node setup.

### The GID index changes

Each IPvlan interface adds GIDs to the RDMA device of its rail. On the nodes of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), the first pod on a rail got GID index 5. The second pod on the same rail got index 7:

```
net1 10.239.255.65 mlx5_5 5
net1 10.239.255.81 mlx5_5 7
```

So a fixed `NCCL_IB_GID_INDEX` is wrong for some pods. NCCL can pick the index itself when the variable is not set. NCCL picked index 5 in a first pod and index 7 in a second pod. Every connection used the GID of the pod's own address. In a pod, the GIDs of the host and of other pods read as zero in sysfs. The pod cannot use them. The bandwidth was the same with both indexes:

| Pod on each rail | GID index | `busbw` at 8 GiB |
|---|---|---|
| First | 5 | 189.15, 190.75 and 190.41 GB/s |
| Second | 7 | 190.49 and 189.66 GB/s |

Without `NCCL_IB_HCA`, NCCL used the RDMA devices that the pod could open. That was 16 PFs in these pods, and 8 PFs in a pod with `nvidia.com/hostdev: 8`. So the NCCL job in this post leaves both variables to NCCL.

### IP addresses

Each pod takes one address on every rail it has a network for. That is 16 addresses, even for a pod with 4 PFs. With blocks of 32 addresses per node, a third such pod could not start:

```
ResourceExhausted desc = no free addresses in the pool "rdma-ipvlan-pool", poolType "ippool"
```

The pool needs a range that no host uses. Its block size also has to fit the pods on each node.

### More moving parts

CRI-O now calls Multus for every pod on the pod network, on every node, and Multus calls the cluster CNI. The error above came from Multus (`plugin type="multus" name="multus-cni-network"`). On the 3 nodes without GPUs, Multus restarted 2 to 4 times right after it started. The last restart on each of them was `OOMKilled`. Its default memory limit is 50Mi. After that, it ran without restarts until the end of the tests.

The setup also has the operator, NVIDIA IPAM, the device plugin and 16 networks. Each of them has to work for a pod to get its rails.

### Pod Security

The Baseline Pod Security Standard rejects the pod only for `IPC_LOCK`:

```
Error from server (Forbidden): error when creating "psa-ipvlan-pod.yaml": pods "ipvlan-n1" is forbidden: violates PodSecurity "baseline:latest": non-default capabilities (container "rdma" must not include "IPC_LOCK" in securityContext.capabilities.add)
```

These nodes do not need `IPC_LOCK`, because CRI-O sets an unlimited `memlock` limit for every container. I ran the pods and the NCCL job again without it, on the nodes of [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/). Every rail still gave 95.69 to 96.88 Gb/s, and NCCL reached 190.72 GB/s at 8 GiB. Baseline then admitted the pod in a server dry run:

```
pod/ipvlan-n1 created (server dry run)
```

The dry run checks only admission. The networks are in `default`, so a pod in another namespace also needs networks in its own namespace.

On nodes with a lower limit, the pod needs a higher `memlock` limit or `IPC_LOCK`. `IPC_LOCK` needs the Privileged level. In [part 1](/posts/getting-rdma-into-kubernetes-pods-part-1-hostnetwork/), the pods also failed for `hostNetwork`, and for `privileged` and `hostPath` without the fix.

## When IPvlan fits

IPvlan worked well for one job per node that uses all 16 rails. It got the full bandwidth of `hostNetwork` without `privileged`. The pods kept their own names, DNS and ports.

In these tests, jobs with 4 GPUs and 8 PFs per node needed the Topology Manager. Without it, the kubelet split the rails without looking at the GPUs. The jobs got 26.95 to 58.84 GB/s instead of about 96 GB/s. With `restricted`, they got the full bandwidth, but the kubelet rejects pods that it cannot align. You also have to plan the address pool for the pods on each node.
