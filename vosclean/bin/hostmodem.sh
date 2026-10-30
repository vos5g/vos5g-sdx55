# vosclean router modem mode (sourced by vosclean).
#
# The stick keeps its own data call on the SIM's APN (QCMAP's "backhaul"). A
# USB host that uses the stick as its modem (QMI or MBIM, e.g. OpenWrt with
# 05c6:9064 configuration 1) asks for a call on the same APN and the modem
# refuses it ("Call failed"). With HOST_MODEM=auto a small daemon watches USB:
#
#   USB configured, but no USB-Ethernet link (ecm0/rndis0) for 6 s
#       -> the host has taken the modem: auto-connect off, the stick's call down
#   USB-Ethernet link back (tethering), or USB not configured
#       -> auto-connect on, the stick's call up again
#
# While the host has the modem the stick has no internet of its own, so the
# daemon keeps QManager's watchdog on hold (it would otherwise "repair" the
# missing call, up to restarting the stick). QCMAP saves the auto-connect flag
# across reboots: a marker file records that we switched it off, and the daemon
# switches it back on whenever the host isn't using the modem, including after a
# reboot and when the feature is turned off.
HM_STATE=/tmp/vosclean/hostmodem          # mode=stick|host since=<epoch>  (read by QManager)
HM_MARK=$VC/state/hostmodem-released      # exists while we hold auto-connect off
HM_UNIT=vos-hostmodem
HM_HOLD=/tmp/qmanager_radio_hold          # QManager's watchdog skips its steps while this is fresh
HM_DEBOUNCE=3                             # checks (2 s apart) before deciding the host has the modem

hm_usb() { # host | tether | none
  [ "$(cat /sys/class/udc/*/state 2>/dev/null | head -1)" = configured ] || { echo none; return; }
  # only USB modes that offer the host a modem (QMI rmnet or MBIM), e.g. 05c6:9064
  ls -l /sys/kernel/config/usb_gadget/*/configs/*/ 2>/dev/null | grep -qE 'gsi\.(rmnet|mbim)' || { echo tether; return; }
  for n in ecm0 rndis0; do
    [ "$(cat /sys/class/net/$n/operstate 2>/dev/null)" = up ] && { echo tether; return; }
  done
  echo host
}
hm_autoconnect() { cricli get_auto_connect_state 2>/dev/null | sed -n 's/.*Flag: *\([0-9]\).*/\1/p'; }
hm_backhaul_up() { cricli get_backhaul_state 2>/dev/null | grep -q "State: 1"; }
hm_write() { mkdir -p /tmp/vosclean; echo "mode=$1 since=$(date +%s)" > $HM_STATE.new && mv $HM_STATE.new $HM_STATE; }

hm_release() { # the host takes the APN
  mkdir -p $VC/state; : > $HM_MARK; sync
  cricli set_auto_connect_state 0 >/dev/null 2>&1
  cricli backhaul_disconnect 1 >/dev/null 2>&1
  cricli backhaul_disconnect 2 >/dev/null 2>&1
  touch $HM_HOLD
}
hm_reclaim() { # the stick takes its call back; true once auto-connect is on again
  cricli set_auto_connect_state 1 >/dev/null 2>&1
  [ "$(hm_autoconnect)" = 1 ] || return 1   # QCMAP ignores this for ~1 min after boot: retried
  hm_backhaul_up || cricli backhaul_connect 1 >/dev/null 2>&1
  rm -f $HM_MARK; sync
}

# the daemon (systemd unit vos-hostmodem, started by do_hostmodem)
hm_run() {
  mode=stick; n=0; tick=0
  hm_write stick
  while :; do
    . $VC/etc/vosclean.conf 2>/dev/null
    if [ "${HOST_MODEM:-off}" != auto ]; then   # turned off: give the call back and stop
      if [ ! -f $HM_MARK ] || hm_reclaim; then
        [ $mode = host ] && log "router modem mode off: the stick has its data connection again"
        hm_write stick; exit 0
      fi
      sleep 5; continue
    fi
    if [ "$(hm_usb)" = host ]; then n=$((n + 1)); else n=0; fi
    if [ $mode = stick ] && [ $n -ge $HM_DEBOUNCE ]; then
      mode=host; hm_release; hm_write host
      log "USB host is using the stick as its modem: released the stick's own data connection"
    elif [ $mode = host ] && [ $n -eq 0 ]; then
      mode=stick; hm_write stick
      if hm_reclaim; then log "USB host is no longer using the modem: the stick reconnected"
      else log "USB host is no longer using the modem: reconnecting when the modem is ready"; fi
    fi
    if [ $mode = host ]; then
      touch $HM_HOLD
      # QCMAP can bring its call back (e.g. while it is still starting up)
      tick=$((tick + 1))
      if [ $((tick % 3)) -eq 0 ] && hm_backhaul_up; then
        log "the stick's own call came back while the host has the modem: releasing it again"
        hm_release
      fi
    elif [ -f $HM_MARK ]; then
      hm_reclaim   # not done yet (modem was not ready): keep trying
    fi
    sleep 2
  done
}

do_hostmodem() { # start or stop the daemon to match HOST_MODEM
  if [ "${HOST_MODEM:-off}" = auto ] || [ -f $HM_MARK ]; then
    systemctl is-active --quiet $HM_UNIT && return 0
    systemctl reset-failed $HM_UNIT 2>/dev/null
    systemd-run --unit=$HM_UNIT -p Restart=on-failure -p RestartSec=5 $VC/bin/vosclean hostmodem-run >/dev/null 2>&1 \
      && { [ "${HOST_MODEM:-off}" = auto ] && log "router modem mode on"; }
  fi
  return 0
}

hostmodem_set() { # on|off
  case "$1" in on) v=auto ;; off) v=off ;; *) echo "usage: vosclean hostmodem [on|off]"; return 1 ;; esac
  f=$VC/etc/vosclean.conf
  if grep -q '^HOST_MODEM=' $f; then
    sed "s/^HOST_MODEM=.*/HOST_MODEM=$v/" $f > $f.new
  else
    { cat $f; printf '\n# Router modem mode: when a USB host uses the stick as its modem (QMI/MBIM), hand it the\n# data connection and take it back when tethering returns. auto | off (QManager: System Settings -> USB mode)\nHOST_MODEM=%s\n' $v; } > $f.new
  fi
  sync && mv $f.new $f && sync || return 1
  HOST_MODEM=$v
  [ $v = off ] && log "router modem mode off" # the daemon gives the call back and exits by itself
  do_hostmodem; conf_save_good
}

hostmodem_status() {
  mode=stick; [ -f $HM_STATE ] && . $HM_STATE
  echo "router modem mode: ${HOST_MODEM:-off} ($(systemctl is-active $HM_UNIT 2>/dev/null)), usb: $(hm_usb), data connection: $([ "$mode" = host ] && echo "with the USB host" || echo "with the stick")$([ -f $HM_MARK ] && echo ', auto-connect held off')"
}
