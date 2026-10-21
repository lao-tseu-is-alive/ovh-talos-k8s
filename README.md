# ovh-talos-k8s

Déploiement reproductible d'un cluster Kubernetes Talos à trois nœuds sur
Proxmox, avec Cilium, Ingress L2, Longhorn et snapshots CSI.

Le dépôt ne contient que la configuration non secrète et les générateurs. La
PKI Talos, les configurations machine finales et les kubeconfigs restent sur le
bastion d'administration.

## État validé

La plateforme suivante a été installée et testée le 21 octobre 2026:

| Composant | Version ou valeur |
|---|---|
| Talos | `v1.14.4` |
| Kubernetes | `v1.36.5` |
| Cilium / Hubble / Ingress | `1.20.3` |
| Longhorn | `1.13.0`, moteur v1, trois réplicas |
| Snapshot controller | `v8.6.0`, deux réplicas |
| Nœuds | `ovh-gok8sm01` à `03`, `192.168.50.61` à `.63` |
| VIP API Kubernetes | `192.168.50.241:6443` |
| VIP Ingress | `192.168.50.240:80/443` |
| Passerelle et bastion | `ovh-fw-k3s`, `192.168.50.2` |
| DNS des nœuds | `8.8.8.8`, `1.1.1.1` |
| Réseau pods | `10.244.0.0/16` |
| Réseau services | `10.96.0.0/12` |

Les validations réalisées couvrent:

- quorum etcd et API Kubernetes;
- trafic pod-à-pod et Service entre les trois nœuds;
- DNS CoreDNS;
- Ingress Cilium via la VIP L2;
- création d'un PVC Longhorn, écriture sur un nœud puis réattachement et lecture
  sur un autre;
- création d'un snapshot CSI, restauration dans un nouveau PVC et lecture sur
  un autre nœud;
- nettoyage complet des ressources temporaires.

## Architecture

Les trois VM sont simultanément control planes et workers. Le taint Kubernetes
`node-role.kubernetes.io/control-plane:NoSchedule` est donc supprimé dans la
configuration Talos persistante.

Chaque VM possède:

- `/dev/sda`: disque système Talos;
- `/dev/sdb`: disque dédié au `UserVolumeConfig` Talos `u-longhorn`, formaté en
  XFS et exposé dans `/var/mnt/longhorn`;
- `ens18`: interface privée du cluster.

Cilium est l'unique CNI, remplace kube-proxy et annonce la VIP Ingress en L2.
La VIP de l'API Kubernetes est portée par Talos. Le bastion assure le routage et
le SNAT du réseau privé vers Internet.

## Organisation du dépôt

```text
.
├── AGENTS.md                 consignes et invariants pour les futurs agents
├── CLAUDE.md                 renvoi vers AGENTS.md
├── config.yaml               source de vérité non secrète
├── scripts/
│   ├── render_talos.py       rendu des patches Talos non secrets
│   ├── render_addons.py      rendu Cilium, Longhorn et snapshot-controller
│   ├── check-static.sh       validation locale du dépôt et des rendus
│   ├── run-infra-ci.sh       exécution distante des contrôles via SSH
│   ├── backup-cluster.sh     sauvegardes chiffrées de l'état Talos et d'etcd
│   ├── ovh-talos-k8s.sh      tunnel SSH et kubeconfig local vers l'API
│   ├── ovk-kubectl.sh        kubectl local via le tunnel
│   ├── bastion/              script de pare-feu du bastion (IP publiques hors Git)
│   └── infra/
│       ├── check-all.sh      orchestrateur passif ou actif
│       ├── check-*.sh        contrôles passifs par composant
│       ├── smoke-*.sh        tests actifs temporaires
│       └── lib/common.sh     fonctions et chemins communs
└── .generated/               rendus locaux ignorés par Git
```

## Sécurité et fichiers sensibles

Les éléments suivants ne doivent jamais entrer dans Git:

- `secrets.yaml`;
- `talosconfig`;
- `kubeconfig`;
- les fichiers `controlplane-*.yaml` générés avec la PKI;
- tout contenu de `/root/ovh-talos-state`.

Ils sont créés sur le bastion dans `/root/ovh-talos-state`, avec les permissions
`0700` pour le répertoire et `0600` pour les fichiers. Les rendus locaux dans
`.generated/` ne contiennent pas de secrets mais restent ignorés pour éviter la
dérive entre sources et artefacts.

## Prérequis

Sur la station de travail:

- Python 3;
- `uv` ou Python avec PyYAML;
- accès SSH au bastion sous le nom défini dans `config.yaml`;
- `scp`, `ssh`, `tar`;
- `age` pour `scripts/backup-cluster.sh`;
- `/usr/local/bin/kubectl-1.36.5` et `~/.kube/ovh-talos` pour l'accès
  kubectl local via le tunnel SSH.

