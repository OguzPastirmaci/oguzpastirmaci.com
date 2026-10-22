+++
title = "Why Large RoCE Frames Disappeared on OVS-DOCA 3.5"
date = "2026-10-20"
draft = false
ogImage = "/images/og/why-large-roce-frames-disappeared-on-ovs-doca-3-5.png"
tags = ["ovs", "doca", "dpdk", "rdma", "roce"]
description = "How OVS-DOCA 3.5 kept receive buffers sized for a 1500-byte MTU, so large RoCE frames vanished. One ovs-vsctl transaction fixed it."
+++

I looked into GB300 hosts where RDMA broke after an image update. `ib_write_bw` between two hosts worked with 512-byte messages. With 64 KiB messages, it showed 0 Gb/s. The links were up on the host and on the switch. Hosts on the older image worked.

The cause was a small change in how OVS-DOCA reuses its receive buffer pools. On the new version, the pools kept the size for a 1500-byte MTU, although every port said 9216. RoCE frames of about 4.2 KB did not fit, and no counter called them dropped.

## The two images

The images differed in the OVS-DOCA build. These are the versions on each image:

| | Working host | Affected hosts |
|---|---|---|
| `ovs_version` | 3.3.0040 | 3.5.0052 |
| DOCA in the OVS build | 3.3.0404 | 3.5.0098 |
| `dpdk_version` | DPDK 25.11.0+doca2601 | DPDK 26.03.0 |
| OS | Ubuntu 24.04, ARM64 | Ubuntu 24.04, ARM64 |

Both images had the same `other_config` in OVSDB. It set `doca-init=true`, `hw-offload=true`, `doca-eswitch-max=4`, `hw-offload-ct-size=0` and `max-idle=300000`.

## How the traffic flows on these hosts

Each host has four ConnectX-8 devices, one per rail. OVS-DOCA runs one bridge per rail, `br-rail0` to `br-rail3`. The bridges use the userspace datapath (`datapath_type=netdev`). Each bridge has five DPDK ports:

- `rdma_p0_rail0` to `rdma_p3_rail0` are the four 200G PFs of the device. The first PF is the eswitch manager. The other three are representors (`representor=pf1` to `pf3`).
- `rdma0` is the representor of VF 0 on the first PF. The host sends its RDMA traffic through that VF.

Every DPDK port had `mtu_request=9216` and showed `mtu 9216` in OVSDB.

Hardware offload is on. The first packet of a new flow misses the flow tables in the NIC. The NIC steers it to a software receive queue. `ovs-vswitchd` reads it, builds a datapath flow, and offloads that flow to the NIC. The later packets of the flow stay in hardware.

So every flow needs its first packet to reach software.

## The counters

I started with `ovs-vsctl list Interface`. This is `rdma0` on an affected host, trimmed to the receive counters:

```
name                : rdma0
statistics          : {... rx_bytes=386823345, rx_dropped=0, rx_errors=0, ... rx_ipv6_udp_bytes=386806897, rx_ipv6_udp_packets=91186, rx_missed_errors=0, ... rx_packets=91307, rx_q0_bytes=17848, rx_q0_packets=128, ...}
```

Two of these counters matter. In OVS-DOCA, `rx_packets` and `rx_bytes` add up the hits on the DOCA Flow rules that steer packets to software. That is `ovs_doca_eth_stats_get()` in `lib/ovs-doca.c`. `rx_q0_packets` counts the packets that OVS actually read from receive queue 0. These ports had one receive queue (`n_rxq=1`). So on a healthy port, the two are equal.

On the affected host, they were far apart on `rdma0` and `rdma1`:

| Port | `rx_packets` | `rx_q0_packets` | Missing packets | Average missing frame |
|---|---|---|---|---|
| `rdma1` | 958764 | 127 | 958637 | 4243 B |
| `rdma0` | 91307 | 128 | 91179 | 4242 B |

The average comes from `rx_bytes` minus `rx_q0_bytes`, divided by the missing packets. About 4.2 KB is the size of a RoCE frame with a 4096-byte MTU.

On the working host, the counters matched. `rdma1` had `rx_packets=6011` and `rx_q0_packets=6011`, and 17820088 bytes on both sides. Every port on that host looked like this.

## The flows

`ovs-appctl dpctl/dump-flows -m` lists the datapath flows. These are the UDP flows that came in on `rdma0`, with only a few fields kept:

