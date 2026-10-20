+++
title = "Running PyTorch Jobs on OKE Using Host Network with RDMA"
date = "2026-10-20"
draft = true
tags = ["oke", "rdma", "pytorch", "nccl", "kubeflow", "kueue", "volcano"]
description = "Multi-node PyTorch on OKE over RDMA with Kubeflow Trainer v2, Kueue, Volcano and Training Operator v1, tested on 2 x BM.GPU4.8."
Toc = true
+++

This guide shows how to run multi-node PyTorch training jobs over RDMA on Oracle Kubernetes Engine (OKE). The pods use the host network, so NCCL can use the RDMA network interfaces of the node directly.

The guide runs the same job in four ways:

- Kubeflow Trainer v2 (`TrainJob`)
- Kubeflow Trainer v2 with Kueue topology-aware scheduling
- Volcano
- Kubeflow Training Operator v1 (`PyTorchJob`)

Every example runs one small PyTorch DDP script on all GPUs of two nodes. The script also measures `all_reduce` bandwidth, so you can confirm that NCCL uses RDMA.


This post is an updated version of the [guide in the oci-hpc-oke repository](https://github.com/oracle-quickstart/oci-hpc-oke/blob/main/docs/running-pytorch-jobs-on-oke-using-hostnetwork-with-rdma.md). The earlier version had Volcano and Training Operator v1 examples that trained YOLOv5 on 1 GPU per node. These are the changes:

- New sections for Kubeflow Trainer v2 and for Kueue topology-aware scheduling.
- All examples use all 8 GPUs of each node and one self-contained DDP script.
- The NCCL settings are for BM.GPU4.8. The earlier version had the values for BM.GPU.B4.8.
- The NVIDIA PyTorch image includes the RDMA libraries, so the pods do not install them at start.
- The Volcano jobs use gang scheduling (`minAvailable: 2`).
- The `PyTorchJob` examples use the same value for `minReplicas` and `maxReplicas`.
- The etcd `PyTorchJob` gets a new rendezvous ID for each run. In the earlier version, every etcd job after the first one failed with `RendezvousClosedError`.
- The etcd examples install `python-etcd`, which the `etcd-v2` backend needs.
- New sections for RDMA verification and troubleshooting.
## Tested Versions

All steps in this guide were tested with these versions.

| Component | Version |
| --- | --- |
| Cluster | OKE v1.36.4, deployed with the [oci-hpc-oke](https://github.com/oracle-quickstart/oci-hpc-oke) stack |
| GPU nodes | 2 x BM.GPU4.8 in one HPC island |
| Node image | `Canonical-Ubuntu-24.04-2026.02.28-0-KERNEL-ORACLE-6.8-DOCA-OFED-3.3.0-GPU-595-OPEN-CUDA-13.2-2026.07.16-0` |
| Container image | `nvcr.io/nvidia/pytorch:26.09-py3` (PyTorch 2.14.0a0, NCCL 2.31.2, CUDA 13.4.1) |
| Kubeflow Trainer | v2.3.0, with JobSet v0.12.0 |
| Kueue | 0.20.0, installed by the stack |
| Volcano | v1.16.0 |
| Kubeflow Training Operator | v1.9.4 |
| etcd | v3.5.34 |

## Prerequisites

- An OKE cluster with RDMA-enabled GPU nodes, deployed with the [oci-hpc-oke](https://github.com/oracle-quickstart/oci-hpc-oke) stack
- `kubectl` and `helm` with access to the cluster
- Basic knowledge of PyTorch distributed training with `torchrun`

## Required Pod Settings for RDMA

Every pod in this guide uses the settings below. Add them to your own PyTorch job manifests.

```yaml
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  volumes:
  - { name: devinf, hostPath: { path: /dev/infiniband }}
  - { name: shm, emptyDir: { medium: Memory, sizeLimit: 32Gi }}
  containers:
  - name: trainer
    securityContext:
      privileged: true
      capabilities:
        add: ["IPC_LOCK", "SYS_ADMIN"]
    volumeMounts:
    - { mountPath: /dev/infiniband, name: devinf }
    - { mountPath: /dev/shm, name: shm }
```

| Setting | Purpose |
| --- | --- |
| `hostNetwork: true` | The pod uses the network namespace of the node, so NCCL can use the RDMA interfaces. |
| `dnsPolicy: ClusterFirstWithHostNet` | Cluster DNS names resolve in the pod. Without this setting, a host network pod uses the DNS settings of the node, and the rendezvous host names do not resolve. |
| `/dev/infiniband` mount | Gives the pod access to the RDMA devices. |
| Memory-backed `/dev/shm` | Gives NCCL enough shared memory for traffic between the GPUs of one node. |
| `IPC_LOCK` capability | Lets NCCL pin memory for RDMA operations. |
| `SYS_ADMIN` capability | Lets the training framework do additional system-level operations. |

The GPU nodes have the taint `nvidia.com/gpu=present:NoSchedule`. The cluster adds a matching toleration to every pod that requests `nvidia.com/gpu`, so the examples do not set one.

> **Important**
>
> The container image must include the RDMA user space libraries (`rdma-core`). Without them, NCCL falls back to TCP sockets. The NVIDIA PyTorch image (`nvcr.io/nvidia/pytorch`) includes them.

### NCCL Settings

The examples set the NCCL parameters for BM.GPU4.8 as environment variables. For other shapes, use the values in [Recommended NCCL/RCCL Parameters by Shape](https://github.com/oracle-quickstart/oci-hpc-oke/blob/main/docs/recommended-nccl-rccl-parameters-by-shape.md). The stack also creates a ConfigMap with these values for each GPU shape. To load the values from the ConfigMap, see [Using the NCCL/RCCL Parameters ConfigMap in Job Manifests](https://github.com/oracle-quickstart/oci-hpc-oke/blob/main/docs/using-nccl-rccl-parameters-configmap.md).

> **Important**
>
> `NCCL_IB_HCA` is different for each shape. A list for another shape can include the front-end network interface and leave out RDMA interfaces. For example, on BM.GPU4.8, `mlx5_4` is the front-end interface (`eth0`).

The examples set `NCCL_DEBUG=INFO` and `NCCL_DEBUG_SUBSYS=INIT,NET`, so the logs show which network NCCL uses. For production jobs, set `NCCL_DEBUG=WARN`.

## Creating the Training Script

Save this script as `train.py`.

```python
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
```

Store the script in a ConfigMap. All examples mount this ConfigMap at `/scripts`.

```bash
kubectl create configmap ddp-script --from-file=train.py
```

The script does two things:

1. It runs `all_reduce` on an 8 GiB buffer 20 times and prints the bus bandwidth. It uses the same formula as nccl-tests.
2. It trains a small model with DDP on random data for 200 steps. The labels are random, so the loss stays near 2.3. The training only shows that DDP gradient synchronization works across the nodes.

Only global rank 0 prints the results.

## Kubeflow Trainer v2

Kubeflow Trainer v2 is the successor of Kubeflow Training Operator v1. A `TrainJob` refers to a training runtime, and the runtime contains the pod template. Trainer v2 creates a JobSet for each `TrainJob`.

### Step 1: Install Kubeflow Trainer

```bash
helm install kubeflow-trainer oci://ghcr.io/kubeflow/charts/kubeflow-trainer \
  --namespace kubeflow-system --create-namespace --version 2.3.0 --wait
```

The chart also installs JobSet v0.12.0. The JobSet controller can restart one time at first start, while its webhook certificate is created. This is expected.

### Step 2: Create a Training Runtime with Host Network

Save this manifest as `trainer-v2-runtime.yaml`.

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
```

```bash
kubectl apply -f trainer-v2-runtime.yaml
```

Important points about the runtime:

- The `TrainJob` API has no fields for `hostNetwork` and `dnsPolicy`. Set them in the runtime.
- The container must have the name `node`. Trainer v2 adds the `torchrun` settings (`PET_*` environment variables) to this container. Patches in a `TrainJob` must also use this name.
- Trainer v2 adds container port 29500 to each pod. With host network, Kubernetes also makes it a host port. Thus, only one `TrainJob` pod can run on a node at a time.

### Step 3: Run the TrainJob

Save this manifest as `trainer-v2-trainjob.yaml`.

```yaml
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
```

```bash
kubectl apply -f trainer-v2-trainjob.yaml
kubectl get trainjob ddp-rdma
```

Important points about the `TrainJob`:

- `numNodes: 2` runs one pod on each of two nodes.
- `resourcesPerNode` requests 8 GPUs. Trainer v2 sets `PET_NPROC_PER_NODE=auto`, so `torchrun` starts one process for each GPU.
- `runtimePatches` mounts the script ConfigMap into the `node` container.
- Trainer v2 sets `PET_MASTER_ADDR` to `ddp-rdma-node-0-0.ddp-rdma`. This name resolves to the IP address of the first node, because the pod uses `ClusterFirstWithHostNet`.

To see the output of global rank 0, run this command:

```bash
kubectl logs -l jobset.sigs.k8s.io/jobset-name=ddp-rdma,batch.kubernetes.io/job-completion-index=0 --tail=-1 \
  | grep -E '^(host|world size|all_reduce|step|training finished)'
```

Example output:

```
host oke-cqx3svxeuna-n4jwf6x4kna-su36xbonoma-0 global rank 0
world size 16
all_reduce 8 GiB: 84.3 ms, busbw 191.1 GB/s
step 50/200 loss 2.3007
step 100/200 loss 2.3449
step 150/200 loss 2.3165
step 200/200 loss 2.3307
training finished
```

To delete the job, run `kubectl delete trainjob ddp-rdma`.

### Step 4 (Optional): Use Kueue Topology-Aware Scheduling

The stack installs Kueue. It also creates a topology-aware LocalQueue for each RDMA GPU shape. The queue name is the shape in lowercase with dots replaced by dashes, plus `-rdma-topology-aware`. For BM.GPU4.8, the name is `bm-gpu4-8-rdma-topology-aware`. For more information, see [Using RDMA Network Locality When Running Workloads on OKE](https://github.com/oracle-quickstart/oci-hpc-oke/blob/main/docs/using-rdma-network-locality-when-running-workloads-on-oke.md).

Save this manifest as `trainer-v2-trainjob-kueue.yaml`.

```yaml
apiVersion: trainer.kubeflow.org/v1alpha1
kind: TrainJob
metadata:
  name: ddp-rdma-kueue
  labels:
    kueue.x-k8s.io/queue-name: bm-gpu4-8-rdma-topology-aware
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
                  metadata:
                    annotations:
                      kueue.x-k8s.io/podset-required-topology: oci.oraclecloud.com/rdma.hpc_island_id
                  spec:
                    volumes:
                    - { name: ddp-script, configMap: { name: ddp-script }}
                    containers:
                    - name: node
                      volumeMounts:
                      - { mountPath: /scripts, name: ddp-script }
```

This manifest has two changes from the previous `TrainJob`:

- The `kueue.x-k8s.io/queue-name` label sends the job to the topology-aware queue.
- The `kueue.x-k8s.io/podset-required-topology` annotation puts all pods in one HPC island. If the job does not fit in one island, it waits. To let Kueue use a larger domain when the job does not fit, use `kueue.x-k8s.io/podset-preferred-topology`.

```bash
kubectl apply -f trainer-v2-trainjob-kueue.yaml
kubectl get workloads
```

Kueue admits the job, and then Trainer v2 starts the pods. Example output:

```
NAME                            QUEUE                           RESERVED IN                     ADMITTED   FINISHED   AGE
trainjob-ddp-rdma-kueue-7163a   bm-gpu4-8-rdma-topology-aware   bm-gpu4-8-rdma-topology-aware   True                  11s
```

If you install Trainer v2 after Kueue, you do not need to restart Kueue. Kueue starts its `TrainJob` integration when the `TrainJob` CRD becomes available.

## Volcano

Volcano is a batch scheduler for Kubernetes. It starts the pods of a job together (gang scheduling).

> **Note**
>
> Do not use the [Volcano PyTorch plugin](https://github.com/volcano-sh/volcano/blob/master/docs/user-guide/how_to_use_pytorch_plugin.md). It uses the legacy master and worker design, not `torchrun`.

### Step 1: Install Volcano

```bash
helm install volcano volcano --repo https://volcano-sh.github.io/helm-charts --version 1.16.0 \
  --namespace volcano-system --create-namespace --wait
```

> **Note**
>
> The Kueue LocalQueue CRD also uses the short names `queue` and `queues`. When both Kueue and Volcano are installed, `kubectl get queues` shows the Kueue LocalQueues. To see the Volcano queues, run `kubectl get queues.scheduling.volcano.sh`.

### Using c10d as the Rendezvous Backend

The `c10d` backend is the native rendezvous of PyTorch. The first pod runs the rendezvous store.

Save this manifest as `volcano-c10d.yaml`.

```yaml
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
```

```bash
kubectl apply -f volcano-c10d.yaml
kubectl get vcjob ddp-volcano-c10d
kubectl logs ddp-volcano-c10d-worker-0 | grep -E '^(host|world size|all_reduce|step|training finished)'
```

The Volcano plugins set these values:

- The `env` plugin sets `VC_TASK_INDEX`, the index of the pod in the task. The first pod has index 0.
- The `svc` plugin sets `VC_WORKER_HOSTS` and `VC_WORKER_NUM`. It also creates a headless Service, so each pod gets a DNS name such as `ddp-volcano-c10d-worker-0.ddp-volcano-c10d`.
- `minAvailable: 2` turns on gang scheduling. Volcano starts the pods only when both pods fit.

The `torchrun` parameters:

| Parameter | Value |
| --- | --- |
| `--rdzv-id` | `JOB_ID`, from the PodGroup name annotation. The name is unique for each job, so each run gets its own rendezvous. |
| `--rdzv-backend` | `c10d` |
| `--rdzv-endpoint` | The DNS name of the first pod in `VC_WORKER_HOSTS`, port 23456 |
| `--rdzv-conf` | `is_host=true` for the first pod and `is_host=false` for the others. With host network, the host name of the pod is the host name of the node, so `torchrun` cannot find the store host by itself. |
| `--local-addr` | The DNS name of the pod. Without it, `torchrun` uses the host name of the node, which other pods cannot resolve. |
| `--nnodes` | `VC_WORKER_NUM`, the number of pods |
| `--nproc-per-node` | 8, one process for each GPU |

### Using etcd as the Rendezvous Backend

The `etcd-v2` backend keeps the rendezvous state in an etcd server.

Save this manifest as `etcd.yaml`. It creates the etcd server and a headless Service.

```yaml
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
```

```bash
kubectl apply -f etcd.yaml
kubectl wait --for=condition=Ready pod/etcd-server
```

The `etcd-v2` backend uses the etcd v2 API. The `--enable-v2` flag turns on this API, so the example uses etcd 3.5. The etcd server has no persistent volume. When you delete the pod, the rendezvous data is also deleted.

Save this manifest as `volcano-etcd.yaml`.

```yaml
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
```

```bash
kubectl apply -f volcano-etcd.yaml
kubectl get vcjob ddp-volcano-etcd
kubectl logs ddp-volcano-etcd-worker-0 | grep -E '^(host|world size|all_reduce|step|training finished)'
```

This manifest has these changes from the `c10d` example:

- It installs `python-etcd` before it starts `torchrun`. The `etcd-v2` backend needs this client, and the NVIDIA PyTorch image does not include it. Without it, `torchrun` fails with `EtcdStubError: The 'etcd' module is required but not installed`.
- `--rdzv-backend=etcd-v2` and `--rdzv-endpoint=etcd-server-headless:2379` use the etcd server.
- It does not set `--rdzv-conf`, because etcd stores the rendezvous state.

## Kubeflow Training Operator v1

Kubeflow Training Operator v1 runs PyTorch jobs with the `PyTorchJob` resource. For new workloads, use [Kubeflow Trainer v2](#kubeflow-trainer-v2).

> **Important**
>
> Training Operator v1 includes its own `MPIJob` CRD (`kubeflow.org/v1`). It conflicts with the stand-alone MPI Operator (`kubeflow.org/v2beta1`) that the stack installs by default. Remove the MPI Operator before you install Training Operator v1. Without this step, the Training Operator pod restarts continuously.
>
> After this change, these items are affected:
>
> - The NCCL test manifests in the oci-hpc-oke repository use the MPI Operator, so they do not work.
> - Kueue logs `Failed to watch *v2beta1.MPIJob` errors again and again, because its MPIJob integration expects `v2beta1`.

### Step 1: Install Training Operator

```bash
kubectl delete -f https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/refs/heads/main/manifests/mpi-operator/mpi-operator.yaml
kubectl apply --server-side --force-conflicts -k "github.com/kubeflow/training-operator.git/manifests/overlays/standalone?ref=v1.9.4"
```

The first command also removes the `MPIJob` CRD. The second command needs `--server-side --force-conflicts`, because the `PyTorchJob` and `PaddleJob` CRDs are larger than the client-side annotation limit of `kubectl`.

### Using c10d as the Rendezvous Backend

Save this manifest as `pytorchjob-c10d.yaml`.

```yaml
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
```

```bash
kubectl apply -f pytorchjob-c10d.yaml
kubectl get pytorchjob ddp-pytorchjob-c10d
kubectl logs ddp-pytorchjob-c10d-worker-0 | grep -E '^(host|world size|all_reduce|step|training finished)'
```

Important points about this manifest:

- Training Operator sets the rendezvous settings in `PET_*` environment variables. For example, it sets `PET_RDZV_ENDPOINT` to `ddp-pytorchjob-c10d-worker-0:23456` and `PET_NNODES` to `2:2`.
- `minReplicas` and `maxReplicas` are both 2. If `minReplicas` is lower than the number of workers, `torchrun` can start training before all pods join.
- `REPLICA_INDEX` comes from a pod label. Only worker 0 hosts the rendezvous store (`is_host=true`).
- `--local-addr=$POD_NAME` makes `torchrun` use the DNS name of the pod. Training Operator creates a Service for each worker, so this name resolves.

### Using etcd as the Rendezvous Backend

This example uses the etcd server from the [Volcano etcd example](#using-etcd-as-the-rendezvous-backend). If you did not create it, apply `etcd.yaml` first.

Save this manifest as `pytorchjob-etcd.yaml`.

```yaml
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
```

This manifest uses `generateName`, so use `kubectl create`, not `kubectl apply`:

```bash
kubectl create -f pytorchjob-etcd.yaml
kubectl get pytorchjobs
kubectl logs <job-name>-worker-0 | grep -E '^(host|world size|all_reduce|step|training finished)'
```

Important points about this manifest:

- `elasticPolicy` sets the `etcd-v2` backend and the address of the etcd server.
- Training Operator does not set a rendezvous ID. Without one, `torchrun` uses the ID `none` for every job. The first job closes the rendezvous `none` in etcd, and every later job fails with `RendezvousClosedError`.
- To get a new rendezvous ID for each run, the manifest sets `PET_RDZV_ID` from the job name, and `generateName` gives each job a new name.
- Like the Volcano example, it installs `python-etcd` before it starts `torchrun`.

## Verifying That NCCL Uses RDMA

Run these commands on the log of any pod. In the commands, `<pod>` is the name of the pod.

```bash
kubectl logs <pod> | grep -m1 'NCCL INFO Using network'
kubectl logs <pod> | grep -m1 'NET/IB : Using \[0\]'
kubectl logs <pod> | grep -c 'via NET/IB/.*/GDRDMA'
```

With RDMA, the output shows these items:

- `NCCL INFO Using network IB`. If you see `Using network Socket`, NCCL uses TCP.
- The 16 RDMA interfaces of BM.GPU4.8 in the `NET/IB : Using` line, each with `/RoCE`.
- More than 0 channels `via NET/IB/.../GDRDMA`. GDRDMA means GPUDirect RDMA. The network interface reads and writes GPU memory directly.

These results are from the tests on 2 x BM.GPU4.8 (16 GPUs). The table shows the bus bandwidth of `all_reduce` with an 8 GiB buffer.

| Method | Bus bandwidth |
| --- | --- |
| Kubeflow Trainer v2 | 191.1 GB/s |
| Kubeflow Trainer v2 with Kueue | 190.9 GB/s |
| Volcano, c10d | 191.0 GB/s |
| Volcano, etcd | 191.1 GB/s |
| Training Operator v1, c10d | 191.0 GB/s |
| Training Operator v1, etcd | 191.0 GB/s |
| nccl-tests `all_reduce_perf` from the oci-hpc-oke repository (reference) | 182.84 GB/s out-of-place, 190.17 GB/s in-place |

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The log shows `NCCL INFO Using network Socket`. | NCCL cannot use the RDMA interfaces. | Check `hostNetwork`, the `/dev/infiniband` mount, the RDMA libraries in the image, and `NCCL_IB_HCA` for your shape. |
| `EtcdStubError: The 'etcd' module is required but not installed` | The image does not include `python-etcd`. | Install `python-etcd` in the image, or before you start `torchrun`. |
| `RendezvousClosedError` with the `etcd-v2` backend | A previous job used the same rendezvous ID and closed the rendezvous. | Use a new rendezvous ID for each run. To delete all rendezvous data, delete the etcd pod and apply `etcd.yaml` again. |
| `kubectl get queues` does not show Volcano queues. | Kueue LocalQueue uses the same short names. | Run `kubectl get queues.scheduling.volcano.sh`. |
| The log shows `NCCL WARN NET/MLX5: Call to mlx5dv_devx_general_cmd failed with error Remote I/O error`. | Not known. These warnings appeared in all tests on BM.GPU4.8, including the NCCL tests from the oci-hpc-oke repository. | No action was necessary in the tests. All jobs still used RDMA at full bandwidth. |
