#!/bin/sh
# Redacts personal identifiers from vos_readonly_probe.sh output so it can be
# shared:   sh tools/redact_probe.sh probe.txt > probe-redacted.txt
# Needs perl (preinstalled on macOS and almost every Linux).
#
# Replaced: IMEI, IMSI, ICCID, EID, serial numbers, phone numbers, MAC
# addresses, public IPv4 and CGNAT (100.64/10: carrier or Tailscale) addresses
# (private and loopback ranges are kept), IPv6 addresses (except ::1), and
# cell identities (cell ID, eNB/gNB, TAC/LAC and the CEREG/C5GREG location
# fields). Band, channel, PCI and signal
# levels are kept: they are what makes a probe useful to compare.
#
# Always read the result before posting it: this catches the known fields,
# not everything a future firmware might print.
[ -n "$1" ] && [ -r "$1" ] || { echo "usage: $0 probe.txt > probe-redacted.txt" >&2; exit 1; }
exec perl -ne '
sub pub4 {
  my @o = split /\./, shift;
  return 0 if grep { $_ > 255 } @o;
  return 0 if $o[0] == 10 || $o[0] == 127 || $o[0] == 0 || $o[0] >= 224;
  return 0 if $o[0] == 192 && $o[1] == 168;
  return 0 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31;
  return 0 if $o[0] == 169 && $o[1] == 254;
  return 2 if $o[0] == 100 && $o[1] >= 64 && $o[1] <= 127;   # CGNAT: carrier or Tailscale address
  return 1;
}
# labelled identifiers: everything after the label
s/\b(IMEI|IMSI|ICCID|EID|MSISDN|MEID|ESN|SN number\d*|[Ss]erial(?: [Nn]umber)?|Phone(?: [Nn]umber)?|Number)(\s*[:=]\s*).+$/$1$2<redacted>/;
# +CNUM: "","+447...",145 and other quoted phone numbers
s/"\+?\d{8,15}"/"<redacted>"/g;
# long digit runs: IMEI/IMSI (15), ICCID (18-20), EID (32)
s/(?<![\dA-Fa-fx.])\d{14,32}(?![\dA-Fa-f.])/<redacted-id>/g;
# MAC addresses
s/\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b/xx:xx:xx:xx:xx:xx/g;
# IPv6 addresses (three or more groups), but not ::1 or times like 12:34:56
s{(?<![\w:])(?=[0-9A-Fa-f:]*[A-Fa-f:]{2})(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?:/\d+)?(?![\w:])}{ $& eq "::1" ? $& : "<ipv6>" }ge;
# public IPv4
s/(?<![\d.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?![\d.])/my $k = pub4($1); $k == 1 ? "<public-ipv4>" : $k == 2 ? "<cgnat-ipv4>" : $1/ge;
# cell identity: "Serving Cell ID 744776", "TAC 1192", "cell_id:123", "global_cell_id: 0x..."
s/(?<![Pp]hysical )\b((?:[Ss]erving |[Gg]lobal )?[Cc]ell[ _]?(?:ID|Id|id)|global_cell_id|serving_cell_id|[EeGg]?[Nn]ode[Bb](?:[ _]?[Ii][Dd])?|[EeGg][Nn][Bb][ _]?[Ii][Dd]|TAC|tac|LAC|lac|ECI|eci|NCI|nci)(\s*[:=]?\s*)(0x[0-9A-Fa-f]+|[0-9A-Fa-f]*\d[0-9A-Fa-f]*)\b/$1$2<redacted>/g;
# +CEREG: 2,1,"04A8","B5D48",7 / +C5GREG / +CREG: location fields in quotes
s/"[0-9A-Fa-f]+"/"<redacted>"/g if /\+C(?:E|5G|G)?REG:/;
print;
' "$1"
