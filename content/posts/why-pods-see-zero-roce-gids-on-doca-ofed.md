+++
title = "Why Pods See Zero RoCE GIDs on DOCA-OFED"
date = "2026-11-02"
draft = false
ogImage = "/images/og/why-pods-see-zero-roce-gids-on-doca-ofed.png"
tags = ["rdma", "roce", "doca", "kubernetes", "sr-iov"]
description = "Why pods on DOCA-OFED nodes read the host's RoCE GIDs as zero, what the driver does, and what works instead."
+++

I looked into B300 nodes where RDMA worked on the host but not in pods. The pods got all 16 PFs from a device plugin (`nvidia.com/hostdev: 16`). They stayed on the normal pod network. The rail netdevs, `rdma0` to `rdma15`, stayed in the host network namespace. The RDMA namespace mode was shared.

Inside a pod, all 16 ports were ACTIVE. Every GID read as zero, link-local included. UCX failed with `Address not valid`. With `hostNetwork: true`, the same pod worked. `ib_write_bw` reached 383 Gbit/s and `ucx_perftest` reached 45 GB/s.

The nodes ran Ubuntu 24.04, kernel 6.14 and DOCA-OFED. Other B300 nodes ran the stock 6.8.0-137-generic kernel with ConnectX-7. They showed the full GID table in the same kind of pod. I think those nodes use the RDMA stack that ships with the kernel. I did not confirm that.

I read the driver source to find out why. Then I reproduced the problem on my own A100 and B300 nodes.

## The test setup

I tested on two kinds of nodes. Most outputs below are from the A100 nodes.

A100 nodes:

- 2 nodes, each with 8 A100 GPUs and 16 RoCE rails on IPv4
- Ubuntu 24.04, kernel 6.14, DOCA-OFED 3.5.0 (`mlnx-ofed-kernel-dkms` 2607.0.100-1)
- Kubernetes 1.36 with CRI-O 1.36.3, and the NVIDIA Network Operator 26.7.0

B300 nodes:

- Two clusters. The results below use up to 16 nodes on one and 8 nodes on the other.
- Each node has 8 B300 GPUs and 16 ConnectX-8 rails on IPv6. The rail router gives each node its own `/64` on each rail (SLAAC).
- One cluster has an IPv4 pod network. The other has a dual-stack pod network.
- Kernel 6.17, the same DOCA-OFED 3.5.0 build, and the NVIDIA Network Operator 26.7.1

All pod tests used one image with NCCL 2.32.3, perftest 6.28, UCX 1.22.0 and `rdma-core` 64. The tests from a network namespace on the node used the node's own tools.

The pods were not privileged. `IPC_LOCK` was the only capability I added. The exceptions are the `strace` pod and some `hostNetwork` pods. The `strace` pod ran privileged on the pod network. On A100, the `hostNetwork` pods ran privileged, with `/dev/infiniband` mounted from the host. On B300, only the `hostNetwork` NCCL pods did. The B300 `hostNetwork` pod for `ib_write_bw` got the PFs as `nvidia.com/hostdev`, like the other pods.

The A100 node image defaults to the exclusive RDMA namespace mode. My B300 nodes default to shared. I switched modes with the `netns_mode` parameter of `ib_core` and a reboot. `rdma system set netns` returns EBUSY while other network namespaces exist.

## Reproducing it

### From a network namespace on the node

On a node in shared mode, I created a network namespace. Then I read the GID table of one rail from inside it. This is the output. The host lines and the `ibv_devinfo` lines are trimmed to the IPv4 entries:

```
host gid 2: 0000:0000:0000:0000:0000:ffff:0ae0:0c8f IB/RoCE v1
host gid 3: 0000:0000:0000:0000:0000:ffff:0ae0:0c8f RoCE v2
gidtest gid 0: 0000:0000:0000:0000:0000:0000:0000:0000
gidtest gid 1: 0000:0000:0000:0000:0000:0000:0000:0000
gidtest gid 2: 0000:0000:0000:0000:0000:0000:0000:0000
gidtest gid 3: 0000:0000:0000:0000:0000:0000:0000:0000
gidtest type 3: cat: /sys/class/infiniband/mlx5_6/ports/1/gid_attrs/types/3: Invalid argument
gidtest ndev 3: cat: /sys/class/infiniband/mlx5_6/ports/1/gid_attrs/ndevs/3: Invalid argument
gidtest ibv_devinfo GIDs:
			GID[  2]:		0000:0000:0000:0000:0000:ffff:0ae0:0c8f, RoCE v1
			GID[  3]:		::ffff:10.224.12.143, RoCE v2
```

