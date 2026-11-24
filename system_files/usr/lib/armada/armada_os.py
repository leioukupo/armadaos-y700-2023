import json
import re
import subprocess
from pathlib import Path

UPDATE = "/usr/libexec/armada/armada-update"
SELECT = "/usr/libexec/armada/armada-select-branch"
OSTREE = "/usr/bin/ostree"
BOOTED_RECORD = "/run/ostree-booted"
CHANNELS = ("stable", "beta", "preview")
FREEDOM = "ghcr.io/mydanyi/armadaos-freedom"
REPOSITORIES = (FREEDOM,)
OS_RELEASE = ("/usr/lib/os-release", "/etc/os-release")
# Transport prefixes bootc may report on a staged image reference.
TRANSPORTS = (
    "ostree-image-signed:docker://",
    "ostree-unverified-image:docker://",
    "ostree-unverified-registry:docker://",
    "ostree-unverified-registry:",
    "docker://",
)


def command(arguments, timeout=15):
    try:
        return subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.CalledProcessError as error:
        raise RuntimeError((error.stderr or "").strip() or str(error)) from error


def ref_repository_tag(image):
    """Return (repository, tag) for a supported image ref, else (None, None).

    Raw references carry no transport prefix, which is how bootc reports staged
    images. An unknown scheme, a missing tag, or a malformed repository never
    matches, so a prefix lookalike cannot be mistaken for the Freedom channel.
    """
    if not image or any(character.isspace() for character in image):
        return None, None
    for prefix in TRANSPORTS:
        if image.startswith(prefix):
            image = image[len(prefix):]
            break
    else:
        if "://" in image:
            return None, None
    image = image.split("@", 1)[0]
    repository, separator, tag = image.rpartition(":")
    if not separator or "/" in tag or "/" not in repository or ":" in repository:
        return None, None
    return repository, tag


def staged_matches_channel(staged, channel):
    if not staged:
        return False
    repository, tag = ref_repository_tag(staged.get("image", ""))
    if repository != FREEDOM:
        return False
    return tag == ("testing" if channel == "preview" else channel)


def deployment(value):
    if not value:
        return None
    image = value.get("image") or {}
    ostree = value.get("ostree") or {}
    return {"version": image.get("version") or image.get("imageDigest") or ostree.get("checksum") or "Unknown version",
            "image": (image.get("image") or {}).get("image", ""),
            "checksum": ostree.get("checksum"), "serial": ostree.get("deploySerial"),
            "stateroot": ostree.get("stateroot"), "incompatible": bool(value.get("incompatible"))}


def has_deployment():
    """True when an OSTree sysroot exists for bootc to manage.

    The running system may still be outside a deployment: adopting a flat root
    writes a repo and a deployment onto the same partition, and no boot payload
    can start that deployment until the boot image is ostree-aware.
    """
    return Path(BOOTED_RECORD).exists() or Path("/ostree/repo").is_dir()


def os_release_values():
    for path in OS_RELEASE:
        try:
            text = Path(path).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        values = {}
        for line in text.splitlines():
            name, separator, value = line.partition("=")
            if separator:
                values[name.strip()] = value.strip().strip('"')
        if values:
            return values
    return {}


def build_id():
    values = os_release_values()
    for key in ("BUILD_ID", "VERSION", "VERSION_ID", "PRETTY_NAME"):
        if values.get(key):
            return values[key]
    return "Unknown version"


def flat_state():
    """Report a plain root filesystem that has no OSTree deployment to manage.

    A bootc image written straight to a partition without an ostree sysroot has
    no deployment, no rollback target and no update channel, so the OS panel
    shows the build id from os-release and keeps the mutations unavailable.
    """
    booted = {"version": build_id(), "image": "", "checksum": None, "serial": None,
              "stateroot": None, "incompatible": False}
    return {"booted": booted, "rollback": None, "staged": None, "rollback_queued": False,
            "channel": "", "repository": "", "channels": [], "deployment": False,
            "reboot_ready": False,
            "refusal": "This installation has no OSTree deployment, so OS updates are unavailable",
            "note": ("This installation is a plain root filesystem without an OSTree deployment. "
                     "Version history, update channels and online updates are unavailable.")}


