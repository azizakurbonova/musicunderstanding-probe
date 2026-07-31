#!/usr/bin/env python3
"""Pick the newest available iOS simulator runtime and a matching iPhone device type."""
import json
import re
import subprocess
import sys


def sh(*args):
    return json.loads(subprocess.check_output(list(args)))


def version_key(v):
    return [int(x) for x in re.findall(r"\d+", v)] or [0]


runtimes = sh("xcrun", "simctl", "list", "runtimes", "--json")["runtimes"]
ios = [r for r in runtimes if r.get("isAvailable") and r.get("platform") == "iOS"]
if not ios:
    ios = [r for r in runtimes if r.get("isAvailable") and "iOS" in r.get("identifier", "")]
if not ios:
    print("NO_IOS_RUNTIME", file=sys.stderr)
    sys.exit(1)
rt = sorted(ios, key=lambda r: version_key(r.get("version", "0")))[-1]

supported = set(rt.get("supportedDeviceTypes") and
                [d["identifier"] for d in rt["supportedDeviceTypes"]] or [])

devtypes = sh("xcrun", "simctl", "list", "devicetypes", "--json")["devicetypes"]
cands = [t for t in devtypes if "iPhone" in t["name"]]
if supported:
    cands = [t for t in cands if t["identifier"] in supported] or cands

# Prefer a plain numbered iPhone (e.g. "iPhone 17"), highest number.
plain = [t for t in cands if re.fullmatch(r"iPhone \d+", t["name"])]
pick = sorted(plain or cands, key=lambda t: version_key(t["name"]))[-1]

print(rt["identifier"])
print(pick["identifier"])
print(rt.get("version", "?"), file=sys.stderr)
print(pick["name"], file=sys.stderr)
