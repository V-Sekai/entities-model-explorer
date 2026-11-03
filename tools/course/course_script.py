#!/usr/bin/env python3
"""Write the walk-mode obstacle course as a SolidCraft command script (course.json).

The course is parametric the SolidCraft way: named parameters, sketches drawn roughly and then
fixed by constraints (inferred horizontal/vertical, equal, coincident-to-axis) and by dimensions
whose values are parameter expressions, then extruded. Change a parameter in the script (or with
parameters.change) and every station rebuilds and moves along to keep its spacing.

World axes are SolidCraft's: Z up (an XZ sketch's own y axis points down, -Z, so XZ profiles
are drawn with negative y), the course runs along +X, lanes sit side by side along Y.
Lengths in mm. Run it with the SolidCraft CLI or the guest (tools/course/bake_course.gd).

    python3 tools/course/course_script.py > vsk_model_explorer/course/course.json
"""
import json
import sys

C = []


def cmd(command, /, **params):
    C.append({"command": command, "params": params})


def param(name, expr, comment):
    cmd("parameters.add", name=name, expression=expr, comment=comment)


def colour(bodies, hex_):
    cmd("appearance.assign", bodies=bodies, color=hex_)


# A closed outline on a sketch plane: points drawn roughly (the dimensions move them), with
# horizontal/vertical inferred from the rough drawing. `pin` names the point held on the sketch's
# x axis (the floor) and `at` the parameter expression for its distance from the origin along x.
def outline(sketch, plane, offset, ids, points, dims, equal=(), pin=None, at=None, on=()):
    cmd("sketch.create", plane=plane, name=sketch, offset=offset)
    if plane == "XZ":
        points = [[x, -y] for x, y in points]
    cmd("sketch.line", points=points, closed=True, ids=ids, infer=True)
    for a, b in equal:
        cmd("sketch.constraint.equal", a=a, b=b)
    for point, axis in on:
        cmd("sketch.constraint.coincident", a=point, b=axis)
    if pin:
        cmd("sketch.constraint.coincident", a=pin, b="x")
        cmd("sketch.dimension", entities=["origin", pin], type="horizontal", value=at)
    for d in dims:
        cmd("sketch.dimension", **d)
    cmd("sketch.finish")


def extrude(body, distance, sketch):
    cmd("solid.extrude", sketch=sketch, distance=distance, direction="positive",
        operation="new", body_name=body)


def length(line, value):
    return {"entities": [line], "value": value}


def h(a, b, value):
    return {"entities": [a, b], "type": "horizontal", "value": value}


def v(a, b, value):
    return {"entities": [a, b], "type": "vertical", "value": value}


def angle(a, b, value):
    return {"entities": [a, b], "type": "angle", "value": value}