Sur le bastion:

- `talosctl v1.14.4`;
- `/usr/local/bin/kubectl v1.36.5`;
- `/usr/local/bin/helm v4.3.1`;
- `curl`, `sha256sum`, `tar`.

Toujours placer `/usr/local/bin` avant `/root/bin`: ce dernier a déjà contenu
des versions obsolètes de `kubectl` et Helm.

## Validation locale

Après toute modification de `config.yaml`, des générateurs ou des scripts:

```bash
scripts/check-static.sh
```

Cette commande:

- valide `config.yaml`;
- rend Talos et les add-ons dans un répertoire temporaire;
- vérifie la présence des artefacts attendus;
- compile les scripts Python;
- exécute `bash -n` sur tous les scripts;
- lance ShellCheck s'il est installé;
- vérifie que les API VolumeGroupSnapshot ne sont pas introduites;
- exécute `git diff --check`.

## Génération de Talos

Sur la station de travail:

```bash
uv run --with 'PyYAML==6.0.3' python scripts/render_talos.py \
  --config config.yaml \
  --output .generated/talos
```

Le rendu contient `common.yaml`, un patch par VM et
`generate-on-bastion.sh`. Il ne contient aucun secret.

Transfert et génération de la PKI sur le bastion:

```bash
scp -rp .generated/talos/. ovh-fw-k3s:/root/ovh-talos-rendered/

ssh ovh-fw-k3s '
chmod 0700 /root/ovh-talos-rendered \
  /root/ovh-talos-rendered/generate-on-bastion.sh
/root/ovh-talos-rendered/generate-on-bastion.sh /root/ovh-talos-state
'
```

Le générateur réutilise `secrets.yaml` s'il existe, produit les trois
configurations finales et les valide en mode `metal --strict`. Il ne faut pas
remplacer les secrets d'un cluster existant.

Il réémet aussi le certificat client de `talosconfig`, daté avec l'horloge du
bastion. Vérifier d'abord `timedatectl` (`System clock synchronized: yes`) et
conserver une copie du `talosconfig` en service: une horloge en avance produit
un certificat refusé par les nœuds (`tls: expired certificate`).

### Application et bootstrap

L'application d'une configuration Talos est une opération séparée et doit être
explicitement approuvée. Pour une première installation, appliquer chaque
configuration à l'adresse correspondante avec `talosctl apply-config
--insecure`. Amorcer ensuite etcd une seule fois, sur un seul nœud:

```bash
export TALOSCONFIG=/root/ovh-talos-state/talosconfig
talosctl bootstrap \
  --endpoints 192.168.50.61 \
  --nodes 192.168.50.61
```

Ne jamais relancer `bootstrap` sur un cluster déjà amorcé.

Le kubeconfig est ensuite extrait vers le bastion:

```bash
talosctl kubeconfig /root/ovh-talos-state/kubeconfig \
  --endpoints 192.168.50.61 \
  --nodes 192.168.50.61 \
  --merge=false --force
chmod 0600 /root/ovh-talos-state/kubeconfig
```

## Génération et installation des add-ons

Sur la station de travail:

```bash
uv run --with 'PyYAML==6.0.3' python scripts/render_addons.py \
  --config config.yaml \
  --output .generated/addons
```

Les installateurs sont volontairement séparés. L'ordre est:

1. Cilium;
2. Longhorn;
3. snapshot-controller et `VolumeSnapshotClass` Longhorn.

Copier le bundle sur le bastion:

```bash
scp -rp .generated/addons/. ovh-fw-k3s:/root/ovh-talos-addons/
ssh ovh-fw-k3s \
  'chmod 0700 /root/ovh-talos-addons /root/ovh-talos-addons/*.sh'