def staged_state():
    """Report a sysroot that has a deployment on disk but did not boot from it.

    An adopted flat root carries a repo, a stateroot and a deployment, yet bootc
    reports no booted deployment because the boot payload still starts the flat
    tree. The running version is known and nothing is broken, so the panel says
    what is missing instead of failing to read the OS state.
    """
    state = flat_state()
    state["refusal"] = ("This system did not boot from its OSTree deployment, "
                        "so OS updates are unavailable")
    state["note"] = ("This installation has an OSTree deployment on disk, but the system booted the "
                     "flat root filesystem, so that deployment is not in use yet. Version history, "
                     "update channels and online updates stay unavailable until the device boots "
                     "from the deployment.")
    return state



# libostree 2024.5 prints one line per deployment and marks the booted one with a
# leading "*", not with a word; the indented Version and origin refspec belong to
# the deployment above them. There is no JSON output for this table.
DEPLOYMENT = re.compile(r"^(?P<booted>[* ])\s+(?P<stateroot>\S+)\s+(?P<checksum>[0-9a-f]{64})\.(?P<serial>\d+)")
VERSION_LINE = re.compile(r"^\s+Version:\s*(.+?)\s*$")
REFSPEC_LINE = re.compile(r"^\s+origin refspec:\s*(.+?)\s*$")


def ostree_deployments():
    """The deployments libostree sees, in the order the bootloader would use them."""
    deployments = []
    for line in command([OSTREE, "admin", "status"], timeout=30).splitlines():
        match = DEPLOYMENT.match(line)
        if match:
            deployments.append({"booted": match.group("booted") == "*",
                                "stateroot": match.group("stateroot"),
                                "checksum": match.group("checksum"),
                                "serial": int(match.group("serial")),
                                "version": "", "refspec": ""})
        elif deployments:
            for pattern, key in ((VERSION_LINE, "version"), (REFSPEC_LINE, "refspec")):
                found = pattern.match(line)
                if found:
                    deployments[-1][key] = found.group(1)
    return deployments


def ostree_version(target):
    """The version stamp libostree prints for a deployment, empty when it has none."""
    deployments = ostree_deployments()
    for item in deployments:
        if item["checksum"] == target["checksum"] and item["serial"] == target["serial"]:
            return item["version"]
    for item in deployments:
        if item["booted"]:
            return item["version"]
    return ""


def unmanaged_state(state, booted):
    """Mark a booted deployment that no container image owns.

    The adopted root boots a bare ostree refspec, so bootc can only name the
    deployment by checksum and nothing manages updates for it. The panel gets the
    version stamp libostree knows, plus one plain sentence about what is missing.
    """
    booted["version"] = ostree_version(booted) or build_id() or booted["version"]
    state["refusal"] = "This deployment has no container image behind it, so OS updates are unavailable"
    state["note"] = (f"The system boots OSTree deployment {booted['stateroot']} "
                     f"{booted['checksum'][:9]}.{booted['serial']}, which no container image manages yet. "
                     "Update channels, online updates and rollback stay unavailable until an image does.")
    return state


def booted_ostree_state():
    """Report a deployment that is running even though bootc has no image for it.

    The adopted root keeps a bare refspec (armadaos) instead of a container image
    reference, so bootc answers with an empty status while libostree did boot this
    deployment. The version, checksum and stateroot then come from libostree
    itself, and the panel keeps updates, channels and rollback unavailable because
    nothing manages that refspec yet.
    """
    try:
        target = next((item for item in ostree_deployments() if item["booted"]), None)
    except (RuntimeError, ValueError, subprocess.SubprocessError):
        target = None
    state = flat_state()
    state["deployment"] = True
    state["bootc"] = False
    state["refusal"] = ("This deployment has no container image behind it, so OS updates are unavailable")
    if target:
        state["booted"] = {"version": target["version"] or build_id(), "image": "",
                           "checksum": target["checksum"], "serial": target["serial"],
                           "stateroot": target["stateroot"], "incompatible": False}
        state["note"] = (f"The system boots OSTree deployment {target['stateroot']} "
                         f"{target['checksum'][:9]}.{target['serial']}. That deployment has no container image "
                         "behind it, so update channels, online updates and rollback are not managed yet.")
    else:
        state["note"] = ("The system booted an OSTree deployment, but it could not be listed. The version above "
                         "comes from os-release; update channels, online updates and rollback are "
                         "not managed yet.")
    return state