From the new namespace, sysfs showed zeros, and the GID attributes failed with `Invalid argument`. `ibv_devinfo -v` still showed the real GIDs from the same namespace.

### From a pod with the host PFs

Next, I recreated the original pod setup. Each pod got all 16 PFs with `nvidia.com/hostdev: 16` and had only the pod network. The pod saw the same picture, trimmed to one PF:

```
== 0000:0c:00.0 -> mlx5_6
  sysfs gid 0: 0000:0000:0000:0000:0000:0000:0000:0000 cat: /sys/class/infiniband/mlx5_6/ports/1/gid_attrs/types/0: Invalid argument
  sysfs gid 1: 0000:0000:0000:0000:0000:0000:0000:0000 cat: /sys/class/infiniband/mlx5_6/ports/1/gid_attrs/types/1: Invalid argument
  sysfs gid 2: 0000:0000:0000:0000:0000:0000:0000:0000 cat: /sys/class/infiniband/mlx5_6/ports/1/gid_attrs/types/2: Invalid argument
  sysfs gid 3: 0000:0000:0000:0000:0000:0000:0000:0000 cat: /sys/class/infiniband/mlx5_6/ports/1/gid_attrs/types/3: Invalid argument
  ibv_devinfo GID 3: 			GID[  3]:		::ffff:10.224.12.143, RoCE v2
```

Between two such pods, `ib_write_bw` with `-d mlx5_6 -x 3` failed when it connected the queue pair:

```
Failed to modify QP 134 to RTR
 Unable to Connect the HCA's through the link
```

I ran the same command from a privileged pod with `strace`. The verbs call that failed returned `ENODEV`:

```
8917  ioctl(3, RDMA_VERBS_IOCTL, 0x7ffd88c57360) = -1 ENODEV (No such device)
```

`ucx_perftest` with `UCX_TLS=rc_x` and `UCX_NET_DEVICES=mlx5_6:1` failed on both sides with the same error as on the original B300 nodes. This is the client side, trimmed:

```
ucp_worker.c:1492 UCX  ERROR uct_iface_open(rc_mlx5/mlx5_6:1) failed: Address not valid
perftest_run.c:363  UCX  ERROR Failed to run test: Address not valid
```

I repeated this pod setup on my B300 nodes. The GIDs read zero there too, and UCX failed with the same `Address not valid` error.

### In exclusive mode

In exclusive mode, the same pod got the character devices but no RDMA devices:

```
RDMA netns mode: N (Y = shared, N = exclusive)
RDMA devices in /sys/class/infiniband: 0
```

`ibv_devices` listed nothing, so no test could run at all.

## What upstream Linux does