```

Puis, après validation explicite de chaque étape:

```bash
ssh ovh-fw-k3s '
export KUBECONFIG=/root/ovh-talos-state/kubeconfig
/root/ovh-talos-addons/install-cilium.sh
/root/ovh-talos-addons/install-longhorn.sh
/root/ovh-talos-addons/install-snapshot-controller.sh
'
```

Les archives Longhorn et external-snapshotter sont épinglées et vérifiées par
SHA-256 avant utilisation.

### Points particuliers Longhorn

- Le namespace `longhorn-system` est explicitement marqué Pod Security
  `privileged`, exigence normale pour Longhorn.
- Talos 1.14 expose déjà `/var/mnt` au kubelet. Ne pas ajouter
  `machine.kubelet.extraMounts`.
- Les warnings Pod Security affichés lors d'une installation antérieure ne
  prouvent pas un échec: contrôler le statut actuel des pods et des rollouts.
- Un snapshot Longhorn de type `snap` protège contre une erreur logique locale,
  mais ne remplace pas une sauvegarde externalisée hors du cluster.

## Sauvegardes Talos et etcd

`scripts/backup-cluster.sh` sauvegarde, depuis la station de travail:

- `state`: une archive de `/root/ovh-talos-state` (PKI Talos, `talosconfig`,
  `kubeconfig`), indispensable pour administrer ou reconstruire le cluster;
- `etcd`: un snapshot etcd conservé dans `/root/ovh-talos-backups/etcd` sur le
  bastion, puis copié localement.

Les copies locales sont chiffrées avec `age` dans `~/backups/ovh-talos`. Les
sept dernières de chaque type sont conservées, sur le bastion comme en local.
La clé privée age doit être stockée hors de cette station, par exemple dans un
gestionnaire de mots de passe.

```bash
age-keygen -o ~/.config/age/ovh-talos.key    # une seule fois
export AGE_RECIPIENT=age1...                 # clé publique affichée
scripts/backup-cluster.sh                    # state + etcd
```

Restauration d'etcd: déchiffrer le snapshot avec
`age --decrypt --identity <clé> etcd-<date>.db.age > etcd.db`, puis suivre la
procédure Talos `talosctl bootstrap --recover-from=./etcd.db`.

## CI d'infrastructure

### Contrôles passifs

Depuis la station de travail:

```bash
scripts/run-infra-ci.sh
```

Le bundle de contrôle est transmis dans un répertoire temporaire du bastion,
exécuté puis supprimé. Aucun script n'est installé durablement sur le bastion.

Contrôles effectués:

| Script | Vérifications |
|---|---|
| `check-bastion-network.sh` | forwarding IPv4 persistant, politique FORWARD et SNAT des nœuds |
| `check-talos.sh` | membres, etcd, résolveurs, volume `u-longhorn` |
| `check-kubernetes.sh` | `/readyz`, nœuds Ready, taints, pods non sains |
| `check-cilium.sh` | Helm, rollouts, agents, kube-proxy replacement, L2 et VIP |
| `check-longhorn.sh` | Helm, rollouts, nœuds/disques, StorageClass, volumes dégradés |
| `check-snapshots.sh` | CRD, contrôleur HA, `VolumeSnapshotClass` |

Pour un autre bastion:

```bash
scripts/run-infra-ci.sh root@nouveau-bastion
# ou
BASTION_HOST=root@nouveau-bastion scripts/run-infra-ci.sh
```

Les variables suivantes peuvent être définies localement; le lanceur les
transmet au bastion:

- chemins: `KUBECONFIG`, `TALOSCONFIG`, `KUBECTL`, `HELM`, `TALOSCTL`;
- topologie: `EXPECTED_NODE_COUNT`, `CILIUM_DEVICE`, `EXPECTED_API_VIP`,
  `EXPECTED_INGRESS_VIP`;
- bastion: `BASTION_EXTERNAL_INTERFACE`, `BASTION_INTERNAL_INTERFACE`,
  `FORWARDING_FILE`;
- comportement: `ALLOW_WORKLOADS_ON_CONTROLPLANES`,
  `SNAPSHOT_CONTROLLER_REPLICAS`.

### Smoke tests actifs

```bash
scripts/run-infra-ci.sh --smoke
```

Cette option ajoute:

| Script | Parcours testé |
|---|---|
| `smoke-network.sh` | trois pods répartis, DNS, Service, Ingress et VIP L2 |
| `smoke-longhorn.sh` | écriture, détachement, réattachement sur un autre nœud |
| `smoke-snapshot.sh` | snapshot CSI, nouveau PVC et restauration inter-nœuds |

Les tests utilisent des namespaces `infra-ci-*`. Ils les suppriment uniquement
après succès. En cas d'échec, les ressources sont conservées pour permettre:

```bash
kubectl get pods,events,pvc -n <namespace>
kubectl describe pod -n <namespace> <pod>
```

Après diagnostic, leur suppression est manuelle:

```bash
kubectl delete namespace <namespace> --wait=true
```

## Exploitation courante

Variables recommandées sur le bastion:

```bash
export PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export TALOSCONFIG=/root/ovh-talos-state/talosconfig
export KUBECONFIG=/root/ovh-talos-state/kubeconfig
```

Commandes utiles:

```bash
talosctl get members
talosctl service etcd
kubectl get nodes -o wide
kubectl get pods -A -o wide
helm status cilium -n kube-system
helm status longhorn -n longhorn-system
kubectl get nodes.longhorn.io -n longhorn-system
kubectl get volumes.longhorn.io -n longhorn-system
kubectl get volumesnapshots -A
kubectl get volumesnapshotcontents
```

Avant une maintenance disruptive, exécuter au minimum la CI passive et vérifier
qu'aucun volume Longhorn n'est `degraded` ou `faulted`.

### Accès kubectl depuis la station de travail

L'API n'est pas exposée sur Internet. Elle est jointe par un tunnel SSH via le
bastion, avec une copie locale du kubeconfig dans `~/.kube/ovh-talos` pointant
vers `https://127.0.0.1:16443` et `tls-server-name: ovh-talos-k8s` (nom présent
dans le certificat de l'API).

