+++
title = "Why torchrun Can't Find Node Two on the Host Network"
date = "2026-10-20"
draft = false
tags = ["pytorch", "torchrun", "rdma", "nccl", "kubernetes", "oke"]
description = "Why torchrun loses track of itself when Kubernetes pods use the host network for RDMA, the PyTorch issues that have been open since 2022, and what fixed it on two A100 nodes."
+++

If you want RDMA inside a Kubernetes pod, the simplest way is the host network. The pod uses the network namespace of the node, NCCL sees the RDMA NICs directly, and you get the bandwidth you paid for. On two BM.GPU4.8 nodes on OKE (8 A100 GPUs and 16 RDMA NICs each), NCCL `all_reduce` reached about 191 GB/s bus bandwidth with an 8 GiB buffer.

Then torchrun gets confused. With the host network, every pod has the host name of its node, and torchrun uses host names to make two decisions. On these nodes, both decisions went wrong, because each node resolves its own name to `127.0.1.1` and the other node cannot resolve it at all. Either no node starts the rendezvous store, or node two cannot find node one.

The fix is two command-line flags. The PyTorch issues that explain why you need them have been open since early 2022. I wanted to know if that is still true in the latest PyTorch, so I broke it on purpose.

Every manifest and command in this post ran on the two nodes. Long files are collapsed, so click a file name to open it.

## The setup

- 2 x BM.GPU4.8, OKE v1.36.4
- `nvcr.io/nvidia/pytorch:26.09-py3` (PyTorch 2.14.0a0, NCCL 2.31.2)
- Volcano v1.16.0, Kubeflow Training Operator v1.9.4 and Kubeflow Trainer v2.3.0 as launchers
- A DDP script on all 16 GPUs that times an 8 GiB `all_reduce` and then trains a toy model for 200 steps

Every worker pod in this post has the same RDMA settings:

- `hostNetwork: true`. The pod uses the network namespace of the node, so NCCL sees the RDMA network interfaces of the node.
- `dnsPolicy: ClusterFirstWithHostNet`. Without it, a host network pod uses the DNS settings of the node, and the pod DNS names of the job do not resolve. All of the fixes below depend on those names.
- A `hostPath` mount of `/dev/infiniband`, the RDMA device files that NCCL opens.
- A memory-backed `emptyDir` on `/dev/shm`. NCCL uses shared memory between the processes on one node, and the default `/dev/shm` of a container is 64 MiB.
- `privileged: true` with the `IPC_LOCK` and `SYS_ADMIN` capabilities. `IPC_LOCK` lets NCCL lock the memory that it registers with the NICs.

The training script goes into a ConfigMap, and every job mounts it on `/scripts`:

```bash
kubectl create configmap ddp-script --from-file=train.py
```

{{< code language="python" title="train.py" open="false" >}}
import os
import socket
import time

import torch
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP


def log(msg):
    if dist.get_rank() == 0:
        print(msg, flush=True)


