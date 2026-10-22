# vosclean custom upstream DNS (sourced by vosclean).
# Every LAN client gets 192.168.225.1 (dnsmasq) as its resolver; dnsmasq asks the
# operator servers listed in /etc/resolv.conf. We DNAT those upstream queries to the
# resolvers in $VC/etc/dns.conf, so local names and caching keep working.
DNS_CONF=$VC/etc/dns.conf
DNS_STATE=/tmp/vosclean-dns.sig
dns_sig() { echo "$DNS_ENABLE|$DNS_SERVERS|$(grep '^nameserver' /etc/resolv.conf | tr '\n' ' ')"; }
dns_flush() {
  conntrack -D -p udp --dport 53 >/dev/null 2>&1
  [ -s /var/run/data/dnsmasq.pid ] && kill -HUP $(cat /var/run/data/dnsmasq.pid) 2>/dev/null
  return 0
}
do_dns() {
  DNS_ENABLE=no; DNS_SERVERS=""
  [ -f $DNS_CONF ] && . $DNS_CONF
  iptables -t nat -N VOS_DNS 2>/dev/null
  iptables -t nat -F VOS_DNS
  if [ "$DNS_ENABLE" != yes ] || [ -z "$DNS_SERVERS" ]; then
    iptables -t nat -D OUTPUT -j VOS_DNS 2>/dev/null; iptables -t nat -X VOS_DNS 2>/dev/null
    rm -f $DNS_STATE; dns_flush; log "custom DNS off (operator DNS in use)"; return 0
  fi
  set -- $DNS_SERVERS; n=$#; i=0
  for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
    case $ns in *:*) continue ;; esac
    eval t=\${$((i % n + 1))}
    for p in udp tcp; do iptables -t nat -A VOS_DNS -d $ns -p $p --dport 53 -j DNAT --to-destination $t || return 1; done
    i=$((i + 1))
  done
  for p in udp tcp; do iptables -t nat -A VOS_DNS -o rmnet+ -p $p --dport 53 -j DNAT --to-destination $1 || return 1; done
  iptables -t nat -C OUTPUT -j VOS_DNS 2>/dev/null || iptables -t nat -I OUTPUT -j VOS_DNS || return 1
  dns_sig > $DNS_STATE; dns_flush; log "custom DNS on: $DNS_SERVERS"
}
dns_watch() { # re-apply after QCMAP flushes nat or the operator hands out new servers
  [ -f $DNS_CONF ] || return 0
  . $DNS_CONF; [ "$DNS_ENABLE" = yes ] || return 0
  if ! iptables -t nat -C OUTPUT -j VOS_DNS 2>/dev/null || [ "$(dns_sig)" != "$(cat $DNS_STATE 2>/dev/null)" ]; then do_dns; fi
}