# --- parameters -------------------------------------------------------------------------------
P = [
    ("lane_w", "1200 mm", "Width of one lane"),
    ("lane_gap", "200 mm", "Space between two lanes"),
    ("course_w", "3 * lane_w + 2 * lane_gap", "Width of the whole course"),
    ("between", "2000 mm", "Flat floor between two stations"),
    ("pad", "20 mm", "Thickness of the start and finish pads"),
    ("start_len", "2400 mm", "Start pad length"),
    ("tread", "300 mm", "Stair tread depth"),
    ("rise_a", "100 mm", "Lane A riser: a low step"),
    ("rise_b", "170 mm", "Lane B riser: an ordinary stair"),
    ("rise_c", "250 mm", "Lane C riser: a steep step"),
    ("landing", "1500 mm", "Stair top landing length"),
    ("stairs_x", "start_len + between", "Where the stairs start"),
    ("stairs_len", "4 * tread + landing + 4 * tread", "Stairs length, foot to foot"),
    ("ramp_rise", "1000 mm", "Height of the ramp decks"),
    ("deck", "1500 mm", "Ramp deck length"),
    ("slope_a", "10 deg", "Lane A ramp slope"),
    ("slope_b", "20 deg", "Lane B ramp slope"),
    ("slope_c", "30 deg", "Lane C ramp slope"),
    ("ramps_x", "stairs_x + stairs_len + between", "Where the ramps start"),
    ("ramps_len", "2 * ramp_rise / tan(slope_a) + deck", "Longest ramp, foot to foot"),
    ("stone_d", "500 mm", "Stepping stone diameter"),
    ("stone_h", "350 mm", "Stepping stone height"),
    ("stone_gap_1", "250 mm", "First stepping gaps"),
    ("stone_gap_2", "400 mm", "Middle stepping gaps"),
    ("stone_gap_3", "550 mm", "Last stepping gaps"),
    ("stones_x", "ramps_x + ramps_len + between", "Where the stepping stones start"),
    ("stones_len", "7 * stone_d + 2 * (stone_gap_1 + stone_gap_2 + stone_gap_3)", "Stepping stones length"),
    ("bump_w", "900 mm", "Bump chord along the course"),
    ("bump_h", "120 mm", "Bump height"),
    ("bump_gap", "500 mm", "Floor between two bumps"),
    ("bumps_x", "stones_x + stones_len + between", "Where the bumps start"),
    ("bumps_len", "4 * bump_w + 3 * bump_gap", "Bumps length"),
    ("beam_clear", "1650 mm", "Clear height under the crouch beam"),
    ("beam_d", "300 mm", "Crouch beam depth along the course"),
    ("beam_t", "200 mm", "Crouch beam thickness"),
    ("post", "150 mm", "Beam post and tunnel wall thickness"),
    ("tunnel_clear", "600 mm", "Clear height inside the crawl tunnel (the military pentathlon wire net is 0.45 to 0.5 m; the belly crawl clears 0.562 m)"),
    ("tunnel_inner", "1500 mm", "Clear width inside the crawl tunnel"),
    ("tunnel_len", "2500 mm", "Crawl tunnel length"),
    ("roof", "120 mm", "Tunnel roof thickness"),
    ("duck_x", "bumps_x + bumps_len + between", "Where the beam and tunnel start"),
    ("duck_len", "beam_d + between + tunnel_len", "Beam and tunnel length"),
    ("plat_h", "400 mm", "Jump platform height"),
    ("plat_len", "1500 mm", "Jump platform length"),
    ("jump_gap", "800 mm", "Gap to jump"),
    ("gap_x", "duck_x + duck_len + between", "Where the jump starts"),
    ("ring_d", "2400 mm", "Finish ring outer diameter"),
    ("ring_t", "150 mm", "Finish ring band width"),
    ("ring_depth", "180 mm", "Finish ring depth along the course"),
    ("finish_x", "gap_x + 2 * plat_len + jump_gap + between", "Where the finish ring stands"),
    ("floor_margin", "3000 mm", "Floor beyond the course on every side"),
    ("floor_t", "50 mm", "Floor slab thickness"),
    ("floor_gap", "10 mm", "Floor top below the grid, so the grid lines draw over it"),
]
for p in P:
    param(*p)

# Lane centres across the course (Y): A left, B middle, C right.
LANES = {"a": "-(lane_w + lane_gap)", "b": "0 mm", "c": "lane_w + lane_gap"}

# --- floor: a solid slab under the whole course. The viewer's grid is see-through lines that
# take no light, so without it nothing casts a shadow on the ground and the course looks
# like it floats. Its top sits floor_gap under the grid plane. ------------------------------
outline("Floor", "XY", "-(floor_t + floor_gap)", ["l1", "l2", "l3", "l4"],
        [[-3000, -5000], [60000, -5000], [60000, 5000], [-3000, 5000]],
        [length("l1", "finish_x + start_len / 2 + 2 * floor_margin"),
         length("l2", "course_w + 2 * floor_margin"),
         v("origin", "l1.start", "course_w / 2 + floor_margin"),
         h("origin", "l1.start", "floor_margin")])
extrude("Floor", "floor_t", "Floor")
colour(["Floor"], "#8a8f96")

# --- start pad --------------------------------------------------------------------------------
outline("StartPad", "XY", "0 mm", ["s1", "s2", "s3", "s4"],
        [[0, -1800], [2400, -1800], [2400, 1800], [0, 1800]],
        [length("s1", "start_len"), length("s2", "course_w"), v("origin", "s1.start", "course_w / 2")],
        on=[("s1.start", "y")])
