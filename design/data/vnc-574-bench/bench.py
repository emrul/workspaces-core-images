#!/usr/bin/env python3
"""Container-start -> desktop benchmark, VNC-574 methodology.

Fresh container per trial, limited to 2 CPUs / 4 GiB, warm page cache
(discarded warm-up runs first). Variants are interleaved round-robin so host
drift hits all of them equally. Run on the docker host itself.

usage: bench.py TRIALS OUT.json name=image [name=image ...]
"""
import json, os, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "probe.sh")
WARMUP = 2


def sh(*a, **k):
    return subprocess.run(a, capture_output=True, text=True, **k)


def trial(image):
    cid = sh("docker", "create", "--cpus", "2", "--memory", "4g", "--shm-size", "512m",
             "-e", "VNC_PW=password", image).stdout.strip()
    try:
        sh("docker", "cp", PROBE, cid + ":/usr/local/bin/kasm-bench-probe")
        t0 = time.time()
        sh("docker", "start", cid)
        out = ""
        # exec can race the very first moments of container start; retry briefly.
        for _ in range(20):
            r = sh("docker", "exec", cid, "sh", "/usr/local/bin/kasm-bench-probe", "90")
            out = r.stdout
            if "desktop" in out or "timeout" in out:
                break
            time.sleep(0.05)
        res = {}
        for line in out.splitlines():
            k, _, v = line.partition(" ")
            if k in ("listen", "desktop"):
                res[k] = round(float(v) - t0, 3)
        return res
    finally:
        sh("docker", "rm", "-f", cid)


def main():
    trials, out_path = int(sys.argv[1]), sys.argv[2]
    variants = [a.split("=", 1) for a in sys.argv[3:]]
    data = {n: [] for n, _ in variants}
    for i in range(WARMUP + trials):
        for name, image in variants:
            r = trial(image)
            tag = "warmup" if i < WARMUP else "trial %d" % (i - WARMUP + 1)
            print("%-8s %-22s %s" % (tag, name, r), flush=True)
            if i >= WARMUP:
                data[name].append(r)
        json.dump(data, open(out_path, "w"), indent=1)
    print("\n%-22s %5s %22s %22s" % ("variant", "n", "listen med [min-max]", "desktop med [min-max]"))
    for name, rs in data.items():
        cols = []
        for k in ("listen", "desktop"):
            v = [r[k] for r in rs if k in r]
            cols.append("%.3f [%.3f-%.3f]" % (statistics.median(v), min(v), max(v)) if v else "n/a")
        ok = sum(1 for r in rs if "desktop" in r)
        print("%-22s %2d/%-2d %22s %22s" % (name, ok, len(rs), cols[0], cols[1]))


if __name__ == "__main__":
    main()
