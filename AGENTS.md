# Instructions pour les agents

Ce dépôt décrit et exploite un cluster Kubernetes Talos à trois nœuds. Lire
`README.md` et `config.yaml` avant toute modification.

## Source de vérité et secrets

- `config.yaml` est la source de vérité pour les paramètres non secrets et les
  versions.
- `.generated/` est régénérable et ignoré par Git.
- Les secrets Talos, configurations machine finales, `talosconfig` et
  `kubeconfig` vivent uniquement sur le bastion dans
  `/root/ovh-talos-state`.
- Ne jamais lire, afficher, copier dans le dépôt ou committer ces fichiers
  sensibles.
- Les rendus locaux doivent rester non secrets. La PKI est générée sur le
  bastion par `generate-on-bastion.sh`.

## Architecture de référence

- Trois VM Proxmox sont à la fois control planes et workers.
- Talos `v1.14.4`, Kubernetes `v1.36.5`.
- Nœuds: `ovh-gok8sm01` à `03`, IP `192.168.50.61` à `.63`.
- VIP API Kubernetes: `192.168.50.241`.
- Cilium `1.20.3`, sans kube-proxy, sur `ens18`.
- VIP Ingress Cilium annoncée en L2: `192.168.50.240`.
- Longhorn `1.13.0`, moteur v1, trois réplicas.
- Chaque nœud réserve `/dev/sdb` au volume Talos `u-longhorn`, monté dans
  `/var/mnt/longhorn`.
- Snapshot-controller `v8.6.0`, deux réplicas, uniquement les trois API CSI
  snapshot standards. Les VolumeGroupSnapshots ne sont pas installés.
- Bastion/pare-feu: `ovh-fw-k3s`, passerelle interne `192.168.50.2`.

Cette référence correspond au déploiement validé le 21 octobre 2026. Toujours
contrôler l'état réel avant de conclure qu'elle est encore exacte.

## Invariants importants

- `cluster.allow_workloads_on_controlplanes: true` doit supprimer durablement
  le taint `node-role.kubernetes.io/control-plane:NoSchedule`.
- Le patch de suppression du taint appartient aux patches de chaque nœud. Il ne
  doit pas être placé dans `common.yaml`: la suppression échoue si la clé n'est
  pas encore présente dans le document commun.
- Ne pas ajouter `machine.kubelet.extraMounts` pour `/var/mnt`: Talos 1.14
  l'expose déjà au kubelet.
- Le namespace `longhorn-system` doit conserver le niveau Pod Security
  `privileged`.
- Cilium est l'unique CNI et remplace kube-proxy. Ne pas activer Flannel ou
  kube-proxy dans Talos.
- Le snapshot-controller doit rester aligné avec la version du CSI snapshotter
  Longhorn et son archive source doit être vérifiée par SHA-256.
- Les outils du bastion doivent être pris dans `/usr/local/bin`. `/root/bin`
  contient historiquement d'anciens binaires `kubectl` et `helm`.
- Le pare-feu doit avoir `net.ipv4.ip_forward=1`. Sans cela, les paquets DNS des
  nœuds arrivent sur `ens19` mais ne sont ni SNATés ni transmis vers Internet.
- Le réglage persistant actuellement utilisé est
  `/etc/sysctl.d/99-ovh-fw-k3s-forward.conf`.

## Discipline d'intervention

1. Exécuter `scripts/check-static.sh` après toute modification du rendu ou des
   scripts.
2. Ne jamais appliquer automatiquement une nouvelle machine configuration,
   amorcer etcd, mettre à niveau Helm ou modifier le pare-feu sans accord
   explicite de l'opérateur.
3. Générer les fichiers, les inspecter, puis séparer clairement le transfert et
   l'application au cluster.
4. Préférer `talosctl patch machineconfig --mode=no-reboot` lorsqu'un changement
   Talos compatible à chaud est explicitement approuvé.
5. Avant une opération disruptive, vérifier etcd, la disponibilité des trois
   nœuds et l'absence de volumes Longhorn dégradés.
6. Ne pas interpréter de vieux Events Kubernetes comme l'état courant. Comparer
   leur âge avec les pods, rollouts et ressources actuels.
7. En cas d'échec d'un smoke test, conserver son namespace pour diagnostic. Ne
   le supprimer qu'après inspection ou demande explicite.

## Validation

- Contrôles statiques locaux:

  ```bash
  scripts/check-static.sh
  ```

- Contrôles passifs du cluster via le bastion:

  ```bash
  scripts/run-infra-ci.sh
  ```

- Contrôles suivis des tests actifs réseau, stockage et snapshots:

  ```bash
  scripts/run-infra-ci.sh --smoke
  ```

Les scripts passifs ne doivent pas modifier le cluster. Les smoke tests créent
des namespaces `infra-ci-*`, les suppriment après succès et les conservent en
cas d'échec.

## Incidents déjà rencontrés

- `ImagePullBackOff` Longhorn: le DNS Talos pointait correctement vers
  `8.8.8.8`, mais `net.ipv4.ip_forward` valait `0` sur le bastion. L'activation
  du forwarding a immédiatement fait progresser les compteurs SNAT et les
  téléchargements.
- Pods Longhorn `Pending`: les trois nœuds avaient récupéré le taint control
  plane. Le taint a été retiré puis la correction a été persistée dans les
  configurations Talos rendues.
- `helm list --all` n'est pas accepté par le Helm installé. Utiliser
  `helm list`, `helm history` et `helm status`.
- Un service LoadBalancer sans backend peut annoncer sa VIP tout en présentant
  des ports filtrés. Le smoke test Ingress valide donc un backend réel et une
  requête HTTP complète.