def allreduce_bandwidth(device, size_bytes=8 << 30, iters=20):
    world = dist.get_world_size()
    buf = torch.ones(size_bytes // 4, dtype=torch.float32, device=device)
    for _ in range(5):
        dist.all_reduce(buf)
    torch.cuda.synchronize()
    start = time.perf_counter()
    for _ in range(iters):
        dist.all_reduce(buf)
    torch.cuda.synchronize()
    seconds = (time.perf_counter() - start) / iters
    # Same bus bandwidth formula as nccl-tests.
    busbw = size_bytes / seconds / 1e9 * 2 * (world - 1) / world
    log(f"all_reduce {size_bytes >> 30} GiB: {seconds * 1e3:.1f} ms, busbw {busbw:.1f} GB/s")
    del buf


def train(device, local_rank, steps):
    model = torch.nn.Sequential(
        torch.nn.Linear(4096, 4096),
        torch.nn.ReLU(),
        torch.nn.Linear(4096, 10),
    ).to(device)
    ddp = DDP(model, device_ids=[local_rank])
    optimizer = torch.optim.SGD(ddp.parameters(), lr=0.01)
    loss_fn = torch.nn.CrossEntropyLoss()
    for step in range(1, steps + 1):
        x = torch.randn(256, 4096, device=device)
        y = torch.randint(0, 10, (256,), device=device)
        optimizer.zero_grad()
        loss = loss_fn(ddp(x), y)
        loss.backward()
        optimizer.step()
        if step % 50 == 0:
            log(f"step {step}/{steps} loss {loss.item():.4f}")


def main():
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    device = torch.device("cuda", local_rank)
    dist.init_process_group(backend="nccl", device_id=device)

    if local_rank == 0:
        print(f"host {socket.gethostname()} global rank {dist.get_rank()}", flush=True)
    log(f"world size {dist.get_world_size()}")

    allreduce_bandwidth(device)
    train(device, local_rank, int(os.environ.get("STEPS", "200")))

    dist.barrier()
    log("training finished")
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
{{< /code >}}

The script runs 5 warm-up `all_reduce` calls on an 8 GiB float32 buffer, then times 20 more between two `torch.cuda.synchronize()` calls. Bus bandwidth is the buffer size divided by the time per call, times 2(n−1)/n. For 16 ranks that factor is 1.875. It is the same formula that nccl-tests uses for [`all_reduce`](https://github.com/NVIDIA/nccl-tests/blob/master/doc/PERFORMANCE.md), so the numbers can be compared directly.

## Two decisions based on a host name

torchrun's `c10d` rendezvous needs one process to host a TCP store. Every node gets the same `--rdzv-endpoint`, and each node must decide on its own if it is the host.

If you do not tell it, torchrun calls [`_matches_machine_hostname()`](https://github.com/pytorch/pytorch/blob/v2.14.1/torch/distributed/elastic/rendezvous/utils.py#L117-L166) from the [`c10d` backend](https://github.com/pytorch/pytorch/blob/v2.14.1/torch/distributed/elastic/rendezvous/c10d_rendezvous_backend.py#L137-L145). That function compares the endpoint with `socket.gethostname()`, and then compares the IP addresses of the endpoint with the IP addresses that the local host name resolves to.

In a host network pod, `socket.gethostname()` returns the name of the node. I checked the names from a host network pod on each node:

{{< code language="yaml" title="dnscheck.yaml" open="false" >}}
apiVersion: v1
kind: Pod
metadata: { name: dnscheck }
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  nodeSelector: { kubernetes.io/hostname: "<node>" }
  tolerations: [{ key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }]
  containers:
  - { name: c, image: nvcr.io/nvidia/pytorch:26.09-py3, command: ["sleep", "600"], resources: { requests: { cpu: 10m, memory: 16Mi } } }
{{< /code >}}

```bash
kubectl exec dnscheck -- python3 -c '
import socket
h = socket.gethostname()
print("gethostname():", h)
print("getfqdn():", socket.getfqdn())
try:
    ai = socket.getaddrinfo(h, None, proto=socket.IPPROTO_TCP, flags=socket.AI_CANONNAME)
    print("getaddrinfo(gethostname()):", sorted({a[4][0] for a in ai}), "canonname:", ai[0][3])
except Exception as e:
    print("getaddrinfo(gethostname()) ERROR:", repr(e))
'
```

On node 0:

```
gethostname():              oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0
getfqdn():                  oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0
getaddrinfo(gethostname()): ['127.0.1.1']
```

The Ubuntu nodes map their own name to `127.0.1.1` in `/etc/hosts`. The endpoint, `<job>-worker-0.<job>`, resolves to the real IP address of node 0. The names do not match and the IP addresses do not match, so no node decides to host the store.

The second decision is the address that each node advertises to the others. Without `--local-addr`, torchrun uses [`socket.getfqdn()`](https://github.com/pytorch/pytorch/blob/v2.14.1/torch/distributed/elastic/rendezvous/dynamic_rendezvous.py#L269). On these nodes that is the short node name, and the address of rank 0 becomes `MASTER_ADDR` for everybody. From the pod on node 1, the name of node 0 does not resolve:

```bash
kubectl exec dnscheck -- python3 -c '
import socket
for name in ["oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0", "oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-1"]:
    try:
        print(name, "->", sorted({a[4][0] for a in socket.getaddrinfo(name, None, proto=socket.IPPROTO_TCP)}))
    except Exception as e:
        print(name, "-> ERROR", repr(e))
'
```

```
oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0 -> ERROR gaierror(-2, 'Name or service not known')
oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-1 -> ['127.0.1.1']
```

Both failures come from name resolution on these nodes, not from the host network itself. If the node name resolves to the real IP address of the node, the IP comparison finds the host. If the other nodes can resolve that name, the default advertised address works too. That is why some clusters never see this problem.

## Breaking it on purpose

I took the working Volcano job from [the fix below](#volcano) and removed one line at a time. Everything else stayed the same, including the NCCL settings and the 16 NICs.

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

At least this error points at the rendezvous.

Without `--local-addr`, the rendezvous succeeds, because `is_host` is set. Node 0 starts NCCL and waits. The 8 processes on node 1 try to reach the store at the advertised address, which is the node name of node 0:

```
[c10d] TCP client failed to connect/validate to host oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0:43045 - retrying (try=0, timeout=600000ms, delay=71479ms)
[c10d] The IPv6 network addresses of (oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0, 43045) cannot be retrieved (gai error: -2 - Name or service not known).
```

The client timeout is 600 seconds, and the client retries after it. The job did not fail in the 10 minutes I gave it. Node 0 already printed NCCL setup lines, so it is easy to blame NCCL or the RDMA network.

I removed the same flags from the Training Operator v1 job, and torchrun behaved the same way. Without `is_host`, both pods timed out on the rendezvous store and restarted after about 2 minutes. Without `--local-addr`, the job was still stuck after 10 minutes, with the same `gai error: -2` for the node name of node 0.

One detail surprised me. In the Training Operator run, the pod that hung was the pod with `is_host=true`. torchrun gave ranks 0 to 7 to the other pod, so the pod that hosted the rendezvous store could not reach rank 0. `is_host` decides where the rendezvous store runs. It does not decide which node gets rank 0.

## The issues

Two PyTorch issues describe exactly this, and both are still open:

- [pytorch/pytorch#73380](https://github.com/pytorch/pytorch/issues/73380), opened in February 2022. A 2-node job on Kubernetes with Volcano times out, because the rank 0 host does not realize that it is the master.
- [pytorch/pytorch#73656](https://github.com/pytorch/pytorch/issues/73656), opened in March 2022. The same two problems on a Slurm cluster, where the nodes must use different names to talk across InfiniBand cells. It has 28 comments, and they converge on the same two settings, `is_host` and `local_addr`. One commenter runs a wrapper launcher that adds both settings automatically.

The code in this area is the same in PyTorch v2.14.1, the latest release, and on `main`.

There is also a version trap. [#125743](https://github.com/pytorch/pytorch/pull/125743) added an option to share the rendezvous TCP store and shipped in PyTorch 2.4.0. It also made torchrun ignore `local_addr`. [#135262](https://github.com/pytorch/pytorch/pull/135262) fixed that in 2.5.0. On 2.4.x, `--local-addr` does nothing, so use 2.5 or later.

## The fix for Volcano and Training Operator v1

Tell torchrun who the host is, and give it an address that the other nodes can resolve. Both launchers create a headless Service, so each pod already has a DNS name that resolves to the IP address of its node.

### Volcano

```bash
helm install volcano volcano --repo https://volcano-sh.github.io/helm-charts --version 1.16.0 \
  --namespace volcano-system --create-namespace --wait
```

The `svc` plugin creates the headless Service and sets `VC_WORKER_HOSTS` (the DNS names of the worker pods) and `VC_WORKER_NUM`. Its `--publish-not-ready-addresses=true` flag publishes the DNS records before the pods are Ready, so the names resolve while torchrun starts. The `env` plugin sets `VC_TASK_INDEX`. The rendezvous ID comes from the PodGroup name, so every job gets its own.

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

{{< code language="yaml" title="volcano-c10d.yaml" open="false" >}}
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: ddp-volcano-c10d
spec:
  minAvailable: 2
  schedulerName: volcano
  queue: default
  plugins:
    env: []
    svc: ["--publish-not-ready-addresses=true"]
  tasks:
  - name: worker
    replicas: 2
    template:
      spec:
        hostNetwork: true
        dnsPolicy: ClusterFirstWithHostNet
        restartPolicy: OnFailure
        nodeSelector:
          node.kubernetes.io/instance-type: BM.GPU4.8
        volumes:
        - { name: devinf, hostPath: { path: /dev/infiniband }}
        - { name: shm, emptyDir: { medium: Memory, sizeLimit: 32Gi }}
        - { name: ddp-script, configMap: { name: ddp-script }}
        containers:
        - name: worker
          image: nvcr.io/nvidia/pytorch:26.09-py3
          command: ["/bin/bash", "-c"]
          args:
          - |
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
          ports:
          - { containerPort: 23456, name: c10d, protocol: TCP }
          env:
          - name: JOB_ID
            valueFrom:
              fieldRef:
                fieldPath: metadata.annotations['scheduling.k8s.io/group-name']
          - { name: NCCL_DEBUG, value: INFO }
          - { name: NCCL_DEBUG_SUBSYS, value: "INIT,NET" }
          - { name: NCCL_IB_SPLIT_DATA_ON_QPS, value: "0" }
          - { name: NCCL_IB_QPS_PER_CONNECTION, value: "4" }
          - { name: NCCL_IB_GID_INDEX, value: "3" }
          - { name: NCCL_IB_HCA, value: "=mlx5_0,mlx5_2,mlx5_6,mlx5_8,mlx5_10,mlx5_12,mlx5_14,mlx5_16,mlx5_1,mlx5_3,mlx5_7,mlx5_9,mlx5_11,mlx5_13,mlx5_15,mlx5_17" }
          - { name: NCCL_IB_TC, value: "41" }
          - { name: NCCL_IB_SL, value: "0" }
          - { name: NCCL_IB_TIMEOUT, value: "22" }
          resources:
            limits:
              nvidia.com/gpu: 8
          securityContext:
            privileged: true
            capabilities:
              add: ["IPC_LOCK", "SYS_ADMIN"]
          volumeMounts:
          - { mountPath: /dev/infiniband, name: devinf }
          - { mountPath: /dev/shm, name: shm }
          - { mountPath: /scripts, name: ddp-script }
{{< /code >}}

```bash
kubectl apply -f volcano-c10d.yaml
kubectl wait --for=jsonpath='{.status.state.phase}'=Completed vcjob/ddp-volcano-c10d --timeout=10m
kubectl logs ddp-volcano-c10d-worker-0 | grep -E '^(host|world size|all_reduce|step|training finished)'
```

### Training Operator v1

```bash
kubectl apply --server-side --force-conflicts -k "github.com/kubeflow/training-operator.git/manifests/overlays/standalone?ref=v1.9.4"
```

With `elasticPolicy`, Training Operator sets `PET_RDZV_BACKEND`, `PET_RDZV_ENDPOINT` (pointing at `<job>-worker-0`) and `PET_NNODES` as `min:max` for torchrun ([`elastic.go`](https://github.com/kubeflow/trainer/blob/v1.9.4/pkg/controller.v1/pytorch/elastic.go)). It does not set `is_host` or the local address. Those come from the pod itself. The replica index comes from a pod label, and the pod name is the DNS name:

```bash
torchrun \
  --local-addr=$POD_NAME \
  --rdzv-conf=is_host=$([ "$REPLICA_INDEX" = 0 ] && echo true || echo false) \
  --nproc-per-node=8 \
  /scripts/train.py
```

`REPLICA_INDEX` comes from the label `training.kubeflow.org/replica-index`, and `POD_NAME` from `metadata.name`.

This only works for a job with `Worker` replicas and no `Master`. Training Operator numbers the replicas of each replica type separately ([`pod.go`](https://github.com/kubeflow/trainer/blob/v1.9.4/pkg/controller.v1/common/pod.go#L297-L321)). In a job with a `Master` and `Worker` replicas, `Master-0` and `Worker-0` both have the index 0, and both would set `is_host=true`. The tested job below has only `Worker` replicas, with `minReplicas` and `maxReplicas` both set to 2.

{{< code language="yaml" title="pytorchjob-c10d.yaml" open="false" >}}
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: ddp-pytorchjob-c10d
spec:
  elasticPolicy:
    rdzvBackend: c10d
    minReplicas: 2
    maxReplicas: 2
    maxRestarts: 3
  pytorchReplicaSpecs:
    Worker:
      replicas: 2
      restartPolicy: OnFailure
      template:
        spec:
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
          nodeSelector:
            node.kubernetes.io/instance-type: BM.GPU4.8
          volumes:
          - { name: devinf, hostPath: { path: /dev/infiniband }}
          - { name: shm, emptyDir: { medium: Memory, sizeLimit: 32Gi }}
          - { name: ddp-script, configMap: { name: ddp-script }}
          containers:
          - name: pytorch
            image: nvcr.io/nvidia/pytorch:26.09-py3
            command: ["/bin/bash", "-c"]
            args:
            - |
              torchrun \
                --local-addr=$POD_NAME \
                --rdzv-conf=is_host=$([ "$REPLICA_INDEX" = 0 ] && echo true || echo false) \
                --nproc-per-node=8 \
                /scripts/train.py
            env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: REPLICA_INDEX
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['training.kubeflow.org/replica-index']
            - { name: NCCL_DEBUG, value: INFO }
            - { name: NCCL_DEBUG_SUBSYS, value: "INIT,NET" }
            - { name: NCCL_IB_SPLIT_DATA_ON_QPS, value: "0" }
            - { name: NCCL_IB_QPS_PER_CONNECTION, value: "4" }
            - { name: NCCL_IB_GID_INDEX, value: "3" }
            - { name: NCCL_IB_HCA, value: "=mlx5_0,mlx5_2,mlx5_6,mlx5_8,mlx5_10,mlx5_12,mlx5_14,mlx5_16,mlx5_1,mlx5_3,mlx5_7,mlx5_9,mlx5_11,mlx5_13,mlx5_15,mlx5_17" }
            - { name: NCCL_IB_TC, value: "41" }
            - { name: NCCL_IB_SL, value: "0" }
            - { name: NCCL_IB_TIMEOUT, value: "22" }
            resources:
              limits:
                nvidia.com/gpu: 8
            securityContext:
              privileged: true
              capabilities:
                add: ["IPC_LOCK", "SYS_ADMIN"]
            volumeMounts:
            - { mountPath: /dev/infiniband, name: devinf }
            - { mountPath: /dev/shm, name: shm }
            - { mountPath: /scripts, name: ddp-script }
{{< /code >}}

```bash
kubectl apply -f pytorchjob-c10d.yaml
kubectl wait --for=condition=Succeeded pytorchjob/ddp-pytorchjob-c10d --timeout=10m
kubectl logs ddp-pytorchjob-c10d-worker-0 | grep -E '^(host|world size|all_reduce|step|training finished)'
```

## The etcd backend

With `--rdzv-backend=etcd-v2`, etcd holds the rendezvous state, so no node has to decide if it hosts a store and `is_host` does not apply. Each node still advertises an address for rank 0, so `--local-addr` is still required. Two more things broke on the way.

- **No etcd client in the NVIDIA image.** The `etcd-v2` backend needs `python-etcd`. Without it, torchrun stops with `EtcdStubError: The 'etcd' module is required but not installed`. The latest release, 0.4.5, is from 2017, and it still works on Python 3.12. Both jobs below install it before torchrun starts.
- **The rendezvous ID with Training Operator v1.** Training Operator does not set a rendezvous ID, so torchrun uses the ID `none` for every job. The first job closes the rendezvous `none` in etcd, and every job after it fails with `RendezvousClosedError`. The PyTorchJob below sets `PET_RDZV_ID` from the job name and uses `generateName`, so each run gets a new ID. Volcano jobs use the PodGroup name, as in the c10d job.

The etcd server needs the v2 API, which etcd 3.5 still has behind `--enable-v2`:

{{< code language="yaml" title="etcd.yaml" open="false" >}}
apiVersion: v1
kind: Pod
metadata:
  name: etcd-server
  labels:
    app: etcd-server
spec:
  containers:
  - name: etcd
    image: quay.io/coreos/etcd:v3.5.34
    command:
    - /usr/local/bin/etcd
    - --name=etcd-server
    - --data-dir=/var/lib/etcd
    - --enable-v2
    - --listen-client-urls=http://0.0.0.0:2379
    - --advertise-client-urls=http://etcd-server-headless:2379
    ports:
    - { containerPort: 2379, name: client, protocol: TCP }
---
apiVersion: v1
kind: Service
metadata:
  name: etcd-server-headless
spec:
  clusterIP: None
  selector:
    app: etcd-server
  ports:
  - { name: client, port: 2379, targetPort: 2379, protocol: TCP }
{{< /code >}}

```bash
kubectl apply -f etcd.yaml
kubectl wait --for=condition=Ready pod/etcd-server
```

{{< code language="yaml" title="volcano-etcd.yaml" open="false" >}}
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: ddp-volcano-etcd
spec:
  minAvailable: 2
  schedulerName: volcano
  queue: default
  plugins:
    env: []
    svc: ["--publish-not-ready-addresses=true"]
  tasks:
  - name: worker
    replicas: 2
    template:
      spec:
        hostNetwork: true
        dnsPolicy: ClusterFirstWithHostNet
        restartPolicy: OnFailure
        nodeSelector:
          node.kubernetes.io/instance-type: BM.GPU4.8
        volumes:
        - { name: devinf, hostPath: { path: /dev/infiniband }}
        - { name: shm, emptyDir: { medium: Memory, sizeLimit: 32Gi }}
        - { name: ddp-script, configMap: { name: ddp-script }}
        containers:
        - name: worker
          image: nvcr.io/nvidia/pytorch:26.09-py3
          command: ["/bin/bash", "-c"]
          args:
          - |
            pip install --quiet python-etcd==0.4.5
            WORKERS=(${VC_WORKER_HOSTS//,/ })
            torchrun \
              --rdzv-id=$JOB_ID \
              --rdzv-backend=etcd-v2 \
              --rdzv-endpoint=etcd-server-headless:2379 \
              --local-addr=${WORKERS[$VC_TASK_INDEX]} \
              --nnodes=$VC_WORKER_NUM \
              --nproc-per-node=8 \
              /scripts/train.py
          env:
          - name: JOB_ID
            valueFrom:
              fieldRef:
                fieldPath: metadata.annotations['scheduling.k8s.io/group-name']
          - { name: NCCL_DEBUG, value: INFO }
          - { name: NCCL_DEBUG_SUBSYS, value: "INIT,NET" }
          - { name: NCCL_IB_SPLIT_DATA_ON_QPS, value: "0" }
          - { name: NCCL_IB_QPS_PER_CONNECTION, value: "4" }
          - { name: NCCL_IB_GID_INDEX, value: "3" }
          - { name: NCCL_IB_HCA, value: "=mlx5_0,mlx5_2,mlx5_6,mlx5_8,mlx5_10,mlx5_12,mlx5_14,mlx5_16,mlx5_1,mlx5_3,mlx5_7,mlx5_9,mlx5_11,mlx5_13,mlx5_15,mlx5_17" }
          - { name: NCCL_IB_TC, value: "41" }
          - { name: NCCL_IB_SL, value: "0" }
          - { name: NCCL_IB_TIMEOUT, value: "22" }
          resources:
            limits:
              nvidia.com/gpu: 8
          securityContext:
            privileged: true
            capabilities:
              add: ["IPC_LOCK", "SYS_ADMIN"]
          volumeMounts:
          - { mountPath: /dev/infiniband, name: devinf }
          - { mountPath: /dev/shm, name: shm }
          - { mountPath: /scripts, name: ddp-script }
{{< /code >}}

```bash
kubectl apply -f volcano-etcd.yaml
kubectl wait --for=jsonpath='{.status.state.phase}'=Completed vcjob/ddp-volcano-etcd --timeout=10m
kubectl logs ddp-volcano-etcd-worker-0 | grep -E '^(host|world size|all_reduce|step|training finished)'
```

{{< code language="yaml" title="pytorchjob-etcd.yaml" open="false" >}}
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  generateName: ddp-pytorchjob-etcd-
spec:
  elasticPolicy:
    rdzvBackend: etcd-v2
    rdzvHost: etcd-server-headless
    rdzvPort: 2379
    minReplicas: 2
    maxReplicas: 2
    maxRestarts: 3
  pytorchReplicaSpecs:
    Worker:
      replicas: 2
      restartPolicy: OnFailure
      template:
        spec:
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
          nodeSelector:
            node.kubernetes.io/instance-type: BM.GPU4.8
          volumes:
          - { name: devinf, hostPath: { path: /dev/infiniband }}
          - { name: shm, emptyDir: { medium: Memory, sizeLimit: 32Gi }}
          - { name: ddp-script, configMap: { name: ddp-script }}
          containers:
          - name: pytorch
            image: nvcr.io/nvidia/pytorch:26.09-py3
            command: ["/bin/bash", "-c"]
            args:
            - |
              pip install --quiet python-etcd==0.4.5
              torchrun \
                --local-addr=$POD_NAME \
                --nproc-per-node=8 \
                /scripts/train.py
            env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: PET_RDZV_ID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['training.kubeflow.org/job-name']
            - { name: NCCL_DEBUG, value: INFO }
            - { name: NCCL_DEBUG_SUBSYS, value: "INIT,NET" }
            - { name: NCCL_IB_SPLIT_DATA_ON_QPS, value: "0" }
            - { name: NCCL_IB_QPS_PER_CONNECTION, value: "4" }
            - { name: NCCL_IB_GID_INDEX, value: "3" }
            - { name: NCCL_IB_HCA, value: "=mlx5_0,mlx5_2,mlx5_6,mlx5_8,mlx5_10,mlx5_12,mlx5_14,mlx5_16,mlx5_1,mlx5_3,mlx5_7,mlx5_9,mlx5_11,mlx5_13,mlx5_15,mlx5_17" }
            - { name: NCCL_IB_TC, value: "41" }
            - { name: NCCL_IB_SL, value: "0" }
            - { name: NCCL_IB_TIMEOUT, value: "22" }
            resources:
              limits:
                nvidia.com/gpu: 8
            securityContext:
              privileged: true
              capabilities:
                add: ["IPC_LOCK", "SYS_ADMIN"]
            volumeMounts:
            - { mountPath: /dev/infiniband, name: devinf }
            - { mountPath: /dev/shm, name: shm }
            - { mountPath: /scripts, name: ddp-script }
{{< /code >}}

The job uses `generateName`, so it needs `kubectl create` instead of `kubectl apply`, and the job name is in the output:

```bash
kubectl create -f pytorchjob-etcd.yaml
kubectl wait --for=condition=Succeeded pytorchjob/<job-name> --timeout=10m
kubectl logs <job-name>-worker-0 | grep -E '^(host|world size|all_reduce|step|training finished)'
```

## Trainer v2 does not ask the question

Kubeflow Trainer v2.3.0 sets five torchrun variables, `PET_NNODES`, `PET_NPROC_PER_NODE`, `PET_NODE_RANK`, `PET_MASTER_ADDR` and `PET_MASTER_PORT` ([`constants.go`](https://github.com/kubeflow/trainer/blob/v2.3.0/pkg/constants/constants.go#L191-L203)). It does not set a rendezvous backend, so torchrun keeps its default, [`static`](https://github.com/pytorch/pytorch/blob/v2.14.1/torch/distributed/run.py#L519-L523). With `static`, the store endpoint is [`MASTER_ADDR:MASTER_PORT`](https://github.com/pytorch/pytorch/blob/v2.14.1/torch/distributed/run.py#L899-L900), and the store host is simply [node rank 0](https://github.com/pytorch/pytorch/blob/v2.14.1/torch/distributed/elastic/rendezvous/static_tcp_rendezvous.py#L65). Nobody compares host names. `PET_MASTER_ADDR` is a DNS name of the first pod, for example `ddp-rdma-node-0-0.ddp-rdma`, and with `ClusterFirstWithHostNet` it resolves to the IP address of node 0. It worked with no extra flags.

It has its own catches:

- The `TrainJob` API has no field for `hostNetwork` or `dnsPolicy`. They go in a `ClusterTrainingRuntime`.
- The container in the runtime must have the name `node`. Patches in a `TrainJob` must use that name too.
- Trainer v2 adds container port 29500 to every pod. With the host network, Kubernetes turns it into a host port, so only one `TrainJob` pod fits on a node.

```bash
helm install kubeflow-trainer oci://ghcr.io/kubeflow/charts/kubeflow-trainer \
  --namespace kubeflow-system --create-namespace --version 2.3.0 --wait
```

{{< code language="yaml" title="trainer-v2-runtime.yaml" open="false" >}}
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
                nodeSelector:
                  node.kubernetes.io/instance-type: BM.GPU4.8
                volumes:
                - { name: devinf, hostPath: { path: /dev/infiniband }}
                - { name: shm, emptyDir: { medium: Memory, sizeLimit: 32Gi }}
                containers:
                - name: node
                  image: nvcr.io/nvidia/pytorch:26.09-py3
                  env:
                  - { name: NCCL_DEBUG, value: INFO }
                  - { name: NCCL_DEBUG_SUBSYS, value: "INIT,NET" }
                  - { name: NCCL_IB_SPLIT_DATA_ON_QPS, value: "0" }
                  - { name: NCCL_IB_QPS_PER_CONNECTION, value: "4" }
                  - { name: NCCL_IB_GID_INDEX, value: "3" }
                  - { name: NCCL_IB_HCA, value: "=mlx5_0,mlx5_2,mlx5_6,mlx5_8,mlx5_10,mlx5_12,mlx5_14,mlx5_16,mlx5_1,mlx5_3,mlx5_7,mlx5_9,mlx5_11,mlx5_13,mlx5_15,mlx5_17" }
                  - { name: NCCL_IB_TC, value: "41" }
                  - { name: NCCL_IB_SL, value: "0" }
                  - { name: NCCL_IB_TIMEOUT, value: "22" }
                  securityContext:
                    privileged: true
                    capabilities:
                      add: ["IPC_LOCK", "SYS_ADMIN"]
                  volumeMounts:
                  - { mountPath: /dev/infiniband, name: devinf }
                  - { mountPath: /dev/shm, name: shm }
{{< /code >}}

{{< code language="yaml" title="trainer-v2-trainjob.yaml" open="false" >}}
apiVersion: trainer.kubeflow.org/v1alpha1
kind: TrainJob
metadata:
  name: ddp-rdma
spec:
  runtimeRef:
    name: torch-distributed-rdma
  trainer:
    numNodes: 2
    resourcesPerNode:
      limits:
        nvidia.com/gpu: 8
    command: ["torchrun", "/scripts/train.py"]
  runtimePatches:
  - manager: example.com/ddp-rdma
    trainingRuntimeSpec:
      template:
        spec:
          replicatedJobs:
          - name: node
            template:
              spec:
                template:
                  spec:
                    volumes:
                    - { name: ddp-script, configMap: { name: ddp-script }}
                    containers:
                    - name: node
                      volumeMounts:
                      - { mountPath: /scripts, name: ddp-script }
{{< /code >}}

```bash
kubectl apply -f trainer-v2-runtime.yaml
kubectl apply -f trainer-v2-trainjob.yaml
kubectl wait --for=condition=Complete trainjob/ddp-rdma --timeout=20m
kubectl logs -l jobset.sigs.k8s.io/jobset-name=ddp-rdma,batch.kubernetes.io/job-completion-index=0 --tail=-1 \
  | grep -E '^(host|world size|all_reduce|step|training finished)'
```

## One more thing that bit me

Training Operator v1 brings its own `MPIJob` CRD (`kubeflow.org/v1`), which conflicts with the stand-alone MPI Operator (`v2beta1`). If Kueue was running while the MPI Operator was installed, Kueue keeps logging `Failed to watch *v2beta1.MPIJob` after you remove it.

## How it ended

Once the rendezvous was right, every launcher reached the same bandwidth:

| Launcher | Bus bandwidth, `all_reduce`, 8 GiB |
| --- | --- |
| Kubeflow Trainer v2 | 191.0 GB/s |
| Volcano, c10d | 191.0 GB/s |
| Volcano, etcd | 191.0 GB/s |
| Training Operator v1, c10d | 191.0 GB/s |
| Training Operator v1, etcd | 191.0 GB/s |

For reference, `all_reduce_perf` from nccl-tests on the same nodes reported 182.84 GB/s out-of-place and 190.17 GB/s in-place at 8 GiB.

In every run, NCCL selected all 16 RDMA NICs in its `NET/IB` device list, used IB with GPUDirect RDMA channels, and never fell back to `NET/Socket`. I checked that with these lines on every pod:

```bash
kubectl logs <pod> | grep -m1 'NCCL INFO Using network'
kubectl logs <pod> | grep -m1 'NET/IB : Using \[0\]'
kubectl logs <pod> | grep -c 'via NET/IB/.*/GDRDMA'
```

The first must say `Using network IB`. The second lists the devices, and it must have 16 `/RoCE` entries and no `mlx5_4` or `mlx5_5`, the front-end ports. The third counts the GPUDirect RDMA channels and must be more than 0. I did not read the per-NIC traffic counters for these runs, so this shows that NCCL selected all 16 NICs, not how evenly it spread the traffic.

## Before you blame NCCL

- On the host network, do not let torchrun guess. Set `is_host` and `--local-addr` yourself, or use a launcher that keeps torchrun's default `static` rendezvous and sets the master address and node rank.
- Use PyTorch 2.5 or later. On 2.4.x, `--local-addr` is ignored.
- `dnsPolicy: ClusterFirstWithHostNet` is not optional. All of the fixes above depend on pod DNS names.
- A hang on node two is not always NCCL. Check the rendezvous address first.
- Check the NCCL log for `Using network IB` and GDRDMA. The job status does not tell you which transport NCCL used.
