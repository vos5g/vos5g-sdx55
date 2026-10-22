#!/bin/sh
# vosclean web UI backend. Whitelisted commands only; inputs validated; nothing is eval'd.
VC=/data/vosclean
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
TO="timeout -t 12"

reply() { R=1; printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'; }
fail()  { [ -n "$R" ] || printf 'Status: %s\r\nContent-Type: text/plain\r\n\r\n' "$1"; printf 'ERROR: %s\n' "$2"; exit 0; }
sec()   { echo "### $1"; shift; $TO "$@" 2>&1; echo; }
log()   { echo "$(date -u '+%F %T') ui: $*" >> $VC/log/vosclean.log; }

urldecode() { d=$(printf '%s' "$1" | sed 's/+/ /g; s/\\/\\\\/g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g'); printf '%b' "$d"; }
# form field: getf NAME  (from $FORM)
getf() { printf '%s' "$FORM" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | { read -r v; urldecode "$v"; }; }
ok() { printf '%s' "$1" | grep -Eq "^($2)\$"; }

case "$REQUEST_METHOD" in
GET)
  A=$(printf '%s' "$QUERY_STRING" | sed -n 's/^.*a=\([a-z_]*\).*$/\1/p')
  reply
  case "$A" in
  dash)
    sec rat cricli rat; sec operator cricli operator; sec reg cricli get_registration_state
    sec roaming cricli roaming; sec conn cricli get_conn_state; sec signal cricli signal
    sec band cricli band; sec wwan cricli wwan_config; sec stats cricli wwan_stats
    sec lte atcli 'AT+BINFO'; sec nr atcli 'AT+BNRINFO'
    sec lca atcli 'AT+LCAINFO'; sec nrca atcli 'AT+NRCAINFO'; sec endc atcli 'AT+5GDISP?'
    echo "### temps"; for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type 2>/dev/null); case "$t" in cpu0-a7-usr|mdm-5g-usr|mdm-q6-usr|ipa-usr|pa-therm1-usr|pa-therm2-usr|sdx-case-therm-usr|xo-therm-usr) echo "$t $(cat $z/temp 2>/dev/null)";; esac; done; echo
    echo "### uptime"; cut -d' ' -f1 /proc/uptime ;;
  bands)
    sec pref cricli get_pref_band; sec rat_pref cricli get_pref_rat; sec cap cricli band_cap
    sec nrcell cricli get_nr5g_cell_config; sec ltecell cricli get_cell_config; sec bconfig atcli 'AT+BCONFIG?'
    echo "### defaults"; cat $VC/state/bands.default 2>/dev/null ;;
  sms)
    sec sim cricli get_msg_list 0; sec nv cricli get_msg_list 1
    sec cap_sim cricli sms_capacity 0; sec cap_nv cricli sms_capacity 1 ;;
  net)
    sec profile cricli get_profile; sec wwan cricli wwan_config; sec stats cricli wwan_stats
    sec usbcomp atcli 'AT+USBCOMP?'; echo "### usbnext"; cat /etc/usb/boot_hsusb_comp; echo
    sec card cricli card_status; sec clients cricli dhcp_client_list ;;
  sys)
    echo "### info"; atcli ATI | grep -E 'Model|Revision'; cat /oem/cei_module_ver_vos_id; echo
    echo "### uptime"; cut -d' ' -f1 /proc/uptime; echo
    sec vosclean $VC/bin/vosclean status; sec df df -h / /data /oem
    echo "### mem"; grep -E 'MemTotal|MemAvailable' /proc/meminfo; echo
    echo "### log"; tail -n 25 $VC/log/vosclean.log ;;
  *) echo "unknown" ;;
  esac ;;

