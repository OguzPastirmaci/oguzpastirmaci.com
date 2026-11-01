+++
title = "ARP, rp_filter and accept_ra for RDMA Pods on Kubernetes"
date = "2026-11-01"
draft = false
ogImage = "/images/og/arp-rp-filter-and-accept-ra-for-rdma-pods-on-kubernetes.png"
tags = ["rdma", "roce", "kubernetes", "sr-iov", "dranet", "ipv6"]
description = "Where the ARP, rp_filter and accept_ra settings of a multi-rail RDMA node live on Kubernetes, and who sets them."
+++

A GPU node with 16 RoCE rails has 16 network interfaces, often in one subnet. Linux treats an IP address as owned by the host, not by an interface. That default is fine for one NIC. With 16 rails, it breaks RDMA in ways that look like RDMA bugs.

These are some of the failures I saw:

- `ib_write_bw` failed on 6 of 16 rails, and the failing rails changed between runs.
- Two peer addresses resolved to the same MAC address. One of them got the MAC of a VF on another rail.
- NCCL stopped with `ibv_modify_qp failed with 61 No data available`, because most rails had no IPv6 address.

The fix is always a few sysctls. The hard part on Kubernetes is where they live. A pod can get its RDMA interface in several ways. Each way decides which network namespace the interface ends up in, and who owns its settings.

This post goes through each way. The results come from tests I ran between June and October 2026. Most ran on pairs of A100 nodes on OKE (BM.GPU.B4.8 and BM.GPU4.8), with 8 GPUs and 16 RoCE rails each. Most of the IPv6 parts ran on B300 and GB300 nodes.

## The settings

These are the settings that matter here. The meanings come from the kernel's [ip-sysctl documentation](https://docs.kernel.org/networking/ip-sysctl.html).

| Setting | Default | Value used | Meaning of the value used |
|---|---|---|---|
| `arp_ignore` | 0 | 1 | Reply to an ARP request only if the target address is on the interface that received it |
| `arp_announce` | 0 | 2 | Use the best local address of the outgoing interface as the source of an ARP request |
| `rp_filter` | 0 | 0 | No reverse path check on incoming packets |
| `arp_filter` | 0 | 1 or 0 | 1 answers ARP based on routing. 0 turns that off. More on this below |
| `accept_local` | 0 | 1 | Accept packets with a local source address |
| `accept_ra` (IPv6) | 1 | 1 or 2 | 1 accepts router advertisements only if forwarding is off. 2 accepts them even if forwarding is on |

With the defaults, a node answers ARP for any of its addresses on any rail. It also picks any local address as the ARP source. With 16 rails in one subnet, a peer can learn the MAC address of the wrong rail. RoCE frames then go to a MAC that does not exist on that rail, and the fabric drops them.

Each IPv4 setting exists in `conf/all`, `conf/default` and `conf/<interface>`. For `arp_ignore`, `arp_announce` and `rp_filter`, the kernel uses the higher of `conf/all` and `conf/<interface>`. `arp_filter` is on if either one is on. So setting a value on `all` can raise every interface. It can never lower an interface that has a higher value of its own.

`conf/default` is different. It is the starting value for an interface that appears later. For IPv4, writing it does not change the rails. Once an interface has an IPv4 address, the kernel treats all its settings as set. A later `conf/default` write skips it.

## Where the values live

The sysctls under `net.ipv4.conf` and `net.ipv6.conf` belong to a network namespace. A `hostNetwork` pod uses the namespace of the node. Every other pod has its own.

A new namespace does not start empty. The kernel's [`devconf_inherit_init_net`](https://docs.kernel.org/admin-guide/sysctl/net.html#devconf-inherit-init-net) setting controls it, and its default is 0. With 0, a new namespace copies the IPv4 `all` and `default` values of the node. The IPv6 values start from the kernel defaults. I did not test this rule on its own. It does match what I saw below.

An interface that moves into a namespace does not keep its settings. It starts again from the `conf/default` of its new namespace. I checked this by moving an unused rail into a test namespace and back. The columns are `rp_filter`, `arp_ignore`, `arp_announce`, `accept_local` and `arp_filter`:

| Step | Values |
|---|---|
| On the host | 0, 1, 2, 1, 1 |
| In the test namespace | 2, 0, 0, 0, 0 |
| Right after it came back to the host | 2, 0, 0, 0, 0 |
| One second after it came back | 0, 1, 2, 1, 1 |

