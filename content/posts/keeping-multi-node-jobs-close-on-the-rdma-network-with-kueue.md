+++
title = "Keeping Multi-Node Jobs Close on the RDMA Network with Kueue"
date = "2026-10-20"
draft = true
tags = ["kueue", "kubernetes", "rdma", "scheduling", "oke"]
description = "How Kueue's topology-aware scheduling keeps the pods of a multi-node job in one RDMA local block or network block, tested step by step from an empty cluster."
+++

The pods of a multi-node training job talk to each other all the time, so where they land on the RDMA network matters. OCI's cluster network is a three-tier Clos. According to [OCI's write-up of the design](https://blogs.oracle.com/cloud-infrastructure/first-principles-zettascale-oci-superclusters), the first tier of switches serves up to 256 GPUs with up to 2 µs of latency, the second tier up to 2,048 GPUs with up to 5 µs, and the third tier up to 131,072 GPUs with up to 8 µs. OCI calls the hosts under these tiers a local block, a network block and an HPC island.

The default Kubernetes scheduler knows none of this. It places each pod on its own, wherever the pod fits. A 4-node job can end up with two pods in one local block and two in another network block, and nothing tells you.

Kueue's topology-aware scheduling (TAS) fixes that. You describe the topology once. Kueue then places all the pods of a job as close together as it can, or keeps the job waiting until they fit where you require.

This post starts from a cluster with nothing installed. It labels the nodes, installs Kueue, creates the four Kueue objects, and runs eight experiments that show how Kueue decides. Every manifest and command in the post ran as written. Long files are collapsed, so click a file name to open it.

## The test cluster

I did not have eight bare metal GPU hosts spread over four local blocks to spare. So I tested on an OKE cluster with eight small CPU nodes, gave them a made-up RDMA topology with node labels, and gave each one 8 fake GPUs. Kueue's placement only looks at node labels, taints and capacity, so it treats these nodes the way it treats GPU hosts. The pods run `pause` and nothing else.

- OKE v1.36.4, kubectl v1.37.1
- 8 x VM.Standard.E5.Flex (2 OCPUs, 16 GB) in the node pool `oke-cpu`, standing in for the GPU hosts
- 3 system nodes in the node pool `oke-system`
- Kueue v0.20.2 and JobSet v0.13.0

## The topology

[![The RDMA topology of the test cluster as Kueue levels](/images/rdma-topology.png)](/images/rdma-topology.png)

Kueue models the topology as levels, from the widest to a single node. Each level is a node label. I use `oci.oraclecloud.com/rdma.hpc_island_id`, `oci.oraclecloud.com/rdma.network_block_id` and `oci.oraclecloud.com/rdma.local_block_id`, with `kubernetes.io/hostname` at the bottom. The test cluster has one island, two network blocks, two local blocks in each, and two nodes in each local block. Real local blocks are much larger, but the shape is the same.

## Where the topology comes from

On bare metal GPU hosts, the instance metadata service (IMDS) returns the place of the host in the RDMA network at `/opc/v2/host/rdmaTopologyData`. OCI's public IMDS documentation does not list this path. NVIDIA documents it for [Topograph's OCI provider](https://docs.nvidia.com/topograph/providers/oci/), which reads it the same way. On a host with a capacity topology, the document has four OCIDs (shortened here):

```json
{
  "customerHPCIslandId": "ocid1.hpcisland.oc1.iad.anuwcljrg5pyaeycajoqlss...",
  "customerHostId": "ocid1.computebaremetalhost.oc1.iad.anuwcljrg5pyaeycu...",
  "customerLocalBlock": "ocid1.computelocalblock.oc1.iad.anuwcljrg5pyaeyc...",
  "customerNetworkBlock": "ocid1.computenetworkblock.oc1.iad.anuwclddsdef..."
}
```

Kubernetes does not read IMDS, so the labels are yours to set. An OCID is longer than the 63 characters that a label value allows, so the script below stores a 12-character SHA-256 hash of each one. The value only has to be the same on all hosts in one block.

The script starts a short-lived pod on each node, with the host network, reads IMDS, and labels the node:

{{< code language="bash" title="label-from-imds.sh" open="false" >}}
#!/usr/bin/env bash
# Label each node with its RDMA topology from the instance metadata service (IMDS).
# Usage: label-from-imds.sh [node label selector]
set -euo pipefail

selector=${1:-}
imds=http://169.254.169.254/opc/v2/host/rdmaTopologyData
prefix=oci.oraclecloud.com/rdma

# OCIDs are longer than the 63 characters a label value allows, so use a short hash.
short() { printf '%s' "$1" | sha256sum | cut -c1-12; }

for node in $(kubectl get nodes ${selector:+-l "$selector"} -o jsonpath='{.items[*].metadata.name}'); do
  # A short-lived pod on the node's network reads IMDS, the same way a process on the host would.
  pod="imds-$(printf '%s' "$node" | tr '.' '-')"
  overrides=$(printf '{"spec":{"nodeName":"%s","hostNetwork":true,"tolerations":[{"operator":"Exists"}]}}' "$node")
  kubectl run "$pod" -q --restart=Never --image=busybox:1.37 --overrides="$overrides" -- \
    sh -c "wget -q -O - --header 'Authorization: Bearer Oracle' $imds 2>/dev/null || true" > /dev/null
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=120s > /dev/null
  json=$(kubectl logs "pod/$pod")
  kubectl delete pod "$pod" --wait=false > /dev/null

  island=$(jq -r '.customerHPCIslandId // empty' <<< "$json" 2>/dev/null || true)
  block=$(jq -r '.customerNetworkBlock // empty' <<< "$json" 2>/dev/null || true)
  local_block=$(jq -r '.customerLocalBlock // empty' <<< "$json" 2>/dev/null || true)
  host=$(jq -r '.customerHostId // empty' <<< "$json" 2>/dev/null || true)

  if [ -z "$island" ] || [ -z "$block" ] || [ -z "$local_block" ] || [ -z "$host" ]; then
    echo "$node: no RDMA topology in IMDS, skipped"
    continue
  fi

  kubectl label node "$node" --overwrite \
    "$prefix.hpc_island_id=$(short "$island")" \
    "$prefix.network_block_id=$(short "$block")" \
    "$prefix.local_block_id=$(short "$local_block")" \
    "$prefix.host_id=$(short "$host")"
done
{{< /code >}}

```bash
./label-from-imds.sh oke.oraclecloud.com/pool.name=oke-cpu
```

The test nodes are VMs, so there is no RDMA topology, and the script says so:

```
10.140.65.205: no RDMA topology in IMDS, skipped
10.140.68.178: no RDMA topology in IMDS, skipped
...
10.140.94.172: no RDMA topology in IMDS, skipped
```

From a pod on one of these VMs, `rdmaTopologyData` returns 404. The `/opc/v2/host` document exists, but it only has a building, a host and a rack ID (shortened here), with no network block or island:

```
## /opc/v2/host/rdmaTopologyData
wget: server returned error: HTTP/1.1 404 Not Found
## /opc/v2/host
{
  "buildingId": "building:81c65ff2...",
  "id": "2cf5737e...",
  "rackId": "e581e64b...",
  "virtualizationSolutionVersion": "1.20240607.1203"
}
```

So for the test, I set the labels by hand:

{{< code language="bash" title="label-simulated.sh" open="false" >}}
#!/usr/bin/env bash
# Give 8 nodes a made-up RDMA topology: 1 HPC island, 2 network blocks, 2 local blocks each.
# Usage: label-simulated.sh <node label selector>
set -euo pipefail

selector=$1
prefix=oci.oraclecloud.com/rdma
local_blocks=(lb-a1 lb-a1 lb-a2 lb-a2 lb-b1 lb-b1 lb-b2 lb-b2)

nodes=()
while read -r node; do
  nodes+=("$node")
done < <(kubectl get nodes -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
if [ "${#nodes[@]}" -ne 8 ]; then
  echo "expected 8 nodes, found ${#nodes[@]}" >&2
  exit 1
fi

for i in "${!nodes[@]}"; do
  lb=${local_blocks[$i]}
  kubectl label node "${nodes[$i]}" --overwrite \
    "$prefix.hpc_island_id=isl-1" \
    "$prefix.network_block_id=nb-${lb:3:1}" \
    "$prefix.local_block_id=$lb" \
    "$prefix.host_id=host-$((i + 1))"
done
{{< /code >}}

```bash
./label-simulated.sh oke.oraclecloud.com/pool.name=oke-cpu
```

Labels do not survive a node replacement. A new node starts without topology labels, and Kueue leaves it out until you label it. On a real cluster, run the labeling script again after every scale-up or node replacement.

## Fake GPUs

Each test node also needs `nvidia.com/gpu` capacity. I added 8 per node with the method from the [Kubernetes documentation for extended resources](https://kubernetes.io/docs/tasks/administer-cluster/extended-resource-node/), a patch to the status of the node:

{{< code language="bash" title="fake-gpus.sh" open="false" >}}
#!/usr/bin/env bash
# Advertise 8 fake nvidia.com/gpu on each selected node, so CPU nodes can stand in for GPU nodes.
# Usage: fake-gpus.sh <node label selector>
set -euo pipefail

selector=$1
for node in $(kubectl get nodes -l "$selector" -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch node "$node" --subresource=status --type=json \
    -p '[{"op": "add", "path": "/status/capacity/nvidia.com~1gpu", "value": "8"}]'
done
{{< /code >}}

```bash
./fake-gpus.sh oke.oraclecloud.com/pool.name=oke-cpu
```

OKE's NVIDIA device plugin DaemonSet only runs on GPU shapes and on nodes with the label `nvidia.com/gpu=true`. It had 0 pods on this cluster, so nothing reset the fake count. Do not do this on a cluster with real GPUs.

After both scripts:

```bash
kubectl get nodes -l oke.oraclecloud.com/pool.name=oke-cpu -o custom-columns='NAME:.metadata.name,NETWORK_BLOCK:.metadata.labels.oci\.oraclecloud\.com/rdma\.network_block_id,LOCAL_BLOCK:.metadata.labels.oci\.oraclecloud\.com/rdma\.local_block_id,HOST:.metadata.labels.oci\.oraclecloud\.com/rdma\.host_id,GPU_CAP:.status.capacity.nvidia\.com/gpu,GPU_ALLOC:.status.allocatable.nvidia\.com/gpu'
```

```
NAME            NETWORK_BLOCK   LOCAL_BLOCK   HOST     GPU_CAP   GPU_ALLOC
10.140.65.205   nb-a            lb-a1         host-1   8         8
10.140.68.178   nb-a            lb-a1         host-2   8         8
10.140.71.229   nb-a            lb-a2         host-3   8         8
10.140.75.175   nb-a            lb-a2         host-4   8         8
10.140.77.31    nb-b            lb-b1         host-5   8         8
10.140.84.34    nb-b            lb-b1         host-6   8         8
10.140.88.205   nb-b            lb-b2         host-7   8         8
10.140.94.172   nb-b            lb-b2         host-8   8         8
```

## Installing Kueue

```bash
helm install kueue oci://registry.k8s.io/kueue/charts/kueue --version 0.20.2 \
  --namespace kueue-system --create-namespace --wait
```

TAS needs no extra values. The `TopologyAwareScheduling` feature gate is beta and on by default since Kueue 0.14 ([`kube_features.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/pkg/features/kube_features.go#L975-L978)). All four objects below use `kueue.x-k8s.io/v1beta2`. In v0.20.2, the `v1beta1` versions of these APIs are deprecated and no longer served ([Topology CRD](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/config/components/crd/bases/kueue.x-k8s.io_topologies.yaml#L19-L21)), so older examples that use `v1beta1` need the new version.

### Topology

{{< code language="yaml" title="topology.yaml" open="false" >}}
apiVersion: kueue.x-k8s.io/v1beta2
kind: Topology
metadata:
  name: oci-rdma
spec:
  levels:
  - nodeLabel: oci.oraclecloud.com/rdma.hpc_island_id
  - nodeLabel: oci.oraclecloud.com/rdma.network_block_id
  - nodeLabel: oci.oraclecloud.com/rdma.local_block_id
  - nodeLabel: kubernetes.io/hostname
{{< /code >}}

The levels go from the widest to the narrowest, with at most 16 levels. `kubernetes.io/hostname` can only be the last level. With the host name as the last level, Kueue assigns every pod to a node, which shows up in the Workload status below.

### ResourceFlavor

{{< code language="yaml" title="resourceflavor.yaml" open="false" >}}
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: gpu-rdma
spec:
  nodeLabels:
    oke.oraclecloud.com/pool.name: oke-cpu
  topologyName: oci-rdma
  tolerations:
  - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
{{< /code >}}

`nodeLabels` selects the nodes of the flavor. On a GPU cluster that would be a label such as `node.kubernetes.io/instance-type: BM.GPU.H100.8`. Here it is the CPU node pool. `topologyName` makes it a TAS flavor. It needs at least one node label, and it cannot be changed later. Kueue adds the `nodeLabels` and `tolerations` of the flavor to every pod that it admits on this flavor.

### ClusterQueue

{{< code language="yaml" title="clusterqueue.yaml" open="false" >}}
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: gpu-rdma
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
    flavors:
    - name: gpu-rdma
      resources:
      - { name: cpu, nominalQuota: 32 }
      - { name: memory, nominalQuota: 128Gi }
      - { name: nvidia.com/gpu, nominalQuota: 64 }
{{< /code >}}

`coveredResources` must list every resource that the pods request. `namespaceSelector: {}` lets every namespace use the queue. Without it, no namespace can. The quota is the eight test nodes, 32 vCPUs, 128 GiB and 64 GPUs.

### LocalQueue

{{< code language="yaml" title="localqueue.yaml" open="false" >}}
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata:
  name: gpu-rdma
  namespace: default
spec:
  clusterQueue: gpu-rdma
{{< /code >}}

```bash
for f in topology resourceflavor clusterqueue localqueue; do kubectl apply -f $f.yaml; done
kubectl get localqueue
```

```
NAME       CLUSTERQUEUE   PENDING WORKLOADS   ADMITTED WORKLOADS
gpu-rdma   gpu-rdma       0                   0
```

The ClusterQueue reports `Active=True` with the message `Can admit new workloads`.

## How TAS decides

A job asks for a topology with an annotation on its pod template:

| Annotation | What Kueue does |
| --- | --- |
| `kueue.x-k8s.io/podset-required-topology: <level>` | Puts all pods in one domain of that level, or the job waits. |
| `kueue.x-k8s.io/podset-preferred-topology: <level>` | Puts all pods in one domain of that level if they fit. If not, it moves up one level at a time. |
| `kueue.x-k8s.io/podset-unconstrained-topology: "true"` | Uses TAS with no locality rule. |
| `kueue.x-k8s.io/podset-slice-required-topology: <level>` and `kueue.x-k8s.io/podset-slice-size: "<n>"` | Splits the pods into slices of n, and puts each slice in one domain of that level. |

The annotations are defined in [`topology_types.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/apis/kueue/v1beta2/topology_types.go#L24-L69). For preferred, the step up is a call to the same search one level higher ([`tas_flavor_snapshot.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/pkg/cache/scheduler/tas_flavor_snapshot.go#L1975-L1977)).

For required and preferred, Kueue uses a best-fit algorithm. Of the domains that fit, it picks the one with the least room left. For unconstrained placement, it picks the domains with the least free capacity ([`tas_flavor_snapshot.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/pkg/cache/scheduler/tas_flavor_snapshot.go#L2071-L2079)).

Free capacity is the allocatable resources of each node, minus the requests of pods that Kueue did not place (DaemonSet pods, for example), minus what Kueue already admitted. A node is left out when it is not Ready, is cordoned, does not match the `nodeLabels` of the flavor, has a taint that the pods do not tolerate, or is missing any of the topology labels ([`node.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/pkg/util/tas/node.go#L33-L47), [`tas_nodes_cache.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/pkg/cache/scheduler/tas_nodes_cache.go#L57-L66)).

## The experiments

[![Where Kueue placed the pods in each experiment](/images/tas-placement.png)](/images/tas-placement.png)

Every experiment is an Indexed Job of `pause` pods that each ask for 8 GPUs, so each pod takes a whole node. I deleted each job before the next experiment, unless I say otherwise. To see where the pods landed, I used this script:

{{< code language="bash" title="placement.sh" open="false" >}}
#!/usr/bin/env bash
# Show where the pods of a job landed in the RDMA topology.
# Usage: placement.sh <pod label selector>
set -euo pipefail

printf '%-32s %-14s %-14s %-12s\n' POD NODE NETWORK_BLOCK LOCAL_BLOCK
kubectl get pods -l "$1" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | sort |
while read -r pod node; do
  if [ -z "${node:-}" ]; then
    printf '%-32s %-14s\n' "$pod" "(not scheduled)"
    continue
  fi
  labels=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.oci\.oraclecloud\.com/rdma\.network_block_id} {.metadata.labels.oci\.oraclecloud\.com/rdma\.local_block_id}')
  read -r nb lb <<< "$labels"
  printf '%-32s %-14s %-14s %-12s\n' "$pod" "$node" "$nb" "$lb"
done
{{< /code >}}

And these commands for Kueue's view of a job:

```bash
kubectl get workloads
kubectl get workload <name> -o jsonpath='{.status.admission.podSetAssignments[*].topologyAssignment}' | jq
kubectl get workload <name> -o json | jq -r '.status.conditions[] | "\(.type)=\(.status) reason=\(.reason) message=\(.message)"'
```

### 1. Two pods, preferred local block

{{< code language="yaml" title="local-2.yaml" open="false" >}}
apiVersion: batch/v1
kind: Job
metadata:
  name: local-2
  labels:
    kueue.x-k8s.io/queue-name: gpu-rdma
spec:
  parallelism: 2
  completions: 2
  completionMode: Indexed
  template:
    metadata:
      annotations:
        kueue.x-k8s.io/podset-preferred-topology: oci.oraclecloud.com/rdma.local_block_id
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: registry.k8s.io/pause:3.10.2
        resources:
          requests: { cpu: 100m, memory: 64Mi }
          limits: { nvidia.com/gpu: 8 }
{{< /code >}}

```bash
kubectl apply -f local-2.yaml
./placement.sh job-name=local-2
```

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
local-2-0-l4x46                  10.140.65.205  nb-a           lb-a1
local-2-1-kstl9                  10.140.68.178  nb-a           lb-a1
```

Both pods are in `lb-a1`. The Workload holds the assignment in a compact form:

```json
{
  "levels": [
    "kubernetes.io/hostname"
  ],
  "slices": [
    {
      "domainCount": 2,
      "podCounts": {
        "universal": 1
      },
      "valuesPerLevel": [
        {
          "individual": {
            "prefix": "10.140.6",
            "roots": [
              "5.205",
              "8.178"
            ]
          }
        }
      ]
    }
  ]
}
```

`levels` has only the host name, because the Topology ends with it. The two host names share the prefix `10.140.6`, so Kueue stores the prefix once and then the rest of each name, `5.205` and `8.178`. `podCounts.universal: 1` means one pod on each of the two nodes. The format is defined in [`workload_types.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/apis/kueue/v1beta2/workload_types.go#L458-L555).

### 2. Four pods, preferred local block

{{< code language="yaml" title="local-4.yaml" open="false" >}}
apiVersion: batch/v1
kind: Job
metadata:
  name: local-4
  labels:
    kueue.x-k8s.io/queue-name: gpu-rdma
spec:
  parallelism: 4
  completions: 4
  completionMode: Indexed
  template:
    metadata:
      annotations:
        kueue.x-k8s.io/podset-preferred-topology: oci.oraclecloud.com/rdma.local_block_id
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: registry.k8s.io/pause:3.10.2
        resources:
          requests: { cpu: 100m, memory: 64Mi }
          limits: { nvidia.com/gpu: 8 }
{{< /code >}}

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
local-4-0-lhs4q                  10.140.65.205  nb-a           lb-a1
local-4-1-6nvkz                  10.140.68.178  nb-a           lb-a1
local-4-2-7xwjc                  10.140.71.229  nb-a           lb-a2
local-4-3-hwwrg                  10.140.75.175  nb-a           lb-a2
```

No local block has four nodes, so Kueue moved up to the network block and used both local blocks of `nb-a`.

### 3. Four pods, required local block

{{< code language="yaml" title="local-4-required.yaml" open="false" >}}
apiVersion: batch/v1
kind: Job
metadata:
  name: local-4-required
  labels:
    kueue.x-k8s.io/queue-name: gpu-rdma
spec:
  parallelism: 4
  completions: 4
  completionMode: Indexed
  template:
    metadata:
      annotations:
        kueue.x-k8s.io/podset-required-topology: oci.oraclecloud.com/rdma.local_block_id
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: registry.k8s.io/pause:3.10.2
        resources:
          requests: { cpu: 100m, memory: 64Mi }
          limits: { nvidia.com/gpu: 8 }
{{< /code >}}

```
QuotaReserved=False reason=TopologyPlacementFailed message=couldn't assign flavors to pod set main: topology "oci-rdma" allows to fit only 2 out of 4 pod(s); all pods must fit in a single "oci.oraclecloud.com/rdma.local_block_id" topology domain
Admitted=False reason=NoReservation message=The workload has no reservation
PodsReady=False reason=WaitForStart message=Not all pods are ready or succeeded
```

The Job stays suspended, so it has no pods at all. Nothing runs half placed, and nothing runs at all until four nodes are free in one local block. Here that can never happen, so the job waits forever. Check `kubectl get workloads` when a job does not start.

### 4. Best fit

First I kept one node busy with a 1-pod job, pinned to `lb-b1` with a `nodeSelector`. TAS takes the `nodeSelector` of the pods into account.

{{< code language="yaml" title="filler.yaml" open="false" >}}
apiVersion: batch/v1
kind: Job
metadata:
  name: filler
  labels:
    kueue.x-k8s.io/queue-name: gpu-rdma
spec:
  parallelism: 1
  completions: 1
  completionMode: Indexed
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        oci.oraclecloud.com/rdma.local_block_id: lb-b1
      containers:
      - name: worker
        image: registry.k8s.io/pause:3.10.2
        resources:
          requests: { cpu: 100m, memory: 64Mi }
          limits: { nvidia.com/gpu: 8 }
{{< /code >}}

Then a 3-pod job that prefers one network block:

{{< code language="yaml" title="block-3.yaml" open="false" >}}
apiVersion: batch/v1
kind: Job
metadata:
  name: block-3
  labels:
    kueue.x-k8s.io/queue-name: gpu-rdma
spec:
  parallelism: 3
  completions: 3
  completionMode: Indexed
  template:
    metadata:
      annotations:
        kueue.x-k8s.io/podset-preferred-topology: oci.oraclecloud.com/rdma.network_block_id
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: registry.k8s.io/pause:3.10.2
        resources:
          requests: { cpu: 100m, memory: 64Mi }
          limits: { nvidia.com/gpu: 8 }
{{< /code >}}

```bash
kubectl apply -f filler.yaml
kubectl apply -f block-3.yaml
./placement.sh job-name=filler
./placement.sh job-name=block-3
```

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
filler-0-kskmh                   10.140.77.31   nb-b           lb-b1
```

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
block-3-0-zrmb6                  10.140.84.34   nb-b           lb-b1
block-3-1-6q9vm                  10.140.88.205  nb-b           lb-b2
block-3-2-dfqfx                  10.140.94.172  nb-b           lb-b2
```

`nb-a` had four free nodes and `nb-b` had three. Both fit three pods. Kueue picked `nb-b`, the one with the least room left, so `nb-a` stays whole for a 4-node job. When I ran the same test with the busy node in `lb-a1`, the 3-pod job went to `nb-a`, so this is not alphabetical order.

### 5. Slices

{{< code language="yaml" title="slices-4.yaml" open="false" >}}
apiVersion: batch/v1
kind: Job
metadata:
  name: slices-4
  labels:
    kueue.x-k8s.io/queue-name: gpu-rdma
spec:
  parallelism: 4
  completions: 4
  completionMode: Indexed
  template:
    metadata:
      annotations:
        kueue.x-k8s.io/podset-slice-required-topology: oci.oraclecloud.com/rdma.local_block_id
        kueue.x-k8s.io/podset-slice-size: "2"
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: registry.k8s.io/pause:3.10.2
        resources:
          requests: { cpu: 100m, memory: 64Mi }
          limits: { nvidia.com/gpu: 8 }
{{< /code >}}

On an empty cluster, this job lands like the job in experiment 2, with two pods in `lb-a1` and two in `lb-a2`. The difference shows on a busy cluster. I kept three nodes busy, one each in `lb-a1`, `lb-a2` and `lb-b1`, with copies of the filler job:

```bash
sed -e 's/name: filler$/name: filler-a1/' -e 's/lb-b1/lb-a1/' filler.yaml > filler-a1.yaml
sed -e 's/name: filler$/name: filler-a2/' -e 's/lb-b1/lb-a2/' filler.yaml > filler-a2.yaml
kubectl apply -f filler.yaml
kubectl apply -f filler-a1.yaml
kubectl apply -f filler-a2.yaml
```

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
filler-0-c74cr                   10.140.77.31   nb-b           lb-b1
filler-a1-0-lmpkz                10.140.65.205  nb-a           lb-a1
filler-a2-0-p5vs4                10.140.71.229  nb-a           lb-a2
```

Then I ran the 4-pod job from experiment 2, which prefers one local block:

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
local-4-0-rz24r                  10.140.68.178  nb-a           lb-a1
local-4-1-rr8wp                  10.140.75.175  nb-a           lb-a2
local-4-2-bdl4p                  10.140.88.205  nb-b           lb-b2
local-4-3-nz26v                  10.140.94.172  nb-b           lb-b2
```

It ran, but pods 0 and 1 ended up in different local blocks. Then the job with slices:

```
QuotaReserved=False reason=WaitingForQuota message=couldn't assign flavors to pod set main: topology "oci-rdma" allows to fit only 1 out of 2 slice(s). Total nodes: 8; excluded: resource "nvidia.com/gpu": 3
Admitted=False reason=NoReservation message=The workload has no reservation
PodsReady=False reason=WaitForStart message=Not all pods are ready or succeeded
```

With slices, every pair stays in one local block, or the job does not start. Only `lb-b2` still had two free nodes, so one slice fit, and the job waited. The reason is `WaitingForQuota` here, not `TopologyPlacementFailed` as in experiment 3, and the message counts the nodes left out for lack of free GPUs.

### 6. No annotation

{{< code language="yaml" title="no-annotation-2.yaml" open="false" >}}
apiVersion: batch/v1
kind: Job
metadata:
  name: no-annotation-2
  labels:
    kueue.x-k8s.io/queue-name: gpu-rdma
spec:
  parallelism: 2
  completions: 2
  completionMode: Indexed
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: registry.k8s.io/pause:3.10.2
        resources:
          requests: { cpu: 100m, memory: 64Mi }
          limits: { nvidia.com/gpu: 8 }
{{< /code >}}

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
no-annotation-2-0-zj5dw          10.140.65.205  nb-a           lb-a1
no-annotation-2-1-89hvs          10.140.68.178  nb-a           lb-a1
```

The job was admitted with TAS anyway. Kueue added this annotation to its pod template:

```json
{
  "kueue.x-k8s.io/podset-unconstrained-topology": "true"
}
```

When every flavor in the ClusterQueue is a TAS flavor, Kueue applies TAS to every job, with or without an annotation ([`tas_flavorassigner.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/pkg/scheduler/flavorassigner/tas_flavorassigner.go#L256-L265)). The two pods share `lb-a1` on an empty cluster, but unconstrained placement does not promise that.

### 7. A pod with no requests

An MPI launcher or a small controller pod often has no resource requests:

{{< code language="yaml" title="no-requests.yaml" open="false" >}}
apiVersion: batch/v1
kind: Job
metadata:
  name: no-requests
  labels:
    kueue.x-k8s.io/queue-name: gpu-rdma
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: launcher
        image: registry.k8s.io/pause:3.10.2
{{< /code >}}

```
QuotaReserved=False reason=NoMatchingFlavor message=failed to assign flavors to pod set main: no TAS flavor assigned
Admitted=False reason=NoReservation message=The workload has no reservation
PodsReady=False reason=WaitForStart message=Not all pods are ready or succeeded
```

A pod set without requests gets no flavor. In a ClusterQueue with only TAS flavors, that means no TAS flavor, and the job waits ([`errors.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/pkg/scheduler/flavorassigner/errors.go#L34)).

The first fix is a small request:

{{< code language="yaml" title="with-request.yaml" open="false" >}}
apiVersion: batch/v1
kind: Job
metadata:
  name: with-request
  labels:
    kueue.x-k8s.io/queue-name: gpu-rdma
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: launcher
        image: registry.k8s.io/pause:3.10.2
        resources:
          requests: { cpu: 100m, memory: 64Mi }
{{< /code >}}

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
with-request-x27fg               10.140.65.205  nb-a           lb-a1
```

It was admitted with TAS, but it landed on one of the topology nodes. On a real cluster that is a GPU host.

The second fix is a flavor without a topology for everything that does not need one. Here it is the system node pool, added to the same ClusterQueue with its own small quota:

{{< code language="yaml" title="resourceflavor-system.yaml" open="false" >}}
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: system
spec:
  nodeLabels:
    oke.oraclecloud.com/pool.name: oke-system
{{< /code >}}

{{< code language="yaml" title="clusterqueue-mixed.yaml" open="false" >}}
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: gpu-rdma
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
    flavors:
    - name: gpu-rdma
      resources:
      - { name: cpu, nominalQuota: 32 }
      - { name: memory, nominalQuota: 128Gi }
      - { name: nvidia.com/gpu, nominalQuota: 64 }
    - name: system
      resources:
      - { name: cpu, nominalQuota: 4 }
      - { name: memory, nominalQuota: 16Gi }
      - { name: nvidia.com/gpu, nominalQuota: 0 }
{{< /code >}}

```bash
kubectl apply -f resourceflavor-system.yaml -f clusterqueue-mixed.yaml
```

The `no-requests` job, still waiting, was admitted right after this change, with no flavor and no topology. The default scheduler put it on a topology node in `lb-a2`:

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
no-requests-fxmx9                10.140.75.175  nb-a           lb-a2
{"name":"main","flavors":null,"topologyAssignment":null}
```

The `with-request` job, run again, got the `system` flavor and landed on a system node:

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
with-request-52zqk               10.140.75.55
```

```
{"name":"main","flavors":{"cpu":"system","memory":"system"}}
```

So a launcher needs both, the mixed ClusterQueue and a small request. Kueue skips the TAS flavor for a pod set without a topology annotation, and gives it the system flavor with its `nodeLabels`.

### 8. A JobSet with a launcher and workers

```bash
helm install jobset oci://registry.k8s.io/jobset/charts/jobset --version 0.13.0 \
  --namespace jobset-system --create-namespace --wait
```

{{< code language="yaml" title="jobset-4.yaml" open="false" >}}
apiVersion: jobset.x-k8s.io/v1alpha2
kind: JobSet
metadata:
  name: train
  labels:
    kueue.x-k8s.io/queue-name: gpu-rdma
spec:
  replicatedJobs:
  - name: launcher
    replicas: 1
    template:
      spec:
        template:
          spec:
            restartPolicy: Never
            containers:
            - name: launcher
              image: registry.k8s.io/pause:3.10.2
              resources:
                requests: { cpu: 100m, memory: 64Mi }
  - name: workers
    replicas: 1
    template:
      spec:
        parallelism: 4
        completions: 4
        completionMode: Indexed
        template:
          metadata:
            annotations:
              kueue.x-k8s.io/podset-preferred-topology: oci.oraclecloud.com/rdma.network_block_id
          spec:
            restartPolicy: Never
            containers:
            - name: worker
              image: registry.k8s.io/pause:3.10.2
              resources:
                requests: { cpu: 100m, memory: 64Mi }
                limits: { nvidia.com/gpu: 8 }
{{< /code >}}

```bash
kubectl apply -f jobset-4.yaml
./placement.sh jobset.sigs.k8s.io/jobset-name=train
```

```
POD                              NODE           NETWORK_BLOCK  LOCAL_BLOCK
train-launcher-0-0-8npkv         10.140.75.55
train-workers-0-0-rbcfq          10.140.65.205  nb-a           lb-a1
train-workers-0-1-lk4td          10.140.68.178  nb-a           lb-a1
train-workers-0-2-sg92v          10.140.71.229  nb-a           lb-a2
train-workers-0-3-kb4ms          10.140.75.175  nb-a           lb-a2
```

Each replicated job of the JobSet is a pod set of its own in the Workload:

```
{"name":"launcher","count":1,"flavors":{"cpu":"system","memory":"system"},"levels":null}
{"name":"workers","count":4,"flavors":{"cpu":"gpu-rdma","memory":"gpu-rdma","nvidia.com/gpu":"gpu-rdma"},"levels":["kubernetes.io/hostname"]}
```

The launcher got the `system` flavor and runs on a system node. The four workers got the TAS flavor and run in one network block. This is the layout I want for a training job.

## What Kueue writes into the job and the pods

After it admitted the job in experiment 1, Kueue changed the pod template of the Job:

```bash
kubectl get job local-2 -o json | jq '{suspend: .spec.suspend, gates: .spec.template.spec.schedulingGates, nodeSelector: .spec.template.spec.nodeSelector, tolerations: .spec.template.spec.tolerations, annotations: .spec.template.metadata.annotations}'
```

```json
{
  "suspend": false,
  "gates": [
    {
      "name": "kueue.x-k8s.io/topology"
    }
  ],
  "nodeSelector": {
    "oke.oraclecloud.com/pool.name": "oke-cpu"
  },
  "tolerations": [
    {
      "effect": "NoSchedule",
      "key": "nvidia.com/gpu",
      "operator": "Exists"
    }
  ],
  "annotations": {
    "kueue.x-k8s.io/podset-preferred-topology": "oci.oraclecloud.com/rdma.local_block_id",
    "kueue.x-k8s.io/workload": "job-local-2-07949"
  }
}
```

The pod template now has the scheduling gate `kueue.x-k8s.io/topology` ([`topology_types.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/apis/kueue/v1beta2/topology_types.go#L71-L75)), so the default scheduler cannot place the new pods yet. It also has the `nodeLabels` and the toleration of the flavor. Kueue's topology ungater then removes the gate from each pod and adds a `kubernetes.io/hostname` node selector with the node from the assignment ([`topology_ungater.go`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/pkg/controller/tas/topology_ungater.go#L306-L317)):

```bash
kubectl get pods -l job-name=local-2 -o json | jq -r '.items[] | "\(.metadata.name) nodeSelector=\(.spec.nodeSelector|tojson) gates=\(.spec.schedulingGates // []|tojson)"'
```

```
local-2-0-l4x46 nodeSelector={"kubernetes.io/hostname":"10.140.65.205","oke.oraclecloud.com/pool.name":"oke-cpu"} gates=[]
local-2-1-kstl9 nodeSelector={"kubernetes.io/hostname":"10.140.68.178","oke.oraclecloud.com/pool.name":"oke-cpu"} gates=[]
```

The default scheduler still binds the pods, but each pod can only go to one node.

## Things to watch for

- **Pods without requests.** In a ClusterQueue with only TAS flavors, they never start. Give every pod a request, and add a flavor without a topology for launchers (experiment 7).
- **PyTorchJob is off by default.** The default Helm values of v0.20.2 do not enable `kubeflow.org/pytorchjob` ([`values.yaml`](https://github.com/kubernetes-sigs/kueue/blob/v0.20.2/charts/kueue/values.yaml#L171-L190)). The running config on the test cluster listed `batch/job`, `jobset.x-k8s.io/jobset`, `trainer.kubeflow.org/trainjob` and `kubeflow.org/mpijob`, but not PyTorchJob. Enable every integration that you use.
- **New nodes have no topology labels.** Kueue leaves them out until you label them.
- **DaemonSet pods count.** Their requests reduce the free capacity of every node.
- **A required topology can wait forever.** The job stays suspended with a condition and no pods. Check `kubectl get workloads`.

## Without Kueue

Node affinity and pod affinity with the same labels work pod by pod. The default scheduler places the first pod wherever it fits, and the other pods follow it. With soft rules, the job can still spread out. With hard rules, the job can start with some pods running and the rest waiting for room in a block that is already full. Kueue looks at all the pods of the job before any of them starts.

## What I would do on a real cluster

- Label the nodes from IMDS, and label them again after every node replacement.
- Use `podset-preferred-topology` on the local block for most jobs. It keeps the pods close when there is room and falls back when there is not.
- Use `podset-required-topology` only when the job is useless outside one domain, and watch for jobs that wait forever.
- Use slices for groups of pods that talk to each other the most.
- Give every pod a request, and add a flavor without a topology for launchers.
- When a job does not start, read the conditions of its Workload. Kueue says exactly what did not fit.