```
nv_mp_pid(0x3) nv_mp_preferred(0x1) nv_mp_strict(0x1) in_port(rdma0) udp(src=59028/0,dst=4791/0) packets:9087 bytes:1363050 offloaded:yes dp:doca actions:rdma_p3_rail0
nv_mp_pid(0x2) nv_mp_preferred(0x1) nv_mp_strict(0x1) in_port(rdma0) udp(src=65473/0,dst=4791/0) packets:1693 bytes:253950 offloaded:yes dp:doca actions:rdma_p2_rail0
nv_mp_pid(0) nv_mp_preferred(0x1) nv_mp_strict(0x1) in_port(rdma0) udp(src=59028/0,dst=4791/0) packets:1702 bytes:255300 offloaded:yes dp:doca actions:rdma_p0_rail0
nv_mp_pid(0x1) nv_mp_preferred(0x1) nv_mp_strict(0x1) in_port(rdma0) udp(src=55794/0,dst=4791/0) packets:1715 bytes:257250 offloaded:yes dp:doca actions:rdma_p1_rail0
```

Every UDP flow from the VFs carried exactly 150 bytes per packet. These small flows were offloaded and worked. There was no flow for the 4.2 KB data frames at all.

The first packet of a data flow never reached `ovs-vswitchd`, so OVS never built a flow for it. Every later packet missed the hardware tables too, and went the same way. Small frames from the VFs had no such problem. That is why 512-byte messages worked.

## The buffer pools

The receive queues put packets into DPDK mbufs from a mempool. `ovs-appctl netdev-doca/get-mempool-info` lists the pools. This is the first pool on an affected host, trimmed:

```
mempool <ovs3169b47e00021580011328>@0x21812a3e80
  flags=10
  socket_id=0
  ...
  size=11328
  ...
  elt_size=2944
  trailer_size=0
  total_obj_size=3072
```

The host had four pools like this one, all with `elt_size=2944`. That is one pool for each of the four eswitches, because all ports of one eswitch share a pool. The working host had eight pools. Four had `elt_size=2944` and four had `elt_size=11136`.

The pool name tells the size. OVS builds it from the format `ovs%08x%02d%05d%07u`, which is a hash, the socket, an MTU and the number of mbufs. Here the MTU part is `02158`. That is the value OVS computes for MTU 1500:

```
dpdk_buf_size(1500)    = ROUND_UP(1500 + 26, 1024) + 128 = 2176
FRAME_LEN_TO_MTU(2176) = 2176 - 18                       = 2158
```

The data room of each mbuf is 2176 bytes. The first 128 bytes are headroom. That leaves 2048 bytes for the frame, so a 4.2 KB frame does not fit in one buffer.

| MTU | MTU part of the name | Room for the frame | `elt_size` |
|---|---|---|---|
| 1500 | 02158 | 2048 B | 2944 |
| 9000 | 09326 | 9216 B | 10112 |
| 9216 | 10350 | 10240 B | 11136 |

I saw all three pool sizes on real hosts. The affected host had the 1500 pools. The working host had 1500 and 9216. The fixed hosts below had 9000.

## What changed in the source

NVIDIA's public DOCA repository has the OVS source for both versions, in the `openvswitch-source` package:

