# QManager port

* `UPSTREAM_COMMIT`: the QManager-GO commit this patch applies to.
* `vosclean.patch`: back-end changes for the Compal RXM-G1 (see docs/06-qmanager.md). The front end is unmodified.
* `build.sh`: clone, patch, build. The result is `../dist/qmanager-core-armv7`.

QManager-GO (https://github.com/evairo176/qmanager) is licensed **MIT with Commons Clause**. The patch and any binary
built from it are covered by that licence: free to use, modify and share, but not to sell.
