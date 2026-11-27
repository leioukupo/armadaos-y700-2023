# One clean boot attempt driven over Sahara: wait until the crashdump PBL actually issues
# a HELLO_REQ (the session is only live for a few seconds after a crash), acknowledge it,
# then send RESET_REQ so PBL restarts the boot flow from scratch.
import logging
import sys
import time

sys.path.insert(0, "/srv/y700/edltool")
from edlclient.Library.Connection.usblib import usb_class  # noqa: E402
from edlclient.Library.sahara import sahara  # noqa: E402
from edlclient.Library.sahara_defs import cmd_t, sahara_mode_t  # noqa: E402

deadline = time.time() + 150
while time.time() < deadline:
    cdc = usb_class(loglevel=logging.ERROR, portconfig=[(0x05C6, 0x900E, -1)])
    if not cdc.connect():
        time.sleep(1)
        continue
    sh = sahara(cdc=cdc, loglevel=logging.ERROR)
    try:
        resp = sh.connect()
    except Exception:
        time.sleep(1)
        continue
    if resp.get("mode") == "sahara" and resp.get("cmd") == cmd_t.SAHARA_HELLO_REQ:
        version = getattr(resp.get("data"), "version", 2)
        sh.cmd_hello(sahara_mode_t.SAHARA_MODE_MEMORY_DEBUG, version=version)
        try:
            sh.get_rsp()
        except Exception:
            pass
        ok = sh.cmd_reset()
        cdc.close()
        print("live session seen, RESET_SENT ok=%s at %s" % (ok, time.strftime("%H:%M:%S")), flush=True)
        sys.exit(0 if ok else 1)
    cdc.close()
    time.sleep(1)
print("NO_LIVE_SESSION in 150s", flush=True)
sys.exit(2)