extrude("StartPad", "pad", "StartPad")
colour(["StartPad"], "#4cbf66")

# --- stairs: one profile per lane, five risers up, a landing, five down -----------------------
for lane, rise in (("a", "rise_a"), ("b", "rise_b"), ("c", "rise_c")):
    ids = ["u0", "t0", "u1", "t1", "u2", "t2", "u3", "t3", "u4", "top",
           "d0", "w0", "d1", "w1", "d2", "w2", "d3", "w3", "d4", "base"]
    pts, x, y = [], 4400, 0
    pts.append([x, y])
    for i in range(5):  # up: riser then tread (the 5th tread is the landing)
        y += 100
        pts.append([x, y])
        x += 1500 if i == 4 else 300
        pts.append([x, y])
    for i in range(5):  # down: riser then tread (the 5th tread is the base, closing)
        y -= 100
        pts.append([x, y])
        if i < 4:
            x += 300
            pts.append([x, y])
    eq = [("t0", t) for t in ("t1", "t2", "t3", "w0", "w1", "w2", "w3")]
    eq += [("u0", r) for r in ("u1", "u2", "u3", "u4", "d0", "d1", "d2", "d3", "d4")]
    outline("Stairs_" + lane, "XZ", f"{LANES[lane]} - lane_w / 2", ids, pts,
            [length("t0", "tread"), length("u0", rise), length("top", "landing")],
            equal=eq, pin="u0.start", at="stairs_x")
    extrude("Stairs_" + lane, "lane_w", "Stairs_" + lane)
colour(["Stairs_a", "Stairs_b", "Stairs_c"], "#f2a633")

# --- ramps: up at the lane's slope to a deck, down at the same slope --------------------------
for lane, slope in (("a", "slope_a"), ("b", "slope_b"), ("c", "slope_c")):
    x0 = 13000
    outline("Ramp_" + lane, "XZ", f"{LANES[lane]} - lane_w / 2", ["up", "deck", "down", "floor"],
            [[x0, 0], [x0 + 3000, 1000], [x0 + 4500, 1000], [x0 + 7500, 0]],
            [length("deck", "deck"), v("origin", "deck.start", "ramp_rise"),
             angle("floor", "up", slope), angle("floor", "down", slope)],
            pin="up.start", at="ramps_x")
    extrude("Ramp_" + lane, "lane_w", "Ramp_" + lane)
colour(["Ramp_a", "Ramp_b", "Ramp_c"], "#5999f2")

# --- stepping stones: a zigzag of posts with growing gaps -------------------------------------
cmd("sketch.create", plane="XY", name="Stones", offset="0 mm")
gaps = ["stone_gap_1", "stone_gap_1", "stone_gap_2", "stone_gap_2", "stone_gap_3", "stone_gap_3"]
along = "stones_x + stone_d / 2"
for i in range(7):
    cx = 30000 + i * 900
    cmd("sketch.circle.center", center=[cx, 150 if i % 2 else -150], diameter=500)
    c = f"c{i}"
    C[-1]["params"]["id"] = c
    if i:
        along += f" + stone_d + {gaps[i - 1]}"
    cmd("sketch.dimension", entities=[c], type="diameter", value="stone_d")
    cmd("sketch.dimension", entities=["origin", f"{c}.center"], type="horizontal", value=along)
    cmd("sketch.dimension", entities=["origin", f"{c}.center"], type="vertical", value="stone_d * 0.3")
cmd("sketch.finish")
cmd("solid.extrude", sketch="Stones", distance="stone_h", direction="positive", operation="new",
    body_name="Stones", profiles="all")
colour(["Stones"], "#d959a6")

