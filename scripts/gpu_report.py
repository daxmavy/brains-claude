#!/usr/bin/env python3
"""Brains GPU status + capacity/policy check. Runs ON Brains (reads nvidia-smi).

Reports which GPUs are free vs busy, who is occupying the busy ones and how many
GPUs each user holds, then decides whether a request for some GPUs is allowed
under the policy: the agent must NEVER occupy ALL GPUs without explicit
permission (pass --allow-all only after the user has approved).

Usage:  python3 gpu_report.py [--need N | --want i,j] [--allow-all] [--min-free-mib M] [--max-util P]
Exit:   0  ok                (prints "SELECT=i,j" when a request was made)
        3  insufficient       (not enough free GPUs, or a wanted GPU is busy)
        4  needs-permission   (request would occupy ALL GPUs)
        2  error
"""
import argparse, os, pwd, subprocess, sys
from collections import defaultdict

try:
    ME = pwd.getpwuid(os.getuid()).pw_name
except KeyError:
    ME = str(os.getuid())


def smi(qtype, fields):
    r = subprocess.run(
        ["nvidia-smi", f"--query-{qtype}={fields}", "--format=csv,noheader,nounits"],
        capture_output=True, text=True)
    if r.returncode != 0:
        print("error: nvidia-smi failed:", r.stderr.strip(), file=sys.stderr)
        sys.exit(2)
    return [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]


def users_of(pids):
    out = {}
    if not pids:
        return out
    r = subprocess.run(["ps", "-o", "pid=,uid=", "-p", ",".join(map(str, pids))],
                       capture_output=True, text=True)
    for ln in r.stdout.splitlines():
        f = ln.split()
        if len(f) >= 2:
            pid, uid = int(f[0]), int(f[1])
            try:
                out[pid] = pwd.getpwuid(uid).pw_name
            except KeyError:
                out[pid] = f"uid:{uid}"
    return out


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--need", type=int, default=0, help="number of free GPUs to auto-select")
    g.add_argument("--want", default="", help="explicit GPU indices, e.g. 2,3")
    ap.add_argument("--allow-all", action="store_true",
                    help="permit occupying ALL GPUs (only after user approval)")
    ap.add_argument("--min-free-mib", type=int, default=40000,
                    help="a GPU needs at least this much FREE memory to be usable")
    ap.add_argument("--max-util", type=int, default=20,
                    help="...and utilisation <= this %% (lets us share lightly-used GPUs)")
    args = ap.parse_args()

    # --- gather ---
    gpus = {}
    for ln in smi("gpu", "index,name,memory.used,memory.total,utilization.gpu"):
        idx, name, used, total, util = (x.strip() for x in ln.split(","))
        gpus[int(idx)] = dict(name=name, used=int(used), total=int(total),
                              util=int(util), procs=[])
    uuid2idx = {}
    for ln in smi("gpu", "index,uuid"):
        idx, uuid = (x.strip() for x in ln.split(","))
        uuid2idx[uuid] = int(idx)

    raw = []  # (idx, pid, mem)
    for ln in smi("compute-apps", "gpu_uuid,pid,used_gpu_memory"):
        p = [x.strip() for x in ln.split(",")]
        if len(p) < 3 or p[0] not in uuid2idx:
            continue
        try:
            raw.append((uuid2idx[p[0]], int(p[1]), int(p[2])))
        except ValueError:
            continue
    who = users_of(sorted({pid for _, pid, _ in raw}))
    for idx, pid, mem in raw:
        gpus[idx]["procs"].append((who.get(pid, "?"), pid, mem))

    def free_mib(g):
        return g["total"] - g["used"]

    def is_avail(g):  # "lightly used" — lots of free memory AND low utilisation
        return free_mib(g) >= args.min_free_mib and g["util"] <= args.max_util

    total = len(gpus)
    avail = sorted((i for i in gpus if is_avail(gpus[i])),
                   key=lambda i: free_mib(gpus[i]), reverse=True)

    user_gpus, user_mem = defaultdict(set), defaultdict(int)
    for i, g in gpus.items():
        for user, _pid, mem in g["procs"]:
            if mem <= 0:           # skip ghost/defunct 0-MiB compute apps
                continue
            user_gpus[user].add(i)
            user_mem[user] += mem

    # --- snapshot (nvitop-style; this IS the canonical user-facing summary) ---
    def short(name):
        return name.replace("NVIDIA ", "").replace(" PCIe", "").strip()

    def bar(used, tot, w=12):
        f = max(0, min(w, round(w * used / tot))) if tot else 0
        return "█" * f + "░" * (w - f)

    print(f"Brains GPU snapshot — {len(avail)}/{total} usable "
          f"(usable = ≥{args.min_free_mib // 1000}GB free & ≤{args.max_util}% util)")
    for i in sorted(gpus):
        g = gpus[i]
        per = defaultdict(int)                       # users responsible, mem on THIS gpu
        for user, _pid, mem in g["procs"]:
            if mem > 0:
                per[user] += mem
        parts = [f"{u}{' (you)' if u == ME else ''} {m}M"
                 for u, m in sorted(per.items(), key=lambda kv: -kv[1])]
        gap = g["used"] - sum(per.values())          # held but not attributable to a process
        if gap > 1024:
            parts.append(f"+{gap}M unattributed")
        who = ", ".join(parts) or "—"
        pct = round(100 * g["used"] / g["total"]) if g["total"] else 0
        flag = "USABLE" if is_avail(g) else "busy  "
        print(f"  GPU{i} {short(g['name']):<9} [{bar(g['used'], g['total'])}] "
              f"{g['used']:>6}/{g['total']:>5} MiB {pct:>3}%  util {g['util']:>3}%  {flag}  {who}")
    if user_gpus:
        summary = "; ".join(
            f"{u}{' (you)' if u == ME else ''} {len(user_gpus[u])}×GPU ({user_mem[u]}M)"
            for u in sorted(user_gpus, key=lambda u: (-len(user_gpus[u]), u)))
        print(f"  Occupied by: {summary}")

    # --- decision ---
    want = [int(x) for x in args.want.split(",") if x != ""] if args.want else []
    if args.need <= 0 and not want:
        return 0

    n = len(want) if want else args.need
    print(f"Request: {n} GPU(s)" + (f" (explicit: {args.want})" if want else ""))
    if n > total:
        print(f"DECISION=impossible (only {total} GPUs exist)")
        return 3
    if n >= total and not args.allow_all:
        print("DECISION=needs-permission — this would occupy ALL GPUs. Ask the user "
              "for explicit permission, then re-run with --allow-all-gpus.")
        return 4

    if want:
        bad = [i for i in want if i not in gpus]
        if bad:
            print(f"DECISION=error (no such GPU: {bad})")
            return 2
        busy = [i for i in want if i not in avail]
        if busy:
            print(f"DECISION=insufficient — requested GPU(s) {busy} are too busy (see above)")
            return 3
        sel = sorted(want)
    else:
        if len(avail) < n:
            print(f"DECISION=insufficient — need {n}, only {len(avail)} usable "
                  f"({avail or 'none'}). See who is occupying the rest above.")
            return 3
        sel = sorted(avail[:n])

    if len(avail) - len(sel) == 0 and total > n:
        print("note: this takes the last usable GPU(s); none will remain free for others.")
    print("SELECT=" + ",".join(map(str, sel)))
    print("DECISION=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
