"""Summarize [Metrics] lines from a device console capture, per sweep label.

Each label's first SETTLE seconds are dropped (the stats window is 2 s and a
format or mode change takes a moment); for the rest, each figure is the median
across the per-second summaries.
"""
import json
import re
import statistics
import sys
from collections import OrderedDict

SETTLE = 6
path = sys.argv[1]
order = [l.split()[0] for l in open(sys.argv[2]) if l.strip() and not l.startswith("#")] if len(sys.argv) > 2 else None

rows = OrderedDict()
for line in open(path, errors="replace"):
    if not line.startswith("20") or "[Metrics]" not in line:
        continue
    m = json.loads(line.split("[Metrics] ", 1)[1])
    if not m.get("label") or "unity" not in m:
        continue
    rows.setdefault(m["label"], []).append(m)

def med(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else float("nan")

cols = [
    ("unity fps", lambda u: u["unityFps"]),
    ("cam fps", lambda u: u["cameraFps"]),
    ("camera", lambda u: u["camera"][0]),
    ("colour", lambda u: u["color"][0]),
    ("pose", lambda u: u["pose"][0]),
    ("wait", lambda u: u["waitForUnity"][0]),
    ("render", lambda u: u["render"][0]),
    ("total", lambda u: u["total"][0]),
    ("tot p95", lambda u: u["total"][1]),
    ("tot worst", lambda u: u["total"][2]),
    ("est", lambda u: u["estimate"][0]),
]

labels = order or list(rows)
print(f"{'label':<24}{'n':>4}" + "".join(f"{c:>10}" for c, _ in cols))
for label in labels:
    samples = rows.get(label, [])[SETTLE:]
    if not samples:
        print(f"{label:<24}{0:>4}  (no data)")
        continue
    vals = [med([f(s["unity"]) for s in samples]) for _, f in cols]
    print(f"{label:<24}{len(samples):>4}" + "".join(f"{v:>10.1f}" for v in vals))
