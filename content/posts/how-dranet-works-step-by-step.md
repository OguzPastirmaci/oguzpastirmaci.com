+++
title = "How Dranet Works, Step by Step"
date = "2026-11-10"
draft = false
ogImage = "/images/og/how-dranet-works-step-by-step.png"
tags = ["dranet", "kubernetes", "dra", "rdma", "oke"]
description = "An interactive walkthrough of how Dranet finds a network device, gives it to a pod, and takes it back, with links to the code of each release."
+++

[Dranet](https://github.com/kubernetes-sigs/dranet) is a Kubernetes network driver. It gives pods real network devices, such as NICs, SR-IOV VFs and RDMA devices, through Dynamic Resource Allocation (DRA). I use it to give RDMA NICs to GPU pods on OKE. I am a reviewer for the Dranet repository and one of the owners of its OKE cloud provider.

Several components take part in the flow, and each one acts at a different time. So I made a page that shows the flow one step at a time. It helped me understand and visualize the flow when I contributed to Dranet.

**[Open the walkthrough: How Dranet works](/how-dranet-works/)**

## What the page shows

The page follows one network device through 15 steps:

1. Dranet starts on the node and registers with the kubelet and the container runtime.
2. It finds the network devices of the node and publishes them as ResourceSlices.
3. A workload asks for a device with a ResourceClaim, and the scheduler allocates one.
4. The kubelet asks Dranet to prepare the claim. Dranet works out the final configuration and saves it.
5. The container runtime creates the pod, and Dranet puts the device into the pod's network namespace.
6. When the pod stops, Dranet gives the device back and publishes it again.

A diagram of the node highlights the components that take part in each step. Below it, two lists show which interfaces are in the host and which are in the pod.

## Two example nodes

A switch at the top of the page selects the example.

- **OKE RDMA NIC.** The RDMA NIC stays on the host. The pod gets an IPvlan child of it with its own address. This is what the OKE provider does for Ethernet RDMA NICs.
- **Passthrough NIC.** The whole interface moves from the host into the pod, and moves back when the pod stops. This is the default behavior of Dranet.

## Links to the code

Each step names the Go functions that do the work and links to them on GitHub. The page is pinned to one Dranet release, currently v1.5.0, so the links and line numbers stay correct. I plan to update it when a new release ships.

The sections below the player cover a few topics that cut across the steps. They show where the applied configuration comes from, how the two attach types differ, what the RDMA namespace modes change, and what happens on a restart.

If you find something wrong on the page, please tell me on [LinkedIn](https://www.linkedin.com/in/oguzpastirmaci/).
