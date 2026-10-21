#!/bin/sh
# Script de pare-feu du bastion ovh-fw-k3s: vide puis reconstruit toutes les
# regles iptables, puis les enregistre dans /etc/iptables/rules.v4 (rechargees
# au demarrage par netfilter-persistent).
#
# 2026-10-21 : script importe dans le depot ovh-talos-k8s. Les adresses IP
# publiques (sources SSH autorisees, IP externe du bastion) ne sont pas
# publiees: elles sont lues dans un fichier env prive, non versionne, place a
# cote du script (voir fwinit_ovh-fw-k3s.env.example) ou designe par FWINIT_ENV.
# Avant toute execution, faire un essai a blanc dans un espace reseau isole
# (voir AGENTS.md).

FWINIT_ENV=${FWINIT_ENV:-$(dirname "$0")/fwinit_ovh-fw-k3s.env}
if [ ! -r "$FWINIT_ENV" ]; then
  echo "ERREUR: fichier env introuvable: $FWINIT_ENV" >&2
  exit 1
fi
. "$FWINIT_ENV"
for var in TRUSTEDIP01 TRUSTEDIP02 TRUSTEDIP03 BASTION01 CAMPTOCAMP EXTIP; do
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    echo "ERREUR: $var doit etre defini dans $FWINIT_ENV" >&2
    exit 1
  fi
done

## adresses IP interne des noeuds k3s interne sur vmbr1
IPK3S01="192.168.50.61"
IPK3S02="192.168.50.62"
IPK3S03="192.168.50.63"

IPGEO="192.168.50.50"
IPCARTO2026="192.168.50.152"

#####THIS IS THE FIREWALL SCRIPT FOR allows to go to 
# GREEN Internal Interface, Network, and IP
INTIF='ens19'
INTIP='192.168.50.2'
INTNET="192.168.50.0/24"
# RED if"EXTERNAL" Interface for RECOLTE
EXTIF='ens18'
# EXTIP: IP publique du bastion, definie dans $FWINIT_ENV

echo "### DEBUT Configuration FIREWALL pour FW03GOCARTO"
echo "INTERNAL IF = $INTIF and INTERNAL IP addr= $INTIP"
echo "EXTERNAL IF = ${EXTIF} and EXTERNAL IP addr= $EXTIP"
UNIVERSE="0.0.0.0/0"
echo "Loading required stateful/NAT kernel modules..."
/sbin/depmod -a
/sbin/modprobe ip_tables
/sbin/modprobe nf_conntrack
/sbin/modprobe iptable_nat
echo "    Enabling IP forwarding..."
echo "1" > /proc/sys/net/ipv4/ip_forward
echo "#     Clear any existing rules and setting default policy to DROP for OUTPUT"
iptables -F
# par default on bloque tous les INPUT
iptables -P INPUT DROP
iptables -F INPUT
# par default on bloque tous les OUTPUT
iptables -P OUTPUT DROP
# la ligne ci-dessous fait le contraire c.a.dire par default on accepte tous les OUTPUT
#iptables -P OUTPUT ACCEPT
iptables -F OUTPUT
# par default on bloque tous les FORWARD a priori il devrait pas trop y en avoir car on est plus en virtual bridge
#iptables -P FORWARD DROP
#la ligne ci-dessous ouvre les forward par defaut
iptables -P FORWARD ACCEPT
iptables -F FORWARD
iptables -F -t nat
# Delete all User-specified chains
iptables -X
# Reset all IPTABLES counters
iptables -Z
echo -e "     - Loading iptables rulesets"
#######################################################################
echo "# all loopback interfaces trafic is valid if coming from lo interface"
iptables -A INPUT -i lo -s localhost -j ACCEPT
iptables -A OUTPUT -o lo -s localhost -j ACCEPT
iptables -A FORWARD -i lo -s localhost -j ACCEPT