# --- bumps: low rolling humps across the whole course -----------------------------------------
cmd("sketch.create", plane="XZ", name="Bumps", offset="-course_w / 2")
start = "bumps_x"
for i in range(4):
    x0 = 40000 + i * 1400
    cmd("sketch.line", points=[[x0, 0], [x0 + 900, 0]], ids=[f"b{i}"], infer=True)
    cmd("sketch.arc.three_point", start=f"b{i}.end", end=f"b{i}.start", through=[x0 + 450, -120])
    C[-1]["params"]["id"] = f"a{i}"
    cmd("sketch.constraint.coincident", a=f"b{i}.start", b="x")
    cmd("sketch.dimension", entities=[f"b{i}"], value="bump_w")
    cmd("sketch.dimension", entities=["origin", f"b{i}.start"], type="horizontal",
        value=f"{start} + {i} * (bump_w + bump_gap)")
    # The arc through a chord bump_w long that rises bump_h: radius (w^2/4 + h^2) / 2h.
    cmd("sketch.dimension", entities=[f"a{i}"], type="radius",
        value="(bump_w * bump_w / 4 + bump_h * bump_h) / (2 * bump_h)")
cmd("sketch.finish")
cmd("solid.extrude", sketch="Bumps", distance="course_w", direction="positive", operation="new",
    body_name="Bumps", profiles="all")
colour(["Bumps"], "#9973e6")

# --- duck under: a beam on two posts (crouch), then a tunnel (crawl) --------------------------
outline("Beam", "YZ", "duck_x", ["g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8"],
        [[-1950, 0], [-1950, 1500], [1950, 1500], [1950, 0], [1800, 0], [1800, 1300],
         [-1800, 1300], [-1800, 0]],
        [length("g2", "course_w + 2 * post"), length("g4", "post"), length("g1", "beam_clear + beam_t"),
         v("origin", "g6.start", "beam_clear")],
        equal=[("g4", "g8")], pin="g1.start", at="course_w / 2 + post")  # pinned to the floor: else a taller beam sinks into it
extrude("Beam", "beam_d", "Beam")
outline("Tunnel", "YZ", "duck_x + beam_d + between", ["n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8"],
        [[-900, 0], [-900, 820], [900, 820], [900, 0], [750, 0], [750, 700], [-750, 700], [-750, 0]],
        [length("n6", "tunnel_inner"), length("n4", "post"), v("origin", "n6.start", "tunnel_clear"),
         length("n1", "tunnel_clear + roof")],
        equal=[("n4", "n8")], pin="n1.start", at="tunnel_inner / 2 + post")
extrude("Tunnel", "tunnel_len", "Tunnel")
colour(["Beam", "Tunnel"], "#f2664c")

# --- jump: two platforms with a gap -----------------------------------------------------------
for name, at in (("PlatformNear", "gap_x"), ("PlatformFar", "gap_x + plat_len + jump_gap")):
    outline(name, "XZ", "-course_w / 2", ["p1", "p2", "p3", "p4"],
            [[50000, 0], [50000, 400], [51500, 400], [51500, 0]],
            [length("p1", "plat_h"), length("p2", "plat_len")], pin="p1.start", at=at)
    extrude(name, "course_w", name)
colour(["PlatformNear", "PlatformFar"], "#40cccc")

# --- finish: a standing ring and a pad --------------------------------------------------------
cmd("sketch.create", plane="YZ", name="Ring", offset="finish_x")
cmd("sketch.circle.center", center=[0, 1200], diameter=2400, id="ro")
cmd("sketch.circle.center", center=[0, 1200], diameter=2100, id="ri")
cmd("sketch.constraint.concentric", a="ro", b="ri")
cmd("sketch.dimension", entities=["ro"], type="diameter", value="ring_d")
cmd("sketch.dimension", entities=["ri"], type="diameter", value="ring_d - 2 * ring_t")
cmd("sketch.dimension", entities=["origin", "ro.center"], type="vertical", value="ring_d / 2 + pad")
cmd("sketch.finish")
# The profile whose outer loop is the outer circle: the inner circle is its hole, a ring.
cmd("solid.extrude", sketch="Ring", distance="ring_depth", direction="positive", operation="new",
    body_name="FinishRing", profiles=[{"curves": ["ro"]}])
