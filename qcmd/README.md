# qcmd

A Quectel-AT → Compal translator for the RXM-G1 / SG500M2-X. QManager calls `qcmd "<AT command>"`.

```
./build.sh                       # tests + ARMv7 static build -> ../dist/qcmd-armv7
qcmd 'AT+QENG="servingcell"'      # on the modem
qcmd sms_tool recv               # multi-call: SMS helper used by QManager
QCMD_DEBUG=1 qcmd AT+QSCAN       # dump raw QMI TLVs
```

See docs/06-qmanager.md for the full translation table and the safety rules.
