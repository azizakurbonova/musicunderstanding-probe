#!/usr/bin/env python3
"""Pull the printed timelines and verdict blocks out of an xcodebuild test log."""
import os
import re
import sys

log_path = sys.argv[1] if len(sys.argv) > 1 else "out/50-simulator-test.log"
out_dir = sys.argv[2] if len(sys.argv) > 2 else "out"
os.makedirs(out_dir, exist_ok=True)

try:
    log = open(log_path, errors="replace").read()
except FileNotFoundError:
    print("no simulator log at", log_path)
    sys.exit(0)

blocks = re.findall(
    r"<<<<<<<<<< BEGIN TIMELINE (\S+) >>>>>>>>>>(.*?)<<<<<<<<<< END TIMELINE \1 >>>>>>>>>>",
    log, re.S)
print("timeline blocks found:", len(blocks))
for slug, body in blocks:
    path = os.path.join(out_dir, "60-timeline-%s.txt" % slug)
    with open(path, "w") as f:
        f.write(body.strip() + "\n")
    print("wrote", path, len(body), "chars")

env = re.search(r"=== ENVIRONMENT ===(.*?)=== SYNTHETIC RESULT ===", log, re.S)
syn = re.search(r"=== SYNTHETIC RESULT ===(.*?)(?:Test Case|\Z)", log, re.S)
verdict = os.path.join(out_dir, "40-simulator-verdict.txt")
with open(verdict, "w") as f:
    f.write("ENVIRONMENT\n" + (env.group(1) if env else "(not found)\n"))
    f.write("\nSYNTHETIC RESULT\n" + (syn.group(1)[:4000] if syn else "(not found)\n"))
print(open(verdict).read())

tab = re.search(r"=== TIMING TABLE \(iOS Simulator\) ===(.*?)\n\s*\n", log, re.S)
if tab:
    with open(os.path.join(out_dir, "41-timing-simulator.md"), "w") as f:
        f.write(tab.group(1))
    print(tab.group(1))

# Surface the pass/fail lines so the verdict is unambiguous.
cases = re.findall(r"Test Case .*? (passed|failed|skipped) .*", log)
print("test case outcomes:", cases[:20])
for m in re.findall(r"^.*(?:error:|XCTAssert|Fatal error|failed -).*$", log, re.M)[:40]:
    print("FAILLINE:", m.strip())