- [3.3.0040-1.2601100.2601100.0622](https://linux.mellanox.com/public/repo/doca/3.3.0-088821/ubuntu24.04/arm64-sbsa/pool/openvswitch-source_3.3.0040-1.2601100.2601100.0622_all.deb) in DOCA 3.3.0 (the 3.3.0-088821 build)
- [3.5.0052-1](https://linux.mellanox.com/public/repo/doca/3.5.0/ubuntu24.04/arm64-sbsa/pool/openvswitch-source_3.5.0052-1_all.deb) in DOCA 3.5.0

The code is in `lib/netdev-doca.c`. Before it creates a pool, `dpdk_mp_get()` looks for one to reuse. In 3.3.0040, it compares the socket, the eswitch and the MTU (lines 870 to 874):

```c
        LIST_FOR_EACH (dmp, list_node, &dpdk_mp_list) {
            if (dmp->socket_id == dev->requested_socket_id
                && dmp->esw_mgr_port_id == dev->esw_mgr_port_id
                && dmp->mtu == mtu) {
                VLOG_DBG("Reusing mempool \"%s\"", dmp->mp->name);
```

In 3.5.0052, the MTU is gone (lines 816 to 819):

```c
    LIST_FOR_EACH (dmp, list_node, &dpdk_mp_list) {
        if (dmp->socket_id == dev->requested_socket_id
            && dmp->esw_mgr_port_id == dev->esw_mgr_port_id) {
            VLOG_DBG("Reusing mempool \"%s\"", dmp->mp->name);
```

`struct dpdk_mp` no longer has an `mtu` field at all.

I also checked [3.4.0040-1.2604086](https://linux.mellanox.com/public/repo/doca/3.4.0/ubuntu24.04/arm64-sbsa/pool/openvswitch-source_3.4.0040-1.2604086_all.deb) from DOCA 3.4.0. It already has the 3.5 version of this loop. I did not have 3.4 hosts, so I know this only from the source.

This is what happened on the affected hosts:

1. The port was added without an MTU. A new port starts with `requested_mtu = RTE_ETHER_MTU`, which is 1500 (line 1668). The first reconfigure built the eswitch pool for 1500.
2. Then `mtu_request=9216` was set on every port. The first PF, the eswitch manager, was already running. So the MTU change made OVS remove that port and add it again (`netdev_doca_reconfigure()` sets `need_restart` at line 4640). The new port asked `dpdk_mp_get()` for a pool for MTU 9216. The loop found the 1500 pool for the same socket and eswitch, and returned it. Nothing new was allocated.
3. `netdev_doca_mempool_configure()` then set the port MTU to 9216 and `max_packet_len` to 9234. OVSDB showed `mtu 9216`. The buffers stayed at 2048 bytes.
4. The representors followed the eswitch manager. On a running representor, `netdev_doca_set_mtu()` ignores `mtu_request`. It logs `setting requested MTU %d is ignored for representor device` (line 3684). `netdev_doca_rep_set_esw_mgr_mtu()` copies the MTU of the manager instead (line 855). So `rdma0` also showed 9216, on the same small pool.
5. The first 4.2 KB frame of each RoCE flow went to the software queue and was lost. No flow was built, so nothing was offloaded.

On 3.3, the request in step 2 gets a new pool for 9216. There, the MTU is part of the match. The 1500 pools stayed too. That is why the working host showed eight pools.

## Order, not value

`vswitchd/bridge.c` shows why the order matters. `iface_do_create()` first opens the netdev (line 2170) and applies `mtu_request` (line 2182). Only then does it add the port to the datapath (line 2185). Say the Interface row has `mtu_request` when the port is created. Then the first pool for the eswitch is already the right size. In the broken order, the 1500 pool already existed when the large one was requested. 3.5 handed it back.

The value does not matter. The hosts used 9216, but 9000 works just as well if it is set when the port is created. Both pools have room for frames much larger than 4.2 KB. Here, only the pool built for 1500 was too small.

## The fix

The quick fix is a restart of the `openvswitch-switch` service. At start, every Interface row already has `mtu_request`, so each port gets a large pool from the start. On one affected host:

```bash
sudo systemctl restart openvswitch-switch
```

These bridges use `fail_mode=secure`, and a restart drops the OpenFlow rules and groups added with `ovs-ofctl`. Re-apply them after the restart, or the bridges forward nothing.

```bash
sudo ovs-appctl netdev-doca/get-mempool-info | grep elt_size
```

After the restart, the host had four pools with `elt_size=11136` and none with 2944. This is `ib_write_bw` with 65535-byte messages after the restart:

```
 #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
 65535      2944850          0.00               771.94               1.472381
 65535      2944935          0.00               771.96               1.472419
```

It held 772 Gb/s on a rail of four 200G ports.

The lasting fix is to set the MTU in the same `ovs-vsctl` transaction that adds the port. The broken order used two transactions:

```bash
sudo ovs-vsctl add-port br-rail0 rdma_p0_rail0 -- set int rdma_p0_rail0 type=dpdk
```

```bash
sudo ovs-vsctl set int rdma_p0_rail0 mtu_request=9216
```

`ovs-vsctl` sends all commands on one command line, joined with `--`, as one transaction. This is the fixed form, as it ran on hosts with the same 3.5.0052 build:

```bash
sudo ovs-vsctl add-port br-rail0 rdma_p0_rail0 -- set int rdma_p0_rail0 type=dpdk mtu_request=9000
```

Those hosts had four pools with `elt_size=10112`, the size for MTU 9000. On one of them, `rdma0` showed `rx_packets=3794` and `rx_q0_packets=3794`, with frames of about 4.2 KB. `ovs-vswitchd` also logged the representors taking the MTU of the manager:

```
2026-09-21T20:38:43.825Z|00646|netdev_doca|INFO|rdma3: Aligning representor device MTU with eswitch manager's MTU (9000).
```

If you run OVS-DOCA 3.5, set `mtu_request` when you add the port. From the source, the same applies to 3.4.