def snapshot():
    if not has_deployment():
        return flat_state()
    try:
        raw = json.loads(command(["/usr/bin/bootc", "status", "--format", "json"]))
    except (RuntimeError, ValueError, subprocess.SubprocessError):
        # bootc cannot describe this sysroot at all.
        raw = {}
    status = raw.get("status") or {}
    booted = deployment(status.get("booted"))
    if not booted or not booted["checksum"]:
        # bootc has no image for this sysroot: either the deployment on disk was
        # never started, or it was started through a bare refspec that bootc does
        # not know. The boot record is what tells those two apart.
        return booted_ostree_state() if Path(BOOTED_RECORD).exists() else staged_state()
    try:
        target = command(["/bin/bash", "-c", 'source /usr/lib/armada/update-lib; armada_update_target "$(armada_booted_ref)"'], timeout=60).strip().split()
    except (subprocess.SubprocessError, RuntimeError):
        target = []
    repository, channel = target if len(target) == 2 else ("", "")
    if channel == "testing":
        channel = "preview"
    state = {"booted": booted, "rollback": deployment(status.get("rollback")),
             "staged": deployment(status.get("staged")), "rollback_queued": bool(status.get("rollbackQueued")),
             "channel": channel, "repository": repository,
             "channels": list(CHANNELS) if repository in REPOSITORIES and channel in CHANNELS else [],
             "deployment": True, "bootc": True}
    if not booted["image"]:
        return unmanaged_state(state, booted)
    return state


def status():
    state = snapshot()
    if not state["deployment"]:
        return state
    # A reboot is ready for an explicit rollback, or when the staged image is
    # actually the Freedom channel this deployment now targets.
    state["reboot_ready"] = bool(
        state["rollback_queued"] or staged_matches_channel(state["staged"], state["channel"]))
    return state


def select_channel(channel):
    if channel not in CHANNELS:
        raise ValueError("Unknown update channel")
    if channel not in snapshot()["channels"]:
        raise RuntimeError("Channel selection is unavailable for this image")
    command([SELECT, channel])
    return {"ok": True}


def restart():
    if not status()["reboot_ready"]:
        raise RuntimeError("There is no pending OS change to restart into")
    command(["/usr/bin/systemctl", "reboot"])
    return {"ok": True}


def execute(operation, checksum=None):
    state = snapshot()
    if not state["deployment"]:
        raise RuntimeError(state.get("refusal") or
                           "This installation has no OSTree deployment, so OS updates are unavailable")
    if operation == "update":
        if not state["repository"] or not state["channel"]:
            raise RuntimeError(state.get("refusal") or "This deployment has no supported update target")
        subprocess.run([UPDATE], check=True)
        current = snapshot()
        staged = current["staged"]
        if not staged:
            return {"message": "No new image was needed."}
        if not staged_matches_channel(staged, current["channel"]):
            raise RuntimeError(
                f"An unsupported pending update is staged from {staged['image']}. "
                "Refresh and confirm the update again.")
        return {"message": "Update installed. Restart to apply."}
    if operation != "rollback":
        raise ValueError("Unknown OS operation")
    target = state["rollback"]
    if not target or not target["checksum"] or target["incompatible"]:
        raise RuntimeError("No compatible previous deployment is available")
    if not checksum or checksum != target["checksum"]:
        raise RuntimeError("The rollback target changed. Refresh and confirm rollback again.")
    if not state["rollback_queued"]:
        print("Selecting the previous OS deployment", flush=True)
        subprocess.run(["/usr/bin/bootc", "rollback"], check=True)
    selected = snapshot()
    if not selected["rollback_queued"] or not selected["rollback"] or selected["rollback"]["checksum"] != checksum:
        raise RuntimeError("The expected rollback deployment was not selected")
    return {"message": "Rollback ready. Restart to apply."}