POST)
  # CSRF guard: browsers cannot send this header cross-site without a CORS preflight we never allow.
  [ "$HTTP_X_VOSCLEAN" = "1" ] || fail 403 "missing header"
  [ "${CONTENT_LENGTH:-0}" -le 4096 ] 2>/dev/null || fail 413 "too large"
  FORM=$(head -c "${CONTENT_LENGTH:-0}")
  A=$(getf a)
  reply
  case "$A" in
  set_rat)
    v=$(getf v); ok "$v" '88|80|24|64|16|8' || fail 400 "bad rat"
    log "set_rat $v"; $TO cricli set_pref_rat "$v" 2>&1 ;;
  set_band)
    op=$(getf op); ok "$op" '2|3|4' || fail 400 "bad op"
    m1=$(getf m1); m2=$(getf m2); m3=$(getf m3); m4=$(getf m4); m5=$(getf m5)
    for m in "$m1" "$m2" "$m3" "$m4" "$m5"; do ok "$m" '0x[0-9A-Fa-f]{1,16}' || fail 400 "bad mask"; done
    [ "$m1$m2$m3$m4$m5" = "0x00x00x00x00x0" ] && fail 400 "refusing empty band set"
    log "set_band op=$op $m1 $m2 $m3 $m4 $m5"
    if [ "$op" = 2 ]; then $TO cricli set_pref_band 2 "$m1" 2>&1; else $TO cricli set_pref_band "$op" "$m1" "$m2" "$m3" "$m4" "$m5" 2>&1; fi ;;
  nr_cell_unlock) log "nr cell unlock"; $TO cricli set_nr5g_cell_config 2 2>&1 ;;
  nr_cell_lock)
    pci=$(getf pci); arfcn=$(getf arfcn); scs=$(getf scs); band=$(getf band)
    ok "$pci" '[0-9]{1,4}' && ok "$arfcn" '[0-9]{1,7}' && ok "$scs" '[0-4]' && ok "$band" '[0-9]{1,3}' || fail 400 "bad cell"
    # band bitmask (decimal) for words 1..8: band n -> bit (n-1)
    w=$(( (band-1)/64 )); b=$(( (band-1)%64 )); set --
    i=0; while [ $i -lt 8 ]; do if [ $i -eq $w ]; then set -- "$@" "$(awk -v b=$b 'BEGIN{printf "%.0f", 2^b}')"; else set -- "$@" 0; fi; i=$((i+1)); done
    log "nr cell lock pci=$pci arfcn=$arfcn scs=$scs band=$band"; $TO cricli set_nr5g_cell_config 0 "$pci" "$arfcn" "$scs" "$@" 2>&1 ;;
  lte_cell_unlock) log "lte cell unlock"; $TO cricli set_cell_config 2>&1 ;;
  lte_cell_lock)
    pci=$(getf pci); f=$(getf freq); ok "$pci" '[0-9]{1,3}' && ok "$f" '[0-9]{1,5}' || fail 400 "bad cell"
    log "lte cell lock pci=$pci freq=$f"; $TO cricli set_cell_config "$pci" "$f" 2>&1 ;;
  set_apn)
    apn=$(getf apn); pdp=$(getf pdp); user=$(getf user); pw=$(getf pw); auth=$(getf auth)
    ok "$apn" '[A-Za-z0-9._-]{1,62}' && ok "$pdp" '0|2|3' && ok "$auth" '0|1|2|3' || fail 400 "bad apn"
    [ -z "$user" ] || ok "$user" '[A-Za-z0-9._@-]{1,64}' || fail 400 "bad user"
    [ -z "$pw" ] || ok "$pw" '[A-Za-z0-9._@!#%+=-]{1,64}' || fail 400 "bad password chars"
    log "set_apn $apn pdp=$pdp auth=$auth"; $TO cricli set_profile 1 "" "$apn" "$user" "$pw" "$pdp" "$auth" 2>&1 ;;
  send_sms)
    to=$(getf to); msg=$(getf msg)
    ok "$to" '\+?[0-9]{3,16}' || fail 400 "bad number"
    [ ${#msg} -ge 1 ] && [ ${#msg} -le 160 ] || fail 400 "message must be 1-160 chars"
    printf '%s' "$msg" | grep -q '[^ -~]' && fail 400 "plain ASCII only for now"
    log "send_sms to=$to len=${#msg}"; $TO cricli send_sms "$to" "$msg" 2>&1 ;;
  del_sms)
    st=$(getf st); idx=$(getf idx); ok "$st" '0|1' && ok "$idx" '[0-9]{1,3}' || fail 400 "bad sms"
    log "del_sms $st $idx"; $TO cricli del_sms "$st" "$idx" 2>&1 ;;
  usb_mode)
    m=$(getf m); ok "$m" '9063|9165|9091' || fail 400 "mode not allowed"
    log "usb_mode next boot = $m"; echo "$m" > /etc/usb/boot_hsusb_comp && sync && echo "OK: USB composition $m from next reboot" ;;
  at)
    c=$(getf c); ok "$c" '[Aa][Tt][A-Za-z0-9+$^&?=,."_ -]{0,120}' || fail 400 "bad AT command"
    case "$c" in *CEIFACRESET*|*ceifacreset*|*USBCOMP=*|*usbcomp=*|*CFUN=0*|*FWNV*|*fwnv*) fail 403 "blocked from console (use the dedicated controls)";; esac
    log "at $c"; $TO atcli "$c" 2>&1 ;;
  reboot) log "reboot requested"; echo "rebooting"; (sleep 2; systemctl reboot) >/dev/null 2>&1 & ;;
  *) fail 400 "unknown action" ;;
  esac ;;
*) fail 405 "method" ;;
esac