echo "# local interface, local machines, going everywhere is valid"
iptables -A INPUT -i $INTIF -s $INTNET -d $UNIVERSE -j ACCEPT
iptables -A OUTPUT -s $INTNET -d $UNIVERSE -j ACCEPT
iptables -A FORWARD -i $INTIF -o $INTIF -j ACCEPT
# internal network can be forwarded outside
# iptables -A FORWARD -i $INTIF -o $EXTIF -j ACCEPT
echo "################################################################################"
echo "# allow all http trafic on port 80 to go out and back"
#iptables -A OUTPUT -p tcp --dport 80  -m state --state NEW,ESTABLISHED -j ACCEPT
#iptables -A INPUT -p tcp  --sport 80  -m state --state ESTABLISHED -j ACCEPT
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp  --sport 80 -j ACCEPT
echo "# allow all http trafic on port 80 to go out and back"
iptables -A INPUT  -p tcp --dport 80 -j ACCEPT
iptables -A OUTPUT -p tcp --sport 80 -j ACCEPT

echo "################################################################################"
echo "# allow all https trafic on port 443 to go out and back"
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT  -p tcp --sport 443 -j ACCEPT
echo "# allow all https trafic on port 443 to go in and out"
iptables -A INPUT  -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -p tcp --sport 443 -j ACCEPT

echo "################################################################################"
echo "# SNAT postrouting pour permettre a ovh-gok8sm01 [${IPK3S01}] de sortir"
iptables -t nat -A POSTROUTING -s ${IPK3S01} -o ${EXTIF} -j SNAT --to-source $EXTIP
echo "# SNAT postrouting pour permettre a ovh-gok8sm02 [${IPK3S02}] de sortir"
iptables -t nat -A POSTROUTING -s ${IPK3S02} -o ${EXTIF} -j SNAT --to-source $EXTIP
echo "# SNAT postrouting pour permettre a ovh-gok8sm03 [${IPK3S03}] de sortir"
iptables -t nat -A POSTROUTING -s ${IPK3S03} -o ${EXTIF} -j SNAT --to-source $EXTIP
echo "# SNAT postrouting pour permettre a ovh-geo-data [${IPGEO}] de sortir"
iptables -t nat -A POSTROUTING -s ${IPGEO} -o ${EXTIF} -j SNAT --to-source $EXTIP
echo "# SNAT postrouting pour permettre a ovh-cartotest-2026 [${IPCARTO2026}] de sortir"
iptables -t nat -A POSTROUTING -s ${IPCARTO2026} -o ${EXTIF} -j SNAT --to-source $EXTIP

## for ovh-gok8s-template
iptables -t nat -A POSTROUTING -s 192.168.50.60 -o ${EXTIF} -j SNAT --to-source $EXTIP

echo "# Allow DNS query to go in and out via UDP"
iptables -A INPUT  -i ${EXTIF} -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -o ${EXTIF} -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -i lo -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -o lo -p udp --sport 53 -j ACCEPT
iptables -A INPUT  -i ${EXTIF} -p tcp --sport 53 -j ACCEPT
iptables -A OUTPUT -o ${EXTIF} -p tcp --dport 53 -j ACCEPT

#iptables -A OUTPUT -p udp -o ${EXTIF} --dport 53 --sport 1024:65535 -m state --state NEW,ESTABLISHED -j ACCEPT
#iptables -A INPUT -p udp -i ${EXTIF} --sport 53 --dport 1024:65535 -m state --state ESTABLISHED -j ACCEPT
#iptables -A FORWARD -p udp -o ${EXTIF} --dport 53 --sport 1024:65535 -m state --state NEW,ESTABLISHED -j ACCEPT
#iptables -A FORWARD -p udp -o ${EXTIF} --sport 53 --dport 1024:65535 -m state --state ESTABLISHED -j ACCEPT
iptables -A FORWARD -p udp -m udp --sport 53 -s 213.186.33.99 -j ACCEPT
iptables -A FORWARD -p udp -m udp --sport 53 -s 8.8.8.8 -j ACCEPT


