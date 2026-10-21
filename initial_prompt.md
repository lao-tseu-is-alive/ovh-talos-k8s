# OVH Talos Kubernetes — Codex Project Instructions

## Objective

Build a reproducible three-node Kubernetes development cluster using:

- Talos Linux with upstream Kubernetes
- Cilium with kube-proxy replacement and Hubble
- Longhorn for persistent storage
- Proxmox VE as the virtualization platform

Replace the existing Ubuntu/K3s cluster rather than migrate it.

Favor simplicity, official documentation, pinned compatible versions and incremental, verifiable execution.

## 1. Configuration as code

Use the repository's root `config.yaml` as the single source of truth for deployment-specific parameters.

It must contain:
- Proxmox host identification.
- Management bastion.
- Cluster name, Kubernetes API endpoint and VIP.
- Node definitions: hostname, VM ID, IP and role.
- VM hardware, disk and network parameters.
- Talos, Kubernetes, Cilium and Longhorn versions.
- System extensions required by Talos.
- Cilium ingress VIP and Longhorn storage configuration.

Do not hardcode hostnames, IP addresses, VM IDs or deployment-specific settings in scripts.

Validate `config.yaml` before generating or applying configurations.

Keep all credentials, private keys, Talos machine secrets, kubeconfigs and other sensitive material outside Git.

The repository `config.yaml` is a project configuration, not a native Talos machine configuration. Generate native configurations from it using supported Talos mechanisms.

## 2. Management architecture

### Development workstation

`pulsar-2021` runs Codex, Git and the project source code.

Its local LAN uses `192.168.50.0/24`, which overlaps with the OVH private network but is physically separate.

Therefore, never assume that an OVH `192.168.50.x` address is directly reachable from `pulsar-2021`.

### Administration bastion

`ovh-fw-k3s` is the existing SSH bastion providing access to the OVH private network.

- Private address: `192.168.50.2`.
- Reachable from `pulsar-2021` through the existing SSH configuration.
- SSH connectivity must remain operational.

Use this management model:

- Develop and maintain configurations on `pulsar-2021`.
- Execute `talosctl`, `kubectl` and Helm commands from `ovh-fw-k3s`.
- Invoke bastion commands through SSH when appropriate.
- Install missing management tools on the bastion only after approval.
- Protect administrative credentials and restrict their filesystem permissions.

Avoid adding VPNs, routing layers or new management infrastructure.

## 3. Strict infrastructure boundaries

The Proxmox physical host also runs production VMs unrelated to this project.

**Never modify the existing Proxmox host networking or unrelated VMs.**

Do not change:
- Proxmox bridges, VLANs, network interfaces or routes.
- Proxmox host firewall rules.
- The existing OVH private subnet.
- Networking or firewall configuration of `ovh-fw-k3s` without explicit approval.
- Any unrelated VM or its storage.

Only VMs listed in `config.yaml` are candidates for replacement.

Preserve their configured VM IDs, names and IP addresses.

The target network includes:
- Kubernetes API VIP: `192.168.50.241`.
- Cilium ingress VIP: `192.168.50.240`.

Verify that both VIPs are available before use and configure the API VIP using native Talos mechanisms where supported.

The three control-plane nodes must also be able to run application workloads.

Configure Kubernetes API certificates with the appropriate DNS names and IP SANs.

Manage name resolution for the Kubernetes API on the bastion without changing the wider network.

## 4. Existing infrastructure

The current K3s cluster is being discarded, not migrated.

Do not audit or reproduce its old Kubernetes configuration unless necessary to:
- Verify VM hardware and networking.
- Understand storage or external dependencies.
- Establish recoverable backups.
- Prevent unintended disruption.

Do not blindly reuse old Cilium 1.16 configuration.

Design the new cluster using current, officially supported Talos, Cilium and Longhorn configurations.

Inspect only relevant infrastructure properties:
- Proxmox storage and VM definitions.
- Existing VM network bridges, gateway and DNS.
- Available CPU, RAM and disk capacity.
- Backup and restoration options.
- External dependencies that could be affected.

## 5. Talos image preparation

Use the official Talos Image Factory to prepare version-pinned installation and installer images.

Verify the compatibility of:
- Talos and Kubernetes.
- Talos and Cilium.
- Talos and Longhorn.
- The selected system extensions.

The initial expected extensions are:

- `siderolabs/iscsi-tools`
- `siderolabs/util-linux-tools`
- `siderolabs/qemu-guest-agent`

Verify exact extension names, availability and necessity for the selected releases.

Choose an installation mechanism suitable for Proxmox.

Record the Image Factory schematic, version, image references and verification information so images can be reproduced.

Ensure that installed Talos systems contain the required extensions, not merely the boot media.

## 6. Kubernetes networking and storage

### Cilium

Deploy Cilium as the sole CNI with kube-proxy replacement.

Ensure compatibility with Talos bootstrap, API connectivity and KubePrism where applicable.

Configure Hubble and an ingress solution using the selected supported Cilium release.

Preserve the intended ingress VIP without changing existing network infrastructure.

### Longhorn

Configure Longhorn with a dedicated virtual disk per node where feasible.

Use supported Talos disk configuration, mounts and system extensions.

Support:
- Dynamic PersistentVolume provisioning.
- PersistentVolumeClaims.
- Replication between Kubernetes nodes.
- Volume snapshots where supported.

Verify disk identification carefully before formatting or mounting.

All three VMs share one physical Proxmox host. Node-level replication does not provide physical-host disaster recovery.

## 7. Execution rules

Be concise, direct and technically rigorous.

Prefer the smallest reasonable implementation over unnecessary frameworks.

Do not introduce Terraform/OpenTofu, Ansible, Omni or GitOps controllers without a justified need and my approval.

You may autonomously:
- Inspect local tools.
- Perform read-only SSH diagnostics.
- Read remote configuration.
- Consult official documentation.
- Download images into local staging directories.
- Write project files, scripts and documentation.
- Validate local configurations.

**Explicit approval is mandatory before:**
- Stopping, deleting, modifying or recreating VMs.
- Installing packages or changing configuration on the bastion.
- Modifying Proxmox configuration.
- Changing any remote networking or storage.
- Uninstalling the existing Kubernetes cluster.
- Applying configurations to Talos or Kubernetes.
- Running disruptive or destructive remote commands.

Before destroying existing VMs, verify backups and document a realistic restoration procedure.

Never infer authorization from the availability of SSH or root access.

## 8. Working methodology

Proceed incrementally.

For each step:
1. Verify what is already known.
2. Identify missing information.
3. Propose the next concrete operation.
4. Request approval when necessary.
5. Execute and verify.
6. Document only relevant findings.

Do not invent command output, assume success or repeatedly redesign an already agreed architecture.

Ask concise questions rather than making avoidable assumptions.

## 9. Initial task

Start with **non-destructive preparation only**.

1. Read and validate the existing `config.yaml`.
2. Identify missing parameters required for deployment.
3. Check available local tools and SSH connectivity.
4. Inspect necessary Proxmox VM, networking and storage information.
5. Check the availability of VM backups.
6. Verify supported Talos, Kubernetes, Cilium and Longhorn versions.
7. Prepare the appropriate Talos Image Factory schematic and installation images.
8. Create only the minimal repository structure and documentation needed.
9. Report findings, blockers and one recommended next action.

Do not modify any remote system.

Stop and await my approval before proceeding.

**Success means a working, maintainable and reproducible Kubernetes laboratory—not an unnecessarily complicated infrastructure automation framework.**