```bash
scripts/ovh-talos-k8s.sh          # kubeconfig local, tunnel, vérification
scripts/ovk-kubectl.sh get nodes  # kubectl avec ~/.kube/ovh-talos
```

`ovk-kubectl.sh` échoue immédiatement si aucun tunnel n'écoute sur
`127.0.0.1:16443` et affiche la commande `ssh` à lancer.

## Dépendance réseau du bastion

Le trafic sortant des nœuds dépend du routage IPv4 et des règles SNAT du
bastion. Le forwarding doit être actif et persistant:

```bash
sysctl net.ipv4.ip_forward
cat /etc/sysctl.d/99-ovh-fw-k3s-forward.conf
iptables -t nat -nvL POSTROUTING --line-numbers
```

Valeur attendue:

```text
net.ipv4.ip_forward = 1
```

Symptôme connu si le forwarding repasse à zéro: les journaux Talos montrent des
timeouts vers `8.8.8.8:53`, les requêtes sont visibles en entrée sur `ens19`, les
compteurs SNAT restent à zéro et les pods passent en `ImagePullBackOff`.

Les DNS `8.8.8.8` et `1.1.1.1` sont actuellement configurés dans Talos. Dans un
autre contexte, adapter `network.nameservers` à des résolveurs réellement
joignables depuis le réseau des nœuds. Pour modifier cette liste sur un
cluster en service, un patch `talosctl patch machineconfig` ajoute des entrées
sans remplacer la liste: ne mettre que les nouvelles entrées et toujours
valider par `--dry-run`.

### Pare-feu du bastion

`scripts/bastion/fwinit_ovh-fw-k3s.sh` est la source du pare-feu, déployée dans
`/root/bin/` sur le bastion. Il vide puis reconstruit toutes les règles et les
enregistre dans `/etc/iptables/rules.v4`. Le dépôt étant public, les IP
publiques (sources SSH autorisées, IP externe) sont lues dans
`/root/bin/fwinit_ovh-fw-k3s.env`, présent uniquement sur le bastion (`0600`,
ignoré par Git). Modèle: `scripts/bastion/fwinit_ovh-fw-k3s.env.example`.

Avant de lancer une nouvelle version, l'essayer à blanc dans un espace réseau
isolé et comparer avec les règles en service:

```bash
grep -vE '^(iptables-save|ip6tables-save) >' fwinit_ovh-fw-k3s.sh > /tmp/dry.sh
unshare --net sh -c 'FWINIT_ENV=/root/bin/fwinit_ovh-fw-k3s.env sh /tmp/dry.sh \
  >/dev/null; iptables -S; iptables -t nat -S' > /tmp/dry.rules
{ iptables -S; iptables -t nat -S; } | diff - /tmp/dry.rules
```

### Horloge du bastion

Le bastion se synchronise avec `systemd-timesyncd` sur des serveurs NTP IPv4
fixés dans `/etc/systemd/timesyncd.conf.d/10-ipv4-ntp.conf`, car il n'a pas de
route IPv6. Les règles NTP sortantes sont dans `fwinit_ovh-fw-k3s.sh`.

```bash
timedatectl | grep synchronized
timedatectl timesync-status
```

## Mise à niveau

Pour Talos, Kubernetes, Cilium, Longhorn ou external-snapshotter:

1. vérifier la matrice de compatibilité officielle;
2. modifier les versions et sommes SHA-256 dans `config.yaml`;
3. exécuter `scripts/check-static.sh`;
4. inspecter le diff des rendus;
5. lancer `scripts/backup-cluster.sh` et sauvegarder les données applicatives
   hors cluster;
6. appliquer une stratégie de mise à niveau composant par composant;
7. exécuter la CI passive puis `scripts/run-infra-ci.sh --smoke`.

Ne pas déduire qu'une mise à niveau est sûre uniquement parce que le rendu YAML
est valide.

## Limites actuelles

- Le dépôt ne crée pas les VM Proxmox; il documente leurs paramètres dans
  `config.yaml`.
- Le script de pare-feu du bastion est versionné dans `scripts/bastion/`, mais
  son déploiement sur le bastion reste manuel.
- L'accès Talos depuis Internet par DNAT n'est pas encore configuré.
- Il n'existe pas encore de cible de sauvegarde Longhorn externe.
- Les sauvegardes Talos et etcd sont lancées à la main; aucune planification
  n'est installée.
- La CI est lancée à la demande depuis la station de travail; aucun ordonnanceur
  périodique n'est installé.