The `rp_filter=2` in the second and third rows is the node's own `conf/default` value. The kernel default is 0, but these nodes set 2, and the test namespace copied it.

The host values came back because the move back was a udev `add` event. On these nodes, udev runs `systemd-sysctl` for a new interface, and that reapplies the node's per-interface files. Nothing like that runs inside a pod. The rail also lost its route in its policy routing table.

So per-interface values have to be set after the interface arrives, inside the namespace where it ends up.

## hostNetwork pods

A `hostNetwork` pod uses the rails of the node as they are. The node configuration owns every value. The node's host agent set the five values in the first row of the table above, at boot. The pod tests below showed that only two of them matter, `arp_ignore=1` and `arp_announce=2`.

The IPv6 case has one more trap, and the cluster CNI causes it. I hit it on B300 nodes on a dual-stack OKE cluster. The rails have IPv6 addresses only, and each rail gets its address and default route from router advertisements.

Two components on the node changed IPv6 settings that depend on each other, and nothing ordered them:

1. The host agent set `accept_ra` on all 16 rails one time, about 2.5 minutes after boot. It wrote `1` because forwarding was still off.
2. The cluster CNI turned on IPv6 forwarding on the node at the first pod network ADD, about 75 seconds later.

With forwarding on, the kernel ignores router advertisements on an interface with `accept_ra=1`. Turning forwarding on also deletes the default routes that the kernel learned from router advertisements. The only exception is an interface with `accept_ra=2`. This is `__rt6_purge_dflt_routers()` in `net/ipv6/route.c` at [v6.14](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/net/ipv6/route.c?h=v6.14#n4407):

```c
		if (rt->fib6_flags & (RTF_DEFAULT | RTF_ADDRCONF) &&
		    (!idev || idev->cnf.accept_ra != 2) &&
		    fib6_info_hold_safe(rt)) {
			rcu_read_unlock();
			ip6_del_rt(net, rt, false);
			goto restart;
		}
```

I polled one node during its first boot. Each line shows the time, uptime, IPv6 forwarding, rails with an address and rails with a default route:

```
03:01:56 up=205s fwd=0 addr=2/16 defrt=3/16
03:02:25 up=234s fwd=1 addr=5/16 defrt=0/16
```

The rails were still getting their addresses when forwarding came on. Every default route disappeared at that moment, and the rails without an address never got one. On first boots, 3 to 6 of 16 rails had an address, and none had a default route. NCCL failed like this:

```
NCCL WARN Call to ibv_modify_qp failed with 61 No data available, on dev mlx5_9:1,
  curr state INIT, next state RTR, local GID index 3, ...
```

What matters is that the rails have `accept_ra=2` before they get router advertisements while forwarding is on. I added a script that runs early in boot, before the host agent sets `accept_ra`. It sets `accept_ra=2` on the primary NIC, so that NIC keeps its default route from router advertisements. Then it turns on forwarding and sets `accept_ra=2` on the rails. The host agent saw forwarding on and wrote `2` too. Then all 16 rails got their addresses on every first boot. On a 128-node cluster, all 128 nodes had an address on 16 of 16 rails.

One more case needs care. A NIC reset removes the rail interfaces and creates them again. A new interface starts from `conf/default`, so the rails came back with `accept_ra=1`. On Ubuntu 24.04, a sysctl.d file with an interface pattern fixes this, because udev applies it to every new interface:

```
# /etc/sysctl.d/90-oke-rdma-ipv6.conf
net.ipv6.conf.rdma*.accept_ra = 2
```

I tested it on an A100 node. Without the file, the two ports of a reset NIC came back with `accept_ra=1`. With the file, they came back with `2`.

## Pods with Multus interfaces

With Multus, a pod gets extra interfaces from a CNI chain. The interface can be an SR-IOV VF, moved into the pod by the SR-IOV CNI. It can also be an IPvlan child of a rail, created in the pod by the IPvlan CNI. Either way, the interface starts from the `conf/default` of the pod's namespace.

The [tuning CNI](https://www.cni.dev/plugins/current/meta/tuning/) sets sysctls in the same chain. It replaces `IFNAME` with the name of the interface it is configuring, so it can set per-interface values. These are the tuning entries in the NetworkAttachmentDefinition that the SR-IOV Network Operator generated from my SriovNetwork:

```
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.IFNAME.arp_announce=2
net.ipv4.conf.IFNAME.arp_filter=1
net.ipv4.conf.IFNAME.arp_ignore=1
net.ipv4.conf.IFNAME.rp_filter=0
net.ipv4.conf.IFNAME.accept_local=1
```

I compared a pod with only the pod network to a pod with one VF and these entries:

| Value | Pod network only | Pod with a VF |
|---|---|---|
| `all.arp_ignore` | 0 | 0 |
| `all.arp_announce` | 0 | 0 |
| `all.rp_filter` | 0 | 0 |
| `eth0.arp_ignore` | 0 | 0 |
| `eth0.arp_announce` | 0 | 0 |
| `net1.arp_announce` | absent | 2 |
| `net1.arp_filter` | absent | 1 |
| `net1.arp_ignore` | absent | 1 |
| `net1.rp_filter` | absent | 0 |
| `net1.accept_local` | absent | 1 |

Only the VF changed. The pod's `all` values and `eth0` stayed as they were. NCCL over 16 VFs per node reached 190.21 GB/s bus bandwidth at 4 GiB, the largest size in that run.

`all.rp_filter=0` did not change the VFs. Each VF started with `rp_filter=2`, and the kernel uses the higher value. The chain sets `rp_filter` on `IFNAME` too, but in the DRANET tests below, `rp_filter=2` caused no failures.

The tuning CNI runs on the node with the rights of the container runtime. The pod itself needs no privileges for this. I also tried the same settings from an init container with only `CAP_NET_ADMIN`. `/proc/sys` was read-only there, the per-interface values were not set, and NCCL failed.

IPvlan children work the same way. These are the 16 NetworkAttachmentDefinitions, one IPvlan child on each rail. They have the same tuning entries:

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

With them, NCCL reached 190.97 GB/s bus bandwidth at 8 GiB. The pods were not privileged. `IPC_LOCK` was the only capability I added. The pods also got the RDMA devices of the 16 PFs from a device plugin (`nvidia.com/hostdev`). The rails stayed in the host namespace, and the nodes ran in shared RDMA namespace mode.

For IPv6, the pod's namespace has its own forwarding setting, and it starts at 0. So the default `accept_ra=1` accepts router advertisements in the pod. I did not test IPv6 rails with Multus. The DRANET section has the IPv6 result.

## DRANET

[DRANET](https://github.com/kubernetes-sigs/dranet) attaches network devices with Dynamic Resource Allocation. It can move a PF or a VF into the pod. It can also create an IPvlan child of a rail in the pod. The same rule applies. The interface starts from the pod's `conf/default`. By default, nothing applies the node's per-interface values.

The first time I attached 16 VFs with DRANET, all 32 VF addresses were in one `/16`. Nothing set the ARP values. NCCL died with `IBV_WC_REM_INV_REQ_ERR` on varying devices. `ib_write_bw` failed on 6 of 16 rails, and the failing rails changed between runs. The client VF counted `local_ack_timeout_err` and `req_transport_retries_exceeded`, while the server VF received nothing.

The neighbor table of one VF showed the cause. Two peer addresses had the same MAC address. One of them had the MAC of a VF on another rail.

I set the ARP values in the pod before the application started:

```bash
sysctl -w net.ipv4.conf.all.arp_ignore=1 net.ipv4.conf.all.arp_announce=2 \
          net.ipv4.conf.default.arp_ignore=1 net.ipv4.conf.default.arp_announce=2
```

The `all` and `default` values also cover VFs that arrive after the command runs. The pod had to be privileged, because `/proc/sys` is read-only otherwise. After that, two full runs of `ib_write_bw` passed on all 16 rails, 32 of 32. NCCL reached 190.32 GB/s bus bandwidth at 4 GiB.

With PFs, I tested which values are needed. Each of two pods got all 16 PFs. A privileged runner on the node set the values in each pod's namespace. Then it pinged all 32 directional rail-to-rail paths:

| Per-interface values | `all` ARP values | Paths that passed |
|---|---|---|
| The host's five: `rp_filter=0`, `arp_ignore=1`, `arp_announce=2`, `accept_local=1`, `arp_filter=1` | Both 0 | 3 of 32 |
| `rp_filter=2`, `arp_ignore=1`, `arp_announce=2`, the rest 0 | Both 0 | 32 of 32 |
| The namespace defaults: `rp_filter=2`, the rest 0 | `arp_ignore=1`, `arp_announce=2` | 32 of 32 |
| The two ARP values and `rp_filter=0` | Both 0 | 32 of 32 |
| The two ARP values and `accept_local=1` | Both 0 | 32 of 32 |
| The two ARP values and `arp_filter=1` | Both 0 | 3 of 32 |
| `arp_ignore=1` only | Both 0 | 31 of 32 |
| `arp_announce=2` only | Both 0 | 18 of 32 |

The two ARP values were enough, on the interface or on `all`. Neither one was enough alone. `arp_ignore=1` limits which interface replies. `arp_announce=2` limits the source address of a request. The single failure with `arp_ignore=1` alone did not happen on every run. An earlier sweep with the same values passed all 32.

`arp_filter=1` was harmful in this test, but that came from the routing, not from ARP itself. `arp_filter` answers based on a route lookup. The DRANET version I tested copied 16 policy rules into the pod without their output interface, in a random order. The route lookup then often picked another rail's table, and the pod did not answer the ARP request.

I then had a DRANET test branch write only the two ARP values on each PF. Three NCCL runs reached 187.06 to 188.99 GB/s bus bandwidth at 8 GiB.

DRANET now has fields for these values:

- [kubernetes-sigs/dranet#277](https://github.com/kubernetes-sigs/dranet/pull/277) added `arpIgnore` and `arpAnnounce` to the interface configuration of a claim. DRANET writes them in the pod's namespace before the interface comes up.
- [kubernetes-sigs/dranet#326](https://github.com/kubernetes-sigs/dranet/pull/326) made DRANET apply the same settings to IPvlan children.
- [kubernetes-sigs/dranet#341](https://github.com/kubernetes-sigs/dranet/pull/341) added `acceptRA`.
- [kubernetes-sigs/dranet#340](https://github.com/kubernetes-sigs/dranet/pull/340) added an OKE profile for IPv4 RoCE rails. It copies the parent rail's ARP values to each IPvlan child.

I also tested IPvlan children from a DRANET test branch, before #326 and #340 merged. An ordinary pod on the same node had `0` for both ARP values in `conf/default` and `conf/all`. The child had `arp_ignore=1` and `arp_announce=2`, because DRANET wrote them. NCCL over 16 children per pod reached 190.76 GB/s bus bandwidth at 8 GiB.

On GB300 nodes with IPv6 rails, I also tested IPvlan children from a DRANET test branch. The host had `net.ipv6.conf.all.forwarding=1`, and the pods had `0`. The children had `accept_ra=1` and got an address and a default route from router advertisements. If a pod turns on forwarding itself, it needs `accept_ra=2`.

## Pod sysctls

A pod can also set namespaced sysctls in its `spec.securityContext`:

```yaml
securityContext:
  sysctls:
  - name: net.ipv4.conf.all.arp_ignore
    value: "1"
  - name: net.ipv4.conf.all.arp_announce
    value: "2"
```

An NCCL job with 16 PFs per pod from DRANET set them this way. The job also set up per-PF source routing in an init container. It reached 189.50 GB/s bus bandwidth at 8 GiB. Because the kernel uses the higher value, `all` also covers interfaces that arrive later.

Kubernetes treats `net.ipv4.conf.*` as unsafe sysctls. The kubelet runs a pod that sets them only if `allowedUnsafeSysctls` allows them. The OKE kubelet configuration I checked allowed `net.*`. A `hostNetwork` pod cannot use this, because the kubelet rejects network sysctls when the pod uses the host network. The downside is that every workload manifest has to carry the settings.

## Summary

| Setup | Namespace | Who sets the values | Values to set |
|---|---|---|---|
| `hostNetwork` | The node's | The node configuration | `arp_ignore=1` and `arp_announce=2` on each rail. On IPv6 rails, `accept_ra=2` before router advertisements arrive while forwarding is on, and a sysctl.d pattern for new interfaces |
| Multus, SR-IOV VF or IPvlan child | The pod's | The tuning CNI in the chain | `arp_ignore=1` and `arp_announce=2` on `IFNAME` |
| DRANET | The pod's | DRANET's interface configuration | `arpIgnore: 1` and `arpAnnounce: 2`, and `acceptRA: 2` if the pod turns on forwarding (not tested) |
| Pod sysctls | The pod's | The pod spec | `net.ipv4.conf.all.arp_ignore=1` and `arp_announce=2`, if the kubelet allows them |

The node's per-interface values never follow an interface into a pod. Whatever puts the interface there has to set them again.
