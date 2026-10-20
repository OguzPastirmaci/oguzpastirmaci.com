+++
title = "The Trouble With Node Two: torchrun on Host Network"
date = "2026-10-20"
draft = true
tags = ["pytorch", "torchrun", "rdma", "nccl", "kubernetes", "oke"]
description = "Why torchrun loses track of itself when Kubernetes pods use the host network for RDMA, the PyTorch issues that have been open since 2022, and what fixed it on two A100 nodes."
+++

If you want RDMA inside a Kubernetes pod, the simplest way is the host network. The pod uses the network namespace of the node, NCCL sees the RDMA NICs directly, and you get the bandwidth you paid for. On two BM.GPU4.8 nodes on OKE (8 A100 GPUs and 16 RDMA NICs each), NCCL `all_reduce` reached about 191 GB/s bus bandwidth with an 8 GiB buffer.

Then torchrun gets confused. With the host network, every pod has the host name of its node. torchrun uses host names to make two decisions, and both go wrong. Either no node starts the rendezvous store, or node two cannot find node one.

The fix is two command-line flags. The PyTorch issues that explain why you need them have been open since early 2022. I wanted to know if that is still true in the latest PyTorch, so I broke it on purpose.

## The setup

These are the pod settings that give NCCL the RDMA NICs:

```yaml
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  volumes:
  - { name: devinf, hostPath: { path: /dev/infiniband }}
  - { name: shm, emptyDir: { medium: Memory, sizeLimit: 32Gi }}
  containers:
  - name: worker
    securityContext:
      privileged: true
      capabilities:
        add: ["IPC_LOCK", "SYS_ADMIN"]
    volumeMounts:
    - { mountPath: /dev/infiniband, name: devinf }
    - { mountPath: /dev/shm, name: shm }
```

`dnsPolicy: ClusterFirstWithHostNet` is easy to miss, and it matters later. Without it, a host network pod uses the DNS settings of the node, and the pod DNS names of the job do not resolve.

The rest of the test setup:

- 2 x BM.GPU4.8 in one HPC island, OKE v1.36.4
- `nvcr.io/nvidia/pytorch:26.09-py3` (PyTorch 2.14.0a0, NCCL 2.31.2)
- A small DDP script on all 16 GPUs that times an 8 GiB `all_reduce` and then trains a toy model for 200 steps
- Volcano v1.16.0, Kubeflow Training Operator v1.9.4 and Kubeflow Trainer v2.3.0 as launchers

## Two decisions based on a host name

torchrun's `c10d` rendezvous needs one process to host a TCP store. Every node gets the same `--rdzv-endpoint`, and each node must decide on its own if it is the host.

