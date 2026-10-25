# vosclean custom upstream DNS (sourced by vosclean).
# Every LAN client gets 192.168.225.1 (dnsmasq) as its resolver; dnsmasq asks the
# operator servers listed in /etc/resolv.conf. We DNAT those upstream queries to the
# resolvers in $VC/etc/dns.conf, so local names and caching keep working.
#
# DNS_PROXY=yes (QManager's Ad Blocking / Encrypted DNS): the same queries are
# redirected to QManager's DNS proxy on 127.0.0.1:$DNS_PROXY_PORT instead. The
# proxy's own upstream sockets carry mark 0xca6d and are left alone. The redirect
# is only installed while QManager's heartbeat file is fresh; if QManager stops or
# hangs, `vosclean watch` drops back to the plain servers (or operator DNS) within
# about two minutes, so DNS never stays pointed at a dead proxy.
DNS_CONF=$VC/etc/dns.conf
DNS_STATE=/tmp/vosclean-dns.sig
DNS_ALIVE=/tmp/qmanager_dnsproxy.alive
DNS_MARK=0xca6d
dns_load() { DNS_ENABLE=no; DNS_SERVERS=""; DNS_PROXY=no; DNS_PROXY_PORT=5335; [ -f $DNS_CONF ] && . $DNS_CONF; }
dns_proxy_alive() {
  [ "$DNS_PROXY" = yes ] && [ -f $DNS_ALIVE ] || return 1
  age=$(( $(date +%s) - $(stat -c %Y $DNS_ALIVE 2>/dev/null || echo 0) ))
  [ $age -ge -90 ] && [ $age -lt 90 ] && netstat -lnu 2>/dev/null | grep -q "127.0.0.1:$DNS_PROXY_PORT "
}
dns_mode() { if dns_proxy_alive; then echo proxy; elif [ "$DNS_ENABLE" = yes ] && [ -n "$DNS_SERVERS" ]; then echo custom; else echo off; fi; }
dns_sig() { echo "$(dns_mode)|$DNS_SERVERS|$DNS_PROXY_PORT|$(grep '^nameserver' /etc/resolv.conf | tr '\n' ' ')"; }
dns_flush() {
  conntrack -D -p udp --dport 53 >/dev/null 2>&1
  [ -s /var/run/data/dnsmasq.pid ] && kill -HUP $(cat /var/run/data/dnsmasq.pid) 2>/dev/null
  return 0
}
do_dns() {
  dns_load
  mode=$(dns_mode)
  iptables -t nat -N VOS_DNS 2>/dev/null
  iptables -t nat -F VOS_DNS
  if [ $mode = off ]; then
    iptables -t nat -D OUTPUT -j VOS_DNS 2>/dev/null; iptables -t nat -X VOS_DNS 2>/dev/null
    rm -f $DNS_STATE; dns_flush
    if [ "$DNS_PROXY" = yes ]; then log "DNS proxy not running - operator DNS in use"; else log "custom DNS off (operator DNS in use)"; fi
    return 0
  fi
  if [ $mode = proxy ]; then
    for p in udp tcp; do iptables -t nat -A VOS_DNS -p $p --dport 53 -m mark --mark $DNS_MARK -j RETURN || return 1; done
    for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
      case $ns in *:*) continue ;; esac
      for p in udp tcp; do iptables -t nat -A VOS_DNS -d $ns -p $p --dport 53 -j REDIRECT --to-ports $DNS_PROXY_PORT || return 1; done
    done
    for p in udp tcp; do iptables -t nat -A VOS_DNS -o rmnet+ -p $p --dport 53 -j REDIRECT --to-ports $DNS_PROXY_PORT || return 1; done
  else
    set -- $DNS_SERVERS; n=$#; i=0
    for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
      case $ns in *:*) continue ;; esac
      eval t=\${$((i % n + 1))}
      for p in udp tcp; do iptables -t nat -A VOS_DNS -d $ns -p $p --dport 53 -j DNAT --to-destination $t || return 1; done
      i=$((i + 1))
    done
    for p in udp tcp; do iptables -t nat -A VOS_DNS -o rmnet+ -p $p --dport 53 -j DNAT --to-destination $1 || return 1; done
  fi
  iptables -t nat -C OUTPUT -j VOS_DNS 2>/dev/null || iptables -t nat -I OUTPUT -j VOS_DNS || return 1
  dns_sig > $DNS_STATE; dns_flush
  if [ $mode = proxy ]; then log "DNS via QManager proxy (127.0.0.1:$DNS_PROXY_PORT)"; else log "custom DNS on: $DNS_SERVERS"; fi
}
dns_watch() { # re-apply after QCMAP flushes nat, the operator hands out new servers, or the proxy comes/goes
  [ -f $DNS_CONF ] || return 0
  dns_load
  [ "$DNS_ENABLE" = yes ] || [ "$DNS_PROXY" = yes ] || return 0
  if [ "$(dns_mode)" != off ] && ! iptables -t nat -C OUTPUT -j VOS_DNS 2>/dev/null; then do_dns; return; fi
  [ "$(dns_sig)" != "$(cat $DNS_STATE 2>/dev/null)" ] && do_dns
  return 0
}
dns_status() {
  dns_load
  case $(dns_mode) in
    proxy) echo "custom DNS: QManager proxy (ad blocking / encrypted DNS), fallback ${DNS_SERVERS:-operator DNS}" ;;
    custom) echo "custom DNS: on ($DNS_SERVERS)" ;;
    *) if [ "$DNS_PROXY" = yes ]; then echo "custom DNS: QManager proxy wanted but not running - operator DNS"; else echo "custom DNS: off (operator DNS)"; fi ;;
  esac
}