outline("FinishPad", "XY", "0 mm", ["f1", "f2", "f3", "f4"],
        [[56000, -1800], [58400, -1800], [58400, 1800], [56000, 1800]],
        [length("f1", "start_len"), length("f2", "course_w"), v("origin", "f1.start", "course_w / 2"),
         h("origin", "f1.start", "finish_x - start_len / 2")])
extrude("FinishPad", "pad", "FinishPad")
colour(["FinishRing", "FinishPad"], "#ffd933")



# --- colliders --------------------------------------------------------------------------------
# The same course as convex pieces for the MuJoCo guest (mujoco.elf's mjc_load_primitives), from
# the same parameters: each piece is exact (a step, a slope, a post), except the ring, which is
# RING_SEGMENTS boxes inside it, within 3 mm of its circles. A record is 12 numbers, in the viewer's
# course frame (y up, metres, the course along -z, across along -x): type (0 box, 1 cylinder
# standing along its local y, 2 walkable box), centre xyz, half sizes xyz, quaternion wxyz, 0.
RING_SEGMENTS = 48


def evaluate(params):
    import math
    env = {"tan": math.tan, "atan": math.atan, "sqrt": math.sqrt, "sin": math.sin, "cos": math.cos}
    for name, expr, _ in params:
        e = expr.replace(" mm", "").replace(" deg", " * 0.017453292519943295")
        env[name] = float(eval(e, {"__builtins__": {}}, env))
    return env