Upstream does not filter GIDs by namespace in sysfs or in the verbs calls. In [v6.14](https://github.com/torvalds/linux/blob/v6.14/drivers/infiniband/core/sysfs.c), `show_port_gid()` in `drivers/infiniband/core/sysfs.c` prints the GID as it is. `rdma_query_gid_table()` in `cache.c` returns every valid entry. There is no per-GID namespace test in `sysfs.c`, `cache.c`, `verbs.c` or the uverbs files.

In shared mode, every namespace gets the full GID files in sysfs. So on upstream, a pod should see every GID.

## The DOCA-OFED source

DOCA-OFED replaces the `ib_core` module of the kernel with its own build. The source is in the `mlnx-ofed-kernel-dkms` package, the same tree that DKMS builds on a node. I took it for three DOCA releases from the public repository:

- DOCA 3.3.0, [26.01.OFED.26.01.1.0.0.1-1](https://linux.mellanox.com/public/repo/doca/3.3.0/ubuntu24.04/x86_64/mlnx-ofed-kernel-dkms_26.01.OFED.26.01.1.0.0.1-1_all.deb)
- DOCA 3.4.0, [26.04.OFED.26.04.0.8.6.1-1](https://linux.mellanox.com/public/repo/doca/3.4.0/ubuntu24.04/x86_64/pool/mlnx-ofed-kernel-dkms_26.04.OFED.26.04.0.8.6.1-1_all.deb)
- DOCA 3.5.0, [2607.0.100-1](https://linux.mellanox.com/public/repo/doca/3.5.0/ubuntu24.04/x86_64/pool/mlnx-ofed-kernel-dkms_2607.0.100-1_all.deb)

My test nodes ran the 3.5.0 package, so the line numbers below are from 3.5.0.

## The check

`cache.c` has a function that upstream does not have (line 1708):

```c
bool rdma_check_gid_user_access(const struct ib_gid_attr *attr)
{
	bool allow;
	/*
	 * For IB and iWarp, there is no netdevice associate with GID entry,
	 * For RoCE consider the netdevice's net ns to validate against the
	 * calling process.
	 */
	rcu_read_lock();
	if (!attr->ndev ||
	    (attr->ndev &&
	     net_eq(dev_net(attr->ndev), current->nsproxy->net_ns)))
		allow = true;
	else
		allow = false;
	rcu_read_unlock();
	return allow;
}
```

A GID with no netdev always passes. That covers InfiniBand and iWARP. A RoCE GID passes only if its netdev is in the network namespace of the calling process. In the pods, `rdma0` to `rdma15` were in the host namespace, so every RoCE GID failed.

OFED calls the check from three places, reached through four interfaces:

| Interface | Function | Line | Result in another namespace | Seen in my tests |
|---|---|---|---|---|
| `/sys/class/infiniband/<dev>/ports/<p>/gids/<i>` | `show_port_gid()` | `sysfs.c:444` | An all-zero GID | Yes |
| `.../gid_attrs/ndevs/<i>` and `.../gid_attrs/types/<i>` | `_show_port_gid_attr()` | `sysfs.c:411` | The read fails with EINVAL | Yes |
| `ibv_modify_qp()` with an address, from user space | `_ib_modify_qp()` calls `ib_resolve_eth_dmac()` | `verbs.c:1862`, check at 1807 | ENODEV | Yes |
| `ibv_create_ah()` on RoCE | `rdma_create_user_ah()` calls `ib_resolve_eth_dmac()` | `verbs.c:671`, check at 1807 | ENODEV | Yes, on B300 |

I saw the `ibv_create_ah()` case on my B300 nodes. From a new network namespace on a node, `ib_send_bw -c UD -x 3` failed with `Failed to create AH`. One verbs ioctl returned ENODEV.

DOCA 3.3.0 and 3.4.0 have the same function at the same call sites. Only the line numbers differ from the 3.5.0 numbers above, by up to 11 lines. I tested only 3.5.0 live.

So the pod does not only see zeros. It also cannot use those GIDs. NCCL and `ib_write_bw` connect RC queue pairs with `ibv_modify_qp()`, and that is the call that failed with ENODEV.

## What the check misses

Two uverbs ioctls do not call the check, `UVERBS_METHOD_QUERY_GID_ENTRY` and `UVERBS_METHOD_QUERY_GID_TABLE`. They are the same as upstream. In [rdma-core](https://github.com/linux-rdma/rdma-core/blob/master/libibverbs/cmd_device.c), `ibv_query_gid()` and `ibv_query_gid_ex()` use the ioctl first and read sysfs only if the kernel lacks it. That is why `ibv_devinfo -v` showed the real GIDs while sysfs showed zeros.

[UCX](https://github.com/openucx/ucx/blob/master/src/uct/ib/base/ib_device.c) reads both:

- `uct_ib_device_query_gid_info()` calls `ibv_query_gid()`. Then it reads `gid_attrs/types/<i>` from sysfs. That read fails, so UCX treats the GID as RoCE v1.
- `uct_ib_device_select_gid()` tests each candidate GID with `ibv_create_ah()`. That test reaches the same check.
- `Address not valid` is how UCX prints `UCS_ERR_INVALID_ADDR`. UCX returns it for a zero GID and when `ibv_create_ah()` fails with an error other than a timeout.

The error appeared when UCX opened the interface. I did not capture which of these calls returned it.

## Where it came from

The check is not in MLNX_OFED 4.3-1.0.1.0. It is in 4.4-1.0.0.0 from 2018. It has the same body and call sites in every version I checked, from 4.4 to DOCA 3.5.0. Upstream v6.8, v6.14 and master do not have it.

The design matches a talk by Parav Pandit at the 14th OFA Workshop in April 2018, [RDMA Containers Update](https://openfabrics.org/images/2018workshop/presentations/115_PPandit_RoCEContainers.pdf). The slides show one shared RDMA device with one macvlan netdev per container, and "GID entry based isolation". A container sees and uses only the GIDs of the netdevs in its own namespace.

## No switch turns it off

- The check reads only two things, the netdev of the GID and the namespace of the caller. It reads no global variable, module parameter or sysfs file.
- `ib_core` has five module parameters, `netns_mode`, `send_queue_size`, `recv_queue_size`, `mad_smp_window` and `force_mr`. None of them changes the check.
- No `#if` or `#ifdef` encloses the function or its call sites. So no build option removes it.
- Firmware and devlink settings cannot change it.
- The DOCA `-userspace` install profiles, such as `doca-ofed-userspace`, do not pull in the OFED kernel modules. A node that loads the kernel's own RDMA modules has no check. I did not test that on these nodes.

## Exclusive mode does not help

The exclusive RDMA namespace mode changes which namespace can use an RDMA device. The check never reads that mode, and the netdevs stay on the host either way.

In my test, the pod in exclusive mode saw no RDMA devices at all. The code also blocks the next step. The uverbs open path returns EPERM when the device belongs to another namespace (`uverbs_main.c:989`). I did not see that error, because the pod never got as far as opening a device.

Moving only the RDMA device into the pod does not fix it either. The GIDs still belong to the netdev on the host. I tested this on my B300 nodes in exclusive mode. I moved the RDMA device of a VF into a new network namespace and left its netdev on the host. In that namespace, GIDs 0 to 3 read zero, while `ibv_devinfo` showed the real GIDs. When I moved the netdev too, sysfs showed all four GIDs.

## What works

The pod needs its own netdev on each rail, inside its namespace. The kernel creates GIDs for the addresses on that netdev, and those GIDs pass the check. I tested three ways to do that on the two A100 nodes. The `hostNetwork` row is the reference.

Each `ib_write_bw` test ran one pair per rail on all 16 rails at once. In the pod setups, each pair used 64 KiB messages and 4 QPs. Each NCCL run in the table was `all_reduce_perf` on 2 nodes with 8 GPUs each. The table shows my first run of each setup:

| Setup | RDMA namespace mode | GIDs in the pod | `ib_write_bw`, 16 rails at once | NCCL bus bandwidth at 8 GiB, out of place / in place |
|---|---|---|---|---|
| `hostNetwork: true` | Exclusive | The rail GIDs | 842.93 Gbit/s | 190.99 / 190.97 GB/s |
| One SR-IOV VF per rail, with the RDMA CNI | Exclusive | The VF's own GIDs | 768.11 Gbit/s | 190.90 / 190.83 GB/s |
| One SR-IOV VF per rail, without the RDMA CNI | Shared | The VF's own GIDs. The host GID 3 of one PF (`mlx5_0`) read zero | 763.96 Gbit/s | 190.91 / 191.08 GB/s |
| 16 host PFs plus one IPvlan L2 child per rail | Shared | Each child's own GID, at index 5. The host GID 3 of `mlx5_6` read zero | 804.86 Gbit/s | 190.97 / 190.84 GB/s |

The `ib_write_bw` totals moved between runs of the same setup. These are the ranges over all my runs:

- Exclusive VF: 685.97 to 768.11 Gbit/s, in 3 runs
- Shared VF: 763.96 to 863.09 Gbit/s, in 2 runs
- IPvlan: 746.03 to 804.86 Gbit/s, in 2 runs

The `hostNetwork` setup had one run. NCCL stayed between 190.45 and 191.08 GB/s at 8 GiB in every run of the three pod setups.

The IPvlan row is the original pod setup with one network added per rail. Inside the same pod, the host GID 3 of a PF still read zero. The child's GID on that same PF worked. UCX worked too. `ucx_perftest` with `ucp_put_bw` and 1 MiB messages reached 11630.75 MB/s on one rail. On these nodes, UCX picked the child's GID by itself. Trimmed:

```
ib_device.c:1205 UCX  DEBUG mlx5_6:1 using gid_index=5 ver=2 addr_family=2
```

The networks below need other objects too:

- In both setups, a NicClusterPolicy deploys Multus, the CNI plugins and NV-IPAM.
- In the IPvlan setup, the NicClusterPolicy also offers the 16 rail PFs as `nvidia.com/hostdev`, selected by PCI address. The `rdma-ipvlan-pool` gives out the addresses, from a range that is not in use on the rails.
- In the VF setup, a SriovNetworkNodePolicy creates the VFs as `nvidia.com/rdma-vf`. A SriovNetworkPoolConfig makes the operator configure one node at a time. The `sriov-pool` gives out the addresses.

These are the A100 networks, for IPv4 rails in one flat subnet. There, one pool can serve all 16 rails. My B300 nodes have routed IPv6 rails, so the IPvlan children get their addresses another way. The VF networks did not work there. The last section covers both.

These are the 16 IPvlan networks:

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

The VF networks differ only in the RDMA CNI. In both modes, the SR-IOV CNI moves the VF netdev into the pod. In exclusive mode, the RDMA CNI also moves its RDMA device:

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

In shared mode, the RDMA CNI refuses to run. With it in the chain, the pod stayed in `ContainerCreating`:

```
plugin type="rdma" failed (add): RDMA subsystem namespace awareness mode is set to shared
```

So the shared network leaves it out:

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

This is also the pattern in the [NVIDIA Network Operator docs](https://docs.nvidia.com/networking/display/kubernetes2670/quick-start/host-device-rdma.html). A RoCE pod gets two things, a device plugin resource and a network attachment. The resource only mounts the RDMA character devices. The attachment puts a netdev on the same NIC into the pod. The original pods had the resource but no attachment.

Two GitHub issues show the same symptom. In [k8s-rdma-shared-dev-plugin#72](https://github.com/Mellanox/k8s-rdma-shared-dev-plugin/issues/72), a pod with only the pod network saw zero GIDs and failed to move its QP to RTR. The maintainer suggested a macvlan network on the RDMA NIC. In [#112](https://github.com/Mellanox/k8s-rdma-shared-dev-plugin/issues/112), the GIDs were zero because the macvlan master was not on the RDMA NIC. The maintainer said the master must be the netdev of the RDMA NIC.

## On B300 with IPv6 rails

On my B300 nodes, the check behaved the same as on A100, with ConnectX-8 NICs and IPv6 GIDs. From a new network namespace, sysfs showed zero GIDs, and the GID attributes failed with `Invalid argument`. `ibv_devinfo -v` showed the real GIDs.

These nodes have IPv6-only rails, and each node has its own routed `/64` on each rail. So one pool cannot give the IPvlan children routable addresses. The B300 version of the IPvlan networks works like this:

- The pool gives each child a placeholder address from `fd01:0:0:100::/112`. This address lets the IPvlan CNI start. It does not route.
- The placeholder address also makes the CNI turn on IPv6 for the child. On the cluster with the IPv4 pod network, pods have IPv6 turned off. Without the placeholder, the child gets no SLAAC address.
- The rail router sends router advertisements. From them, each child gets its routed address (SLAAC) and a default route.
- The networks have no `tuning` or `sbr` plugin. The ARP settings are for IPv4, and source routing does not help an address that does not route.

In the pods, each child's SLAAC address had a RoCE v2 GID at index 9, on all 16 rails. The host GID 3 still read zero. NCCL over IPvlan matched `hostNetwork` on both clusters. This is the bus bandwidth at 8 GiB in GB/s, out of place / in place:

| Pod network | Nodes | IPvlan | `hostNetwork` |
|---|---|---|---|
| IPv4 | 2 | 882.91 / 883.20 | 881.49 / 881.56 |
| IPv4 | 4 | 770.51 / 773.90 | 773.70 / 769.54 |
| IPv4 | 16 | 762.76 / 763.16 | 765.64 / 769.56 |
| Dual stack | 2 | 882.56 / 881.78 | 882.64 / 882.25 |
| Dual stack | 8 | 765.68 / 773.45 | 771.84 / 773.13 |

On the cluster with the IPv4 pod network, `ib_write_bw` in the pods was uneven from rail to rail. A `hostNetwork` pod with the same image showed the same pattern. The node's own perftest gave about 232.5 Gbit/s on every rail. So the unevenness came from the image or the pod, not from IPvlan. On the dual-stack cluster, the runs on the node were uneven too. Each run had two rails below 90 Gbit/s.

Every NCCL run over IPvlan had `NCCL_IB_GID_INDEX=9`, set from the SLAAC GID. UCX needed the same setting. By itself, it picked GID index 5, the GID of the placeholder address. That address does not route, so UCX could not reach the peer. Trimmed:

```
libperf.c:1200 UCX  ERROR ucp_ep_create() failed: Endpoint timeout
perftest_run.c:363  UCX  ERROR Failed to run test: Endpoint timeout
```

I measured UCX on the cluster with the IPv4 pod network. With `UCX_IB_GID_INDEX=9`, `ucp_put_bw` with 1 MiB messages reached 45564.31 to 45613.37 MB/s with `rc_x` on one rail, in 3 runs. One earlier run reached only 24918.28 MB/s. On the host, the same test reached 45566.88 and 45683.42 MB/s.

The VF networks did not work on these B300 nodes. The VFs got their own GIDs and passed the GID check. But their IPv4 pool does not route on IPv6 rails. So `ib_write_bw` failed on all 16 rails, and NCCL hung. Next, I gave the VFs SLAAC addresses with an IPv6 placeholder pool, and tested one rail. QP setup then passed, but no traffic got through.

The NIC counters showed why. Of 10003 frames that left the sending VF's port, 1 reached the receiving port. Between the PFs on the same rail, all 10000 frames arrived. So this fabric drops frames from VF MAC addresses. That is a fabric setting, not the GID check. VFs need a fabric that accepts frames from their MAC addresses.