If you do not tell it, torchrun calls [`_matches_machine_hostname()`](https://github.com/pytorch/pytorch/blob/v2.14.1/torch/distributed/elastic/rendezvous/utils.py#L117-L166) from the [`c10d` backend](https://github.com/pytorch/pytorch/blob/v2.14.1/torch/distributed/elastic/rendezvous/c10d_rendezvous_backend.py#L137-L145). That function compares the endpoint with `socket.gethostname()`, and then compares the IP addresses of the endpoint with the IP addresses that the local host name resolves to.

In a host network pod, `socket.gethostname()` returns the name of the node. This is what I saw in a host network pod on node 0:

```
gethostname():              oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0
getfqdn():                  oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0
getaddrinfo(gethostname()): ['127.0.1.1']
```

The Ubuntu nodes map their own name to `127.0.1.1` in `/etc/hosts`. The endpoint, `<job>-worker-0.<job>`, resolves to the real IP address of node 0. The names do not match and the IP addresses do not match, so no node decides to host the store.

The second decision is the address that each node advertises to the others. Without `--local-addr`, torchrun uses [`socket.getfqdn()`](https://github.com/pytorch/pytorch/blob/v2.14.1/torch/distributed/elastic/rendezvous/dynamic_rendezvous.py#L269). On these nodes that is the short node name, and the address of rank 0 becomes `MASTER_ADDR` for everybody. From a pod on node 1:

```
oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0 -> gaierror(-2, 'Name or service not known')
```

## Breaking it on purpose

I took a working Volcano job and removed the flags one at a time. Everything else stayed the same, including the NCCL settings and all 16 NICs.

| Variant | Result |
| --- | --- |
| `is_host` and `--local-addr` | Completed in 23 seconds, 191.0 GB/s |
| No `is_host` | Failed after about 2 minutes, then restarted |
| No `--local-addr` | Still stuck when I stopped it after 10 minutes |
| Neither flag | Failed after about 2 minutes, then restarted |

Without `is_host`, both nodes act as clients and wait for a store that nobody starts:

```
[c10d] TCP client failed to connect/validate to host vc-no-ishost-worker-0.vc-no-ishost:23456 - timed out (try=1, timeout=60000ms)
torch.distributed.elastic.rendezvous.api.RendezvousConnectionError: The connection to the C10d store has failed. See inner exception for details.
```

That one is at least honest. The error points at the rendezvous.

Without `--local-addr`, the rendezvous succeeds, because `is_host` is set. Node 0 starts NCCL and waits. The 8 processes on node 1 try to reach the store at the advertised address, which is the node name of node 0:

```
[c10d] TCP client failed to connect/validate to host oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0:43045 - retrying (try=0, timeout=600000ms, delay=71479ms)
[c10d] The IPv6 network addresses of (oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0, 43045) cannot be retrieved (gai error: -2 - Name or service not known).
```

The client timeout is 600 seconds, and the client retries after it. The job did not fail in the 10 minutes I gave it. Node 0 already printed NCCL setup lines, so it is easy to blame NCCL or the RDMA network.

I removed the same flags from a Training Operator v1 job, and torchrun behaved the same way. Without `is_host`, both pods timed out on the rendezvous store and restarted after about 2 minutes. Without `--local-addr`, the job was still stuck after 10 minutes, with the same `gai error: -2` for the node name of node 0.

One detail surprised me. In the Training Operator run, the pod that hung was the pod with `is_host=true`. torchrun gave ranks 0 to 7 to the other pod, so the pod that hosted the rendezvous store could not reach rank 0. `is_host` decides where the rendezvous store runs. It does not decide which node gets rank 0.

## The issues

Two PyTorch issues describe exactly this, and both are still open:

- [pytorch/pytorch#73380](https://github.com/pytorch/pytorch/issues/73380), opened in February 2022. A 2-node job on Kubernetes with Volcano times out, because the rank 0 host does not realize that it is the master.
- [pytorch/pytorch#73656](https://github.com/pytorch/pytorch/issues/73656), opened in March 2022. The same two problems on a Slurm cluster, where the nodes must use different names to talk across InfiniBand cells. It has 28 comments, and they converge on the same two settings, `is_host` and `local_addr`. One commenter runs a wrapper launcher that adds both settings automatically.

The code in this area is the same in PyTorch v2.14.1, the latest release, and on `main`.

There is also a version trap. [#125743](https://github.com/pytorch/pytorch/pull/125743) added an option to share the rendezvous TCP store and shipped in PyTorch 2.4.0. It also made torchrun ignore `local_addr`. [#135262](https://github.com/pytorch/pytorch/pull/135262) fixed that in 2.5.0. On 2.4.x, `--local-addr` does nothing, so use 2.5 or later.

## The fix for Volcano and Training Operator v1

Tell torchrun who the host is, and give it an address that the other nodes can resolve. Both launchers create a headless Service, so each pod already has a DNS name that resolves to the IP address of its node.

With Volcano, the `svc` and `env` plugins give you the host list and the task index:

```bash
WORKERS=(${VC_WORKER_HOSTS//,/ })
torchrun \
  --rdzv-id=$JOB_ID \
  --rdzv-backend=c10d \
  --rdzv-endpoint=${WORKERS[0]}:23456 \
  --rdzv-conf=is_host=$([ "$VC_TASK_INDEX" = 0 ] && echo true || echo false) \
  --local-addr=${WORKERS[$VC_TASK_INDEX]} \
  --nnodes=$VC_WORKER_NUM \
  --nproc-per-node=8 \
  /scripts/train.py
```

With Training Operator v1, the replica index comes from a pod label and the pod name is the DNS name:

```bash
torchrun \
  --local-addr=$POD_NAME \
  --rdzv-conf=is_host=$([ "$REPLICA_INDEX" = 0 ] && echo true || echo false) \
  --nproc-per-node=8 \
  /scripts/train.py
```

`REPLICA_INDEX` comes from the label `training.kubeflow.org/replica-index`, and `POD_NAME` from `metadata.name`. Training Operator sets the rest of the rendezvous settings itself.

## Trainer v2 does not ask the question

Kubeflow Trainer v2 sets `PET_MASTER_ADDR` to a DNS name of the first pod, for example `ddp-rdma-node-0-0.ddp-rdma`, and `PET_NODE_RANK` for each pod. With a master address, torchrun uses its default `static` rendezvous. There the store host is simply [node rank 0](https://github.com/pytorch/pytorch/blob/v2.14.1/torch/distributed/elastic/rendezvous/static_tcp_rendezvous.py#L65). Nobody compares host names, and with `ClusterFirstWithHostNet` the master address resolves to the IP address of node 0. It worked with no extra flags.

It has its own catches:

- The `TrainJob` API has no field for `hostNetwork` or `dnsPolicy`. They go in a `ClusterTrainingRuntime`.
- The container in the runtime must have the name `node`. Patches in a `TrainJob` must use that name too.
- Trainer v2 adds container port 29500 to every pod. With the host network, Kubernetes turns it into a host port, so only one `TrainJob` pod fits on a node.

```yaml
apiVersion: trainer.kubeflow.org/v1alpha1
kind: ClusterTrainingRuntime
metadata:
  name: torch-distributed-rdma
  labels:
    trainer.kubeflow.org/framework: torch
spec:
  mlPolicy:
    numNodes: 1
    torch: {}
  template:
    spec:
      replicatedJobs:
      - name: node
        template:
          metadata:
            labels:
              trainer.kubeflow.org/trainjob-ancestor-step: trainer
          spec:
            template:
              spec:
                hostNetwork: true
                dnsPolicy: ClusterFirstWithHostNet
                containers:
                - name: node
                  image: nvcr.io/nvidia/pytorch:26.09-py3
```

The full runtime also has the NCCL settings, the `/dev/infiniband` and `/dev/shm` mounts and the security context from the setup above.

## Other things that bit me

The host name problem was the main one, but not the only one.

- **etcd rendezvous and Training Operator v1.** Training Operator does not set a rendezvous ID, so torchrun uses the ID `none` for every job. The first job closes the rendezvous `none` in etcd, and every job after it fails with `RendezvousClosedError`. I set `PET_RDZV_ID` from the job name and used `generateName`, so each run gets a new ID.
- **No etcd client in the NVIDIA image.** The `etcd-v2` backend needs `python-etcd`. Without it, torchrun stops with `EtcdStubError: The 'etcd' module is required but not installed`. The latest release, 0.4.5, is from 2017, and it still works on Python 3.12.
- **Two operators, one CRD.** Training Operator v1 brings its own `MPIJob` CRD (`kubeflow.org/v1`), which conflicts with the stand-alone MPI Operator (`v2beta1`). If Kueue was running while the MPI Operator was installed, Kueue keeps logging `Failed to watch *v2beta1.MPIJob` after you remove it.
- **An `NCCL_IB_HCA` list from another shape.** On BM.GPU4.8, `mlx5_4` is `eth0`, the front-end NIC. A list copied from another GPU shape includes it and leaves out two RDMA NICs. This loop shows which network interface belongs to each RDMA device:

  ```bash
  for d in /sys/class/infiniband/*; do echo "$(basename "$d") $(ls "$d/device/net")"; done
  ```

- **A warning I could not explain.** Every pod logged more than 120 `NCCL WARN NET/MLX5: Call to mlx5dv_devx_general_cmd failed with error Remote I/O error` lines. The bandwidth was the same in every run, so I left it alone.

## How it ended

With the flags in place, every launcher reached the same bandwidth. All runs used all 16 RDMA NICs (`NCCL INFO Using network IB`, GPUDirect RDMA channels, no `NET/Socket`):

| Launcher | Bus bandwidth, `all_reduce`, 8 GiB |
| --- | --- |
| Kubeflow Trainer v2 | 191.0 GB/s |
| Kubeflow Trainer v2 with Kueue | 191.1 GB/s |
| Volcano, c10d | 191.0 GB/s |
| Volcano, etcd | 191.0 GB/s |
| Training Operator v1, c10d | 191.0 GB/s |
| Training Operator v1, etcd | 191.0 GB/s |

For reference, `all_reduce_perf` from nccl-tests on the same nodes reported 182.84 GB/s out-of-place and 190.17 GB/s in-place at 8 GiB.

## What I take from this

- On the host network, do not let torchrun guess. Set `is_host` and `--local-addr` yourself, or use a launcher that passes a master address and lets torchrun use static rendezvous.
- Use PyTorch 2.5 or later. On 2.4.x, `--local-addr` is ignored.
- `dnsPolicy: ClusterFirstWithHostNet` is not optional. All of the fixes above depend on pod DNS names.
- A hang on node two is not always NCCL. Check the rendezvous address first.
- Check the NCCL log for `Using network IB` and GDRDMA. The job status does not tell you which transport NCCL used.