echo "# Allow ssh coming from  my trusted ip1 $TRUSTEDIP01"
iptables -A INPUT -p tcp -s $TRUSTEDIP01 -i ${EXTIF} --sport 513:65535 --dport 22 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -p tcp -d $TRUSTEDIP01 -o ${EXTIF} --sport 22 --dport 513:65535 -m state --state ESTABLISHED -j ACCEPT
iptables -t nat -A PREROUTING  -s ${TRUSTEDIP01} -i ${EXTIF} -p tcp -d $EXTIP --dport 50 -j DNAT --to-destination ${IPGEO}:22
echo "# Allow ssh connexion to carto server ${IPK3S01}  from my trusted ip $TRUSTEDIP01 WITH PORT 61"
iptables -t nat -A PREROUTING  -s ${TRUSTEDIP01} -i ${EXTIF} -p tcp -d $EXTIP --dport 61 -j DNAT --to-destination ${IPK3S01}:22
iptables -t nat -A PREROUTING  -s ${TRUSTEDIP01} -i ${EXTIF} -p tcp -d $EXTIP --dport 62 -j DNAT --to-destination ${IPK3S02}:22
iptables -t nat -A PREROUTING  -s ${TRUSTEDIP01} -i ${EXTIF} -p tcp -d $EXTIP --dport 63 -j DNAT --to-destination ${IPK3S03}:22
iptables -t nat -A PREROUTING  -s ${TRUSTEDIP01} -i ${EXTIF} -p tcp -d $EXTIP --dport 152 -j DNAT --to-destination ${IPCARTO2026}:22

echo "# Allow ssh coming from  my trusted ip2 $TRUSTEDIP02"
iptables -A INPUT -p tcp -s $TRUSTEDIP02 -i ${EXTIF} --sport 513:65535 --dport 22 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -p tcp -d $TRUSTEDIP02 -o ${EXTIF} --sport 22 --dport 513:65535 -m state --state ESTABLISHED -j ACCEPT
echo "# Allow ssh connexion to carto server ${IPK3S01}  from my trusted ip $TRUSTEDIP02 WITH PORT 61"
iptables -t nat -A PREROUTING  -s ${TRUSTEDIP02} -i ${EXTIF} -p tcp -d $EXTIP --dport 61 -j DNAT --to-destination ${IPK3S01}:22

echo "# Allow ssh coming from  my trusted ip3 $TRUSTEDIP03"
iptables -A INPUT -p tcp -s $TRUSTEDIP03 -i ${EXTIF} --sport 513:65535 --dport 22 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -p tcp -d $TRUSTEDIP03 -o ${EXTIF} --sport 22 --dport 513:65535 -m state --state ESTABLISHED -j ACCEPT
echo "# Allow ssh connexion to carto server ${IPK3S01}  from my trusted ip $TRUSTEDIP03 WITH PORT 61"
iptables -t nat -A PREROUTING  -s ${TRUSTEDIP03} -i ${EXTIF} -p tcp -d $EXTIP --dport 61 -j DNAT --to-destination ${IPK3S01}:22

echo "# Allow all trafic coming from  my BASTION ip $BASTION01"
iptables -A INPUT -p tcp -s $BASTION01 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -p tcp -d $BASTION01 -m state --state ESTABLISHED -j ACCEPT
echo "# Allow node_exporter prometheus scraping coming from  my BASTION ip $BASTION01"
iptables -A INPUT -p tcp -s $BASTION01 --sport 513:65535 --dport 9100 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -p tcp -d $BASTION01 --sport 9100 --dport 513:65535 -m state --state ESTABLISHED -j ACCEPT



echo "# Allow ssh connexion to ovh-gok8sm01 server ${IPK3S01}   from BASTION $BASTION01 WITH PORT 61"
iptables -t nat -A PREROUTING  -s ${BASTION01} -i ${EXTIF} -p tcp -d $EXTIP --dport 61 -j DNAT --to-destination ${IPK3S01}:22
iptables -t nat -A PREROUTING  -s ${BASTION01} -i ${EXTIF} -p tcp -d $EXTIP --dport 62 -j DNAT --to-destination ${IPK3S02}:22
iptables -t nat -A PREROUTING  -s ${BASTION01} -i ${EXTIF} -p tcp -d $EXTIP --dport 63 -j DNAT --to-destination ${IPK3S03}:22
echo "# Allow ssh connexion to ovh-geo-data server 192.168.50.50  from BASTION $BASTION01 WITH PORT 50"
iptables -t nat -A PREROUTING  -s ${BASTION01} -i ${EXTIF} -p tcp -d $EXTIP --dport 50 -j DNAT --to-destination ${IPGEO}:22
echo "# Allow ssh connexion to ovh-cartotest-2026 server 192.168.50.152 from BASTION $BASTION01 WITH PORT 152"
iptables -t nat -A PREROUTING  -s ${BASTION01} -i ${EXTIF} -p tcp -d $EXTIP --dport 152 -j DNAT --to-destination ${IPCARTO2026}:22

