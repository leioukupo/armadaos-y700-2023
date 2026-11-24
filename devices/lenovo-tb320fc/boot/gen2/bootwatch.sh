#!/bin/bash
# Judge a boot round without a TF card or a serial console: the only thing the
# host can see is what the tablet enumerates on USB while it tries slot a.
#   18d1:d00d  fastboot          -> XBL rejected the payload outright
#   05c6:9008  EDL/crashdump     -> the payload started and died fatally
#   adb serial HA1WZJJ5          -> some OS booted; `adb shell uname -r` says which
DUR=${DUR:-300}
END=$(( $(date +%s) + DUR ))
prev=""
adb start-server >/dev/null 2>&1
while [ "$(date +%s)" -lt "$END" ]; do
  usb=$(lsusb | grep -viE 'linux foundation|intel corp|root hub' | sed 's/^.*ID /ID /' | sort | tr '\n' ' ')
  adblist=$(adb devices | sed -n '2,$p' | tr -d '\r' | grep -v '^$' | tr '\n' ' ')
  line="usb[$usb] adb[$adblist]"
  if [ "$line" != "$prev" ]; then
    printf '%s %s\n' "$(date +%H:%M:%S)" "$line"
    prev="$line"
  fi
  sleep 2
done
printf '%s watch done\n' "$(date +%H:%M:%S)"
