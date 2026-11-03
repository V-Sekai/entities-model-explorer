"""Run from the viewer project root: GODOT=... MODEL=rigged.glb WORK=/tmp/frontier python3 tools/course/frontier.py

Frontier search over the obstacle course's crouch bar and crawl tunnel clear heights (mm): bisect each between a failing and a
passing value, three trials at once (each trial is a full staged run with its own colliders file, the bar and the tunnel
varied together because the stations are independent), until the bracket is under TOL mm."""
import json, os, re, subprocess, sys, time
# Environment: GODOT (the editor binary with the sandbox module), MODEL (a rigged model), WORK (a scratch directory); run from the
# viewer project root (the directory with project.godot), which has the guest ELFs, motion/mm and an imported .godot.
ME = os.getcwd()
S = os.environ["WORK"]
GODOT = os.environ["GODOT"]
MODEL = os.environ["MODEL"]
TOL, REPEATS = 12, 2  # a setting is run REPEATS times at once (the viewer steps by real frame time, so runs differ); it passes only if all pass
src = open(ME + "/tools/course/course_script.py").read()
bar = {"fail": 1562, "pass": 1650}      # from the first search: 1562 fails, 1650 passes
tun = {"fail": 938, "pass": 1000}       # from the first search: 938 fails, 1000 passes
rows = []

def trial(i, b, t):
    code = re.sub(r'\("beam_clear", "\d+ mm"', f'("beam_clear", "{b} mm"', src)
    code = re.sub(r'\("tunnel_clear", "\d+ mm"', f'("tunnel_clear", "{t} mm"', code)
    py = f"{S}/frontier/c{i}.py"; open(py, "w").write(code)
    col = f"{S}/frontier/colliders{i}.json"
    open(col, "w").write(subprocess.run(["python3", py, "--colliders"], capture_output=True, text=True, check=True).stdout)
    env = dict(os.environ, MOVE_STEPS="course-stages", COURSE_COLLIDERS=col)
    log = open(f"{S}/frontier/log{i}.txt", "w")
    return subprocess.Popen([GODOT, "--path", ME, "--", MODEL, "--obstacle-course", "--move-quit"], env=env, stdout=log, stderr=subprocess.STDOUT, cwd=ME)

def read(i):
    out = {}
    for l in open(f"{S}/frontier/log{i}.txt"):
        m = re.match(r"COURSE-CHECK (\S+) pass=(\d) reached=(\d)(?: .*room (-?[\d.]+))?", l)
        if m: out[m[1]] = (m[2] == "1", float(m[4]) if m[4] else None)
    return out

os.makedirs(S + "/frontier", exist_ok=True)  # results: $WORK/course_frontier.tsv
rnd = 0
while (bar["pass"] - bar["fail"] > TOL) or (tun["pass"] - tun["fail"] > TOL):
    rnd += 1
    b = round((bar["fail"] + bar["pass"]) / 2) if bar["pass"] - bar["fail"] > TOL else bar["pass"]
    t = round((tun["fail"] + tun["pass"]) / 2) if tun["pass"] - tun["fail"] > TOL else tun["pass"]
    procs = [trial(k, b, t) for k in range(REPEATS)]
    for p in procs: p.wait(timeout=600)
    res = [read(k) for k in range(REPEATS)]
    duck = [r.get("duck", (None, None)) for r in res]; crawl = [r.get("crawl", (None, None)) for r in res]
    d_ok = None if any(x[0] is None for x in duck) else all(x[0] for x in duck)
    c_ok = None if any(x[0] is None for x in crawl) else all(x[0] for x in crawl)
    rows.append((rnd, b, t, duck, crawl)); print(f"round {rnd} bar {b} duck {duck} -> {d_ok}   tunnel {t} crawl {crawl} -> {c_ok}", flush=True)
    if d_ok is not None and bar["pass"] - bar["fail"] > TOL:
        bar["pass" if d_ok else "fail"] = b
    if c_ok is not None and tun["pass"] - tun["fail"] > TOL:
        tun["pass" if c_ok else "fail"] = t
    print(f"bracket after round {rnd}: bar ({bar['fail']}, {bar['pass']}]  tunnel ({tun['fail']}, {tun['pass']}]", flush=True)
print("FRONTIER bar_clear_mm", bar["pass"], "tunnel_clear_mm", tun["pass"], flush=True)
with open(os.path.join(S, "course_frontier.tsv"), "w") as f:
    f.write("round\tbar_mm\tduck_runs(pass,room_m)\ttunnel_mm\tcrawl_runs(pass,room_m)\n")
    for rnd_, b, t, d, c in rows: f.write(f"{rnd_}\t{b}\t{d}\t{t}\t{c}\n")