# autoriser camptocamp a rentrer en ssh A DESACTIVER QUAND CONFIG TERMINEE 
iptables -t nat -A PREROUTING  -s ${CAMPTOCAMP} -i ${EXTIF} -p tcp -d $EXTIP --dport 152 -j DNAT --to-destination ${IPCARTO2026}:22

echo "# Allow prometheus to collect node exporter data"
iptables -t nat -A PREROUTING  -s ${BASTION01} -i ${EXTIF} -p tcp -d $EXTIP --dport 961 -j DNAT --to-destination ${IPK3S01}:9100
iptables -t nat -A PREROUTING  -s ${BASTION01} -i ${EXTIF} -p tcp -d $EXTIP --dport 962 -j DNAT --to-destination ${IPK3S02}:9100
iptables -t nat -A PREROUTING  -s ${BASTION01} -i ${EXTIF} -p tcp -d $EXTIP --dport 963 -j DNAT --to-destination ${IPK3S03}:9100
iptables -t nat -A PREROUTING  -s ${BASTION01} -i ${EXTIF} -p tcp -d $EXTIP --dport 950  -j DNAT --to-destination ${IPGEO}:9100
iptables -t nat -A PREROUTING  -s ${BASTION01} -i ${EXTIF} -p tcp -d $EXTIP --dport 950  -j DNAT --to-destination ${IPCARTO2026}:9100

echo "# allow NTP (network time protocol) queries to go in and out"
# 2026-10-21 : correction NTP. Les anciennes regles (commentees ci-dessous) exigeaient
# source ET destination = $EXTIP, donc seul le trafic du bastion vers lui-meme passait.
# systemd-timesyncd ne joignait jamais de serveur NTP et l horloge avait derive d environ
# 60 s, ce qui faisait rejeter les nouveaux certificats talosctl ("expired certificate").
# On autorise maintenant les requetes NTP sortantes sur $EXTIF et uniquement leurs reponses.
#iptables -A OUTPUT -p udp -s $EXTIP  --sport 123 -d $EXTIP  --dport 123 -j ACCEPT
#iptables -A INPUT -p udp -d $EXTIP   --sport 123 -s $EXTIP  --dport 123 -j ACCEPT
iptables -A OUTPUT -o $EXTIF -p udp -s $EXTIP --dport 123 -j ACCEPT
iptables -A INPUT -i $EXTIF -p udp -d $EXTIP --sport 123 -m state --state ESTABLISHED -j ACCEPT

echo "# allow icmp ping incoming on internal IP $INTIP" 
iptables -A INPUT -p icmp --icmp-type 8 -s 0/0 -d $INTIP -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p icmp --icmp-type 0 -s $INTIP -d 0/0 -m state --state ESTABLISHED,RELATED -j ACCEPT
echo "# allow icmp ping incoming on external IP $EXTIP" 
iptables -A INPUT -p icmp --icmp-type 8 -s 0/0 -d $EXTIP -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p icmp --icmp-type 0 -s $EXTIP -d 0/0 -m state --state ESTABLISHED,RELATED -j ACCEPT

#iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT
#iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT

echo -e "    Firewall server rule loading complete\n\n"
#this 3 rules allow me to see what's going wrong with tcp protocol
iptables -A INPUT -p tcp -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "##DROPPED TCP INPUT -- "
iptables -A OUTPUT -p tcp -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "##DROPPED TCP OUTPUT --"
iptables -A INPUT -p udp -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "##DROPPED UDP INPUT --"
iptables -A OUTPUT -p udp -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "##DROPPED UDP OUTPUT --"
iptables -A FORWARD -p tcp -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "##DROPPED TCP FORWARD -- "
iptables -A FORWARD -p udp -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "##DROPPED UDP FORWARD -- "
echo " Now saving iptables rules in /etc/iptables/rules.v4 just in case you need it"
iptables-save > /etc/iptables/rules.v4 
ip6tables-save > /etc/iptables/rules.v6