def colliders():
    import math
    v = evaluate(P)
    out = []

    def rec(kind, x, y, z, hx, hy, hz, q=(1.0, 0.0, 0.0, 0.0), name=""):
        # x along, y across, z up, mm (SolidCraft) -> viewer metres; half sizes in the
        # piece's own axes, which the quaternion turns in the viewer frame.
        out.append({"name": name, "prim": [kind, -y / 1000, z / 1000, -x / 1000,
                                             hx / 1000, hy / 1000, hz / 1000, *q, 0]})

    def box(name, x0, x1, y0, y1, z0, z1, walk=True):
        rec(2 if walk else 0, (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2,
            abs(y1 - y0) / 2, abs(z1 - z0) / 2, abs(x1 - x0) / 2, name=name)

    def about_x(a):  # viewer x is across
        return (math.cos(a / 2), math.sin(a / 2), 0.0, 0.0)

    def about_z(a):  # viewer z is along
        return (math.cos(a / 2), 0.0, 0.0, math.sin(a / 2))

    hw, m = v["course_w"] / 2, v["floor_margin"]
    box("Floor", -m, v["finish_x"] + v["start_len"] / 2 + m, -hw - m, hw + m,
        -(v["floor_t"] + v["floor_gap"]), -v["floor_gap"])
    box("StartPad", 0, v["start_len"], -hw, hw, 0, v["pad"])
    fx = v["finish_x"] - v["start_len"] / 2
    box("FinishPad", fx, fx + v["start_len"], -hw, hw, 0, v["pad"])
    for lane, rise in (("a", "rise_a"), ("b", "rise_b"), ("c", "rise_c")):
        y = v["lane_w"] + v["lane_gap"]
        yc = {"a": -y, "b": 0.0, "c": y}[lane]
        y0, y1, t, r = yc - v["lane_w"] / 2, yc + v["lane_w"] / 2, v["tread"], v[rise]
        x = v["stairs_x"]
        for i in range(4):
            box(f"Stairs_{lane}", x + i * t, x + (i + 1) * t, y0, y1, 0, (i + 1) * r)
        xl = x + 4 * t
        box(f"Stairs_{lane}", xl, xl + v["landing"], y0, y1, 0, 5 * r)
        xd = xl + v["landing"]
        for i in range(4):
            box(f"Stairs_{lane}", xd + i * t, xd + (i + 1) * t, y0, y1, 0, (4 - i) * r)
    for lane, slope in (("a", "slope_a"), ("b", "slope_b"), ("c", "slope_c")):
        y = v["lane_w"] + v["lane_gap"]
        yc = {"a": -y, "b": 0.0, "c": y}[lane]
        sl, rise, x0 = v[slope], v["ramp_rise"], v["ramps_x"]
        run = rise / math.tan(sl)
        # A slope is a turned box whose top face is the slope and whose bottom reaches the floor.
        half_len, half_t = rise / math.sin(sl) / 2, rise / math.cos(sl) / 2
        for sign, xa in ((1, x0), (-1, x0 + run + v["deck"])):
            mx, mz = xa + run / 2, rise / 2
            nx, nz = -sign * math.sin(sl), math.cos(sl)
            rec(2, mx - nx * half_t, yc, mz - nz * half_t, v["lane_w"] / 2, half_t, half_len,
                about_x(sign * sl), name=f"Ramp_{lane}")
        box(f"Ramp_{lane}", x0 + run, x0 + run + v["deck"], yc - v["lane_w"] / 2,
            yc + v["lane_w"] / 2, 0, rise)
    gaps = ["stone_gap_1", "stone_gap_1", "stone_gap_2", "stone_gap_2", "stone_gap_3", "stone_gap_3"]
    cx = v["stones_x"] + v["stone_d"] / 2
    for i in range(7):
        if i:
            cx += v["stone_d"] + v[gaps[i - 1]]
        cy = v["stone_d"] * 0.3 * (1 if i % 2 else -1)
        rec(1, cx, cy, v["stone_h"] / 2, v["stone_d"] / 2, v["stone_h"] / 2, 0, name="Stones")
    # A bump is an arc extruded across the course: a lying cylinder, mostly under the floor.
    w, h = v["bump_w"], v["bump_h"]
    rad = (w * w / 4 + h * h) / (2 * h)
    for i in range(4):
        cx = v["bumps_x"] + i * (w + v["bump_gap"]) + w / 2
        rec(1, cx, 0, h - rad, rad, hw, 0, about_z(-math.pi / 2), name="Bumps")
    dx, post = v["duck_x"], v["post"]
    top = v["beam_clear"] + v["beam_t"]
    for sgn in (-1, 1):
        box("Beam", dx, dx + v["beam_d"], sgn * hw, sgn * (hw + post), 0, top, walk=False)
    box("Beam", dx, dx + v["beam_d"], -hw - post, hw + post, v["beam_clear"], top, walk=False)
    tx = dx + v["beam_d"] + v["between"]
    ti, tc = v["tunnel_inner"] / 2, v["tunnel_clear"]
    for sgn in (-1, 1):
        box("Tunnel", tx, tx + v["tunnel_len"], sgn * ti, sgn * (ti + post), 0, tc + v["roof"],
            walk=False)
    box("Tunnel", tx, tx + v["tunnel_len"], -ti - post, ti + post, tc, tc + v["roof"])
    gx = v["gap_x"]
    box("PlatformNear", gx, gx + v["plat_len"], -hw, hw, 0, v["plat_h"])
    gx2 = gx + v["plat_len"] + v["jump_gap"]
    box("PlatformFar", gx2, gx2 + v["plat_len"], -hw, hw, 0, v["plat_h"])
    ro, ri = v["ring_d"] / 2, v["ring_d"] / 2 - v["ring_t"]
    # Each box's outer corners sit on the outer circle and its inner face on the inner one, so
    # every box is inside the ring (at most ro (1 - cos(pi / n)) short of it, 2.6 mm here).
    half = math.pi / RING_SEGMENTS
    outer = ro * math.cos(half)
    rm, zc, x = (ri + outer) / 2, v["ring_d"] / 2 + v["pad"], v["finish_x"] + v["ring_depth"] / 2
    for k in range(RING_SEGMENTS):
        th = 2 * math.pi * (k + 0.5) / RING_SEGMENTS
        # Local x radial: in the viewer, across is -y, so the radial (cos, sin) is (-cos, sin).
        rec(0, x, rm * math.cos(th), zc + rm * math.sin(th), (outer - ri) / 2,
            ro * math.sin(half), v["ring_depth"] / 2, about_z(math.pi - th), name="FinishRing")
    return out


if "--colliders" in sys.argv:
    json.dump({"colliders": colliders()}, sys.stdout, indent=0)
else:
    json.dump({"commands": C}, sys.stdout, indent=1)
sys.stdout.write("\n")
