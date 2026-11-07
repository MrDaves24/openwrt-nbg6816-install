#!/bin/sh
# One test case, in the container: the script from /stock/t/script, run in the stock firmware's
# root as ssh runs it (sh -s ARGS), then the environment it leaves, read by the stock fw_printenv
mknod /stock/dev/null c 1 3
cd /stock/t
chroot /stock /bin/sh -s "$@" </stock/t/script >/stock/t/stdout 2>/stock/t/stderr
echo $? >/stock/t/rc
chroot /stock /usr/sbin/fw_printenv >/stock/t/printenv 2>&1
# Its status is the script's, in rc
exit 0
