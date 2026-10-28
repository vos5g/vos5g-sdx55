# VOS ARMv7 DIAG helper

`adb_bridge.c` is from P1sec/QCSuper 2.1.3, commit
`aa555b4f7f25f7a8bf4e5afd4dcb884edf2f6735`, under GPL-3.0-or-later
(see LICENSE). It includes maigougou/vos5g-all-band-unlock's ARMv7/Linux
and disconnected-client fixes. Our additional changes bind the server to
127.0.0.1 only and correct the client-count bound.

Build with `tools/build-diag-bridge.sh` (Zig) or set CC_ARM to an ARM musl compiler.
Install with `install.sh --diag-bridge dist/vos5g-diag-bridge-armv7`.
QManager starts this separate process only during EFS operations and kills it
when finished. It is not linked into the QManager binary. Port 43555 remains
local to the stick; do not forward it to a network. Close QCSuper/QPST sessions
before using QManager's EFS tools.

Upstream: https://github.com/P1sec/QCSuper
VOS patch: https://github.com/maigougou/vos5g-all-band-unlock
