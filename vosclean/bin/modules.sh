# vosclean extra kernel modules (sourced by vosclean).
# Modules built by tools/build-modules.sh for this exact kernel live in
# $VC/modules/<uname -r>/. MODULES in etc/vosclean.conf lists the groups to load:
#   wireguard  kernel WireGuard (udp_tunnel, ip6_udp_tunnel, wireguard)
#   ipv6nat    IPv6 NAT / masquerade / DNAT (nf_nat_ipv6, ip6table_nat, ...)
#   bbr        BBR congestion control for the stick's own TCP (also sets it as default)
#   fqcodel    fq_codel queue discipline
#   xtmatch    iptables matches: owner, string (bm/fsm), connbytes
# A crash or reset while loading would otherwise repeat on every boot: a marker on
# flash brackets the loading, and if it is still there at the next boot the modules
# are skipped (log says so) until "vosclean modules" is run by hand.
MOD_DIR=$VC/modules/$(uname -r)
MOD_MARK=$VC/modules/LOADING
MOD_FAILED=$VC/modules/FAILED

MOD_GROUPS="wireguard ipv6nat bbr fqcodel xtmatch"

mod_group() {
  case $1 in
    wireguard) echo "udp_tunnel ip6_udp_tunnel wireguard" ;;
    ipv6nat)   echo "nf_nat_ipv6 nf_nat_masquerade_ipv6 ip6table_nat ip6t_MASQUERADE" ;;
    bbr)       echo "tcp_bbr sch_fq" ;;
    fqcodel)   echo "sch_fq_codel" ;;
    xtmatch)   echo "ts_bm ts_fsm xt_string xt_owner xt_connbytes" ;;
  esac
}

do_modules() { # $1=manual: run by hand (clears a previous failure)
  [ -n "$MODULES" ] || { [ "$1" = manual ] && mod_unload_disabled; return 0; }
  [ -d "$MOD_DIR" ] || { log "modules: none built for kernel $(uname -r) (expected $MOD_DIR)"; return 0; }
  if [ "$1" = manual ]; then
    rm -f $MOD_FAILED
  elif [ -f $MOD_MARK ] || [ -f $MOD_FAILED ]; then
    [ -f $MOD_MARK ] && mv $MOD_MARK $MOD_FAILED
    log "modules: SKIPPED - the last load did not finish (crash or reset while loading). Check, then run: vosclean modules"
    return 0
  fi
  date -u '+%F %T' > $MOD_MARK; sync
  loaded=""; failed=""
  for g in $MODULES; do
    list=$(mod_group $g); [ -n "$list" ] || { failed="$failed $g(unknown)"; continue; }
    for m in $list; do
      grep -q "^$m " /proc/modules && continue
      if insmod $MOD_DIR/$m.ko 2>/dev/null; then loaded="$loaded $m"; else failed="$failed $m"; fi
    done
  done
  rm -f $MOD_MARK; sync
  case " $MODULES " in *" bbr "*) grep -q "^tcp_bbr " /proc/modules && sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null ;; esac
  [ "$1" = manual ] && mod_unload_disabled
  [ -n "$loaded" ] && log "modules loaded:$loaded"
  [ -n "$failed" ] && log "modules FAILED:$failed"
  return 0
}

# Unload groups that are no longer listed (newest first); a module still in use
# (e.g. wireguard by NetBird, BBR by open connections) stays until the next reboot.
mod_unload_disabled() {
  keep=""; for g in $MODULES; do keep="$keep $(mod_group $g)"; done
  case " $MODULES " in *" bbr "*) ;; *) [ "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" = bbr ] && sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null ;; esac
  unloaded=""; busy=""
  for g in $MOD_GROUPS; do
    case " $MODULES " in *" $g "*) continue ;; esac
    for m in $(mod_group $g | tr ' ' '\n' | sed '1!G;h;$!d'); do   # reverse order
      case " $keep " in *" $m "*) continue ;; esac
      grep -q "^$m " /proc/modules || continue
      if rmmod $m 2>/dev/null; then unloaded="$unloaded $m"; else busy="$busy $m"; fi
    done
  done
  [ -n "$unloaded" ] && log "modules unloaded:$unloaded"
  [ -n "$busy" ] && log "modules still in use (unload at next reboot):$busy"
  return 0
}

# machine-readable list for QManager: "<group> <module> <module>..."
modules_list() { for g in $MOD_GROUPS; do echo "$g $(mod_group $g)"; done; }

modules_status() {
  [ -n "$MODULES" ] || { echo "kernel modules: none configured (MODULES in etc/vosclean.conf)"; return; }
  s=""; for g in $MODULES; do
    ok=yes; for m in $(mod_group $g); do grep -q "^$m " /proc/modules || ok=no; done; s="$s $g:$ok"
  done
  echo "kernel modules:$s$([ -f $MOD_FAILED ] && echo ' (SKIPPED at boot after a failed load - run: vosclean modules)'), tcp_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control)"
}
