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
- DNS des nœuds: `8.8.8.8` et `1.1.1.1`.
- Accès local à l'API: tunnel SSH `127.0.0.1:16443` vers la VIP, kubeconfig
  `~/.kube/ovh-talos` (voir `scripts/ovh-talos-k8s.sh` et `ovk-kubectl.sh`).
- Sauvegardes: `scripts/backup-cluster.sh` (état Talos et etcd chiffrés avec
  `age`; snapshots etcd aussi dans `/root/ovh-talos-backups/etcd`).

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
- L'horloge du bastion doit être synchronisée (`timedatectl`:
  `System clock synchronized: yes`). `generate-on-bastion.sh` réémet le
  certificat client de `talosconfig` avec l'heure du bastion.
- Les règles du pare-feu du bastion sont produites par
  `scripts/bastion/fwinit_ovh-fw-k3s.sh`, déployé dans `/root/bin/`. Il vide
  puis reconstruit tout le jeu de règles et l'enregistre dans
  `/etc/iptables/rules.v4`. Le dépôt est public: ne jamais y écrire les IP
  publiques, qui vivent dans `/root/bin/fwinit_ovh-fw-k3s.env` sur le
  bastion. Modifier la version du dépôt, puis la déployer. Avant de le lancer,
  l'exécuter dans un espace réseau isolé (`unshare --net`, lignes
  `iptables-save` retirées) et comparer le résultat avec `iptables -S`.

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
- `talosctl: tls: expired certificate` après `generate-on-bastion.sh` (21
  octobre 2026): l'horloge du bastion avançait d'environ 60 s, donc le nouveau
  certificat client n'était pas encore valide pour les nœuds. Les règles NTP du
  pare-feu exigeaient source et destination égales à l'IP du bastion et
  bloquaient toute requête NTP sortante. Le `talosconfig` précédent a été
  restauré, les règles NTP corrigées dans `fwinit_ovh-fw-k3s.sh` (commentaire
  daté), et des serveurs NTP IPv4 fixés dans
  `/etc/systemd/timesyncd.conf.d/10-ipv4-ntp.conf`, car le bastion n'a pas de
  route IPv6.
- Les patches `talosctl patch machineconfig` ajoutent aux listes des documents
  multi-docs (par exemple `ResolverConfig.nameservers`) au lieu de les
  remplacer. Toujours passer par `--dry-run` et ne mettre dans le patch que les
  nouvelles entrées.
- `helm list --all` n'est pas accepté par le Helm installé. Utiliser
  `helm list`, `helm history` et `helm status`.
- Un service LoadBalancer sans backend peut annoncer sa VIP tout en présentant
  des ports filtrés. Le smoke test Ingress valide donc un backend réel et une
  requête HTTP complète.
