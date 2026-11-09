#!/usr/bin/env python3
"""Build Model Explorer as godot-sandbox guests: every .gd is compiled by
V-Sekai-fire/entities-godot-sandbox-gdscript-compiler (gdscript_to_riscv) to <name>.sgd.elf with
<name>.gd.remap pointing at it, and every .tscn becomes a build procedure (tscn2gd.py), so the
exported game ships no scene files and GDScript only for PLAIN (below).

    python3 guest/build.py <work dir> <gdscript_to_riscv> <godot_sandbox addon dir> <web template zip> [guest .elf ...]

Each guest .elf (usd.elf, skintokens.elf) is copied to res:// for OpenUSD input and the .vrm step.

Then export the work dir: godot --resolution 640x360 --path <work dir> --export-release Web out/index.html
Prints one line per script and a summary; exit 1 if any script fails.
"""
import json, pathlib, re, shutil, subprocess, sys, concurrent.futures

here = pathlib.Path(__file__).resolve().parent
src = here.parent
work, compiler, addon, template = (pathlib.Path(x).resolve() for x in sys.argv[1:5])
guest_elfs = [pathlib.Path(x).resolve() for x in sys.argv[5:]]
# Scripts that run a second Sandbox (usd.elf, skintokens.elf, headfit.elf) or are called back by
# glTF extensions while they do stay plain GDScript: a guest script that enters another guest
# machine fails on the web ("Too many VM calls in progress", or a JSPI SuspendError).
PLAIN_FILES = {'vsk_model_explorer/core/UsdImport.gd', 'vsk_model_explorer/core/VrmExport.gd',
               'vsk_model_explorer/core/AutoRig.gd', 'vsk_model_explorer/core/Bintr.gd',
               'vsk_model_explorer/core/FaceBlink.gd', 'vsk_model_explorer/core/FaceRoles.gd',
               'vsk_model_explorer/core/Motion.gd',
               'vsk_model_explorer/core/MotionMatch.gd', 'vsk_model_explorer/core/MotionMatchNode.gd'}
PLAIN_DIRS = ('addons/vrm/',)
overlay = here / 'overlay'
if work.exists():
    shutil.rmtree(work)
shutil.copytree(src, work, ignore=shutil.ignore_patterns('.git', '.godot', '*.uid', 'guest', '.lake', 'lean'))
shutil.copytree(addon, work / 'addons/godot_sandbox', dirs_exist_ok=True)
for e in guest_elfs:
    shutil.copy(e, work / e.name)
# Walk mode's clips (MM_DATA, ':'-separated clip dirs as in tools/package_desktop.sh) go to
# res://motion/mm: one .f32 per clip, clips.tsv, and the SOMA skeleton of the first clip.
import os
mm_sets = [d for d in os.environ.get('MM_DATA', '').split(':') if d]
if mm_sets:
    mm = work / 'motion/mm'
    mm.mkdir(parents=True, exist_ok=True)
    keys, first = [], None
    for d in mm_sets:
        for c in sorted(p for p in pathlib.Path(d).iterdir() if p.is_dir()):
            shutil.copy(c / 'transforms.f32', mm / (c.name + '.f32'))
            if (c / 'phase.f32').exists():
                shutil.copy(c / 'phase.f32', mm / (c.name + '.phase.f32'))
            # Same clips.tsv as tools/package_desktop.sh: "<key>\tloop" for a clip cut as a loop.
            keys.append(c.name + ('\tloop' if (c / 'loop.txt').exists() else ''))
            first = first or c
    (mm / 'clips.tsv').write_text(''.join(k + '\n' for k in keys))
    (mm / 'skeleton.txt').write_text(''.join((first / 'skeleton.txt').read_text().splitlines(True)[3:]))
    shutil.copy(first / 'parents.txt', mm / 'parents.txt')
    print('MM clips', len(keys))
if overlay:
    shutil.copytree(overlay, work, dirs_exist_ok=True)
ep = work / 'export_presets.cfg'
ep.write_text(re.sub(r'custom_template/(release|debug)=""', lambda m: 'custom_template/%s="%s"' % (m.group(1), template), ep.read_text()))
# Editor-only parts of the sandbox addon: the game needs only bin/.
for f in list((work / 'addons/godot_sandbox').iterdir()):
    if f.is_file():
        f.unlink()
# The MCP server is for the desktop viewer only: a web page cannot listen and has no stdin.
shutil.rmtree(work / 'addons/vsekai_godot_mcp', ignore_errors=True)
(work / 'vsk_model_explorer/core/RigTools.gd').unlink(missing_ok=True)
# Scenes become procedures compiled into the guests (tscn2gd.py); the main scene is an empty Node
# and the Boot autoload builds the app.
r = subprocess.run([sys.executable, str(here / 'tscn2gd.py'), str(work)], capture_output=True, text=True)
print(r.stdout.strip()); 
if r.returncode:
    sys.exit('tscn2gd: ' + r.stderr.strip())
pgp = work / 'project.godot'
pg = pgp.read_text()
pg = re.sub(r'^MCP=.*\n', '', pg, flags=re.M)
pg = re.sub(r'\n\[vsekai_godot_mcp\]\n[\s\S]*?(?=\n\[|\Z)', '', pg)
pg = re.sub(r'run/main_scene="[^"]*"', 'run/main_scene="res://boot.tscn"', pg)
pg = re.sub(r'^(\[autoload\]\n\n(?:\w+=.*\n)*)', lambda m: m.group(1) + 'Boot="*res://boot.gd"\n', pg, count=1, flags=re.M)
pg = re.sub(r'^\[editor_plugins\]\n\nenabled=.*\n', '', pg, flags=re.M)
# WebGPU 2D MSAA gives a sample-count mismatch in the render pass (engine bug, noted); web only.
pg = pg.replace('anti_aliasing/quality/msaa_2d=2\n', 'anti_aliasing/quality/msaa_2d=2\nanti_aliasing/quality/msaa_2d.web=0\n')
# Forward+ on WebGPU draws the 3D view black with no error (engine bug, noted); Mobile draws it.
pg = pg.replace('[rendering]\n\n', '[rendering]\n\nrenderer/rendering_method.web="mobile"\n', 1)
# Physical light units need the scene's exposure settings, which the light studio drops: off.
pg = pg.replace('lights_and_shadows/use_physical_light_units=true\n', 'lights_and_shadows/use_physical_light_units=false\n')
# The web loading screen takes the boot splash colour: light, like the page, not black.
pg = pg.replace('boot_splash/show_image=false\n', 'boot_splash/show_image=false\nboot_splash/bg_color=Color(0.93, 0.93, 0.92, 1)\n')
# Never a black frame: the clear colour is light too, for any frame before the backdrop draws.
pg = pg.replace('[rendering]\n\n', '[rendering]\n\nenvironment/defaults/default_clear_color=Color(0.93, 0.93, 0.92, 1)\n', 1)
pgp.write_text(pg)

files = sorted(p for p in work.rglob('*.gd') if '.godot' not in p.parts)
# Relative load paths ("./x.gd", "x.gd") are made absolute: the compiled guest asks the host
# to load the literal string, and the host resolves it against res://.
for p in files:
    t = p.read_text(errors='replace')
    d = p.parent.relative_to(work).as_posix()
    def absol(m):
        path = m.group(2)
        if path.startswith('res://') or path.startswith('user://') or '/' not in path and not path.endswith(('.gd', '.tscn', '.tres', '.res', '.gdshader', '.png')):
            return m.group(0)
        full = (pathlib.PurePosixPath(d) / path).as_posix()
        parts = []
        for seg in full.split('/'):
            if seg in ('', '.'):
                continue
            if seg == '..':
                parts.pop()
            else:
                parts.append(seg)
        return m.group(1) + 'res://' + '/'.join(parts) + '"'
    u = re.sub(r'((?:preload|load)\(\s*")([^"]+)"', absol, t)
    if u != t:
        p.write_text(u)
srcs = {p: p.read_text(errors='replace') for p in files}
rel = {p: p.relative_to(work).as_posix() for p in files}
classes = {}
for p, s in srcs.items():
    m = re.search(r'^class_name\s+(\w+)', s, re.M)
    if m:
        classes[m.group(1)] = p
pg = (work / 'project.godot').read_text()
m = re.search(r'^\[autoload\]\n(.*?)(?=^\[|\Z)', pg, re.M | re.S)
autoloads = [l.split('=')[0].strip() for l in m.group(1).splitlines() if '=' in l] if m else []
common = [str(compiler), '--double-precision']
for n in autoloads:
    common += ['--autoload', n]
for n, p in classes.items():
    common += ['--global-class', f'{n}=res://{rel[p]}']

def extends_of(s):
    for line in s.splitlines():
        m = re.match(r'^\s*extends\s+(.+?)\s*(#.*)?$', line)
        if m:
            return m.group(1).strip()

def chain(p):
    out, seen, cur = [], set(), p
    while True:
        e = extends_of(srcs[cur])
        if not e:
            break
        q = None
        if e[0] in '"\'' and e[-1] == e[0]:
            path = e[1:-1]
            q = work / path[6:] if path.startswith('res://') else (cur.parent / path).resolve()
            name = path
        elif e in classes:
            q, name = classes[e], e
        if q is None or q not in srcs or q in seen:
            break
        seen.add(q); out.append((name, q)); cur = q
    return list(reversed(out))

def build(p):
    elf = p.with_name(p.stem + '.sgd.elf')
    bases = [x for n, q in chain(p) for x in ('--base', f'{n}={q}')]
    r = subprocess.run([*common, *bases, '-o', str(elf), str(p)], cwd=work, capture_output=True, text=True, timeout=300)
    ok = r.returncode == 0 and elf.exists()
    if ok:
        p.with_name(p.name + '.remap').write_text('[remap]\n\npath="res://%s"\n' % elf.relative_to(work).as_posix())
    msg = '' if ok else ((r.stderr or r.stdout).strip().splitlines() or ['no ELF'])[0][:240]
    return rel[p], ok, elf.stat().st_size if ok else 0, msg

def plain(p):
    r = rel[p]
    return r in PLAIN_FILES or r.startswith(PLAIN_DIRS)

# A plain script that names a class compiled into a guest fails to parse on the web ("Could not
# find type"): compiled scripts are not global classes for stock GDScript. So every class a plain
# script names (and what those name in turn) stays plain too.
def strip_comments(s):
    return re.sub(r'#[^\n]*', '', s)

grew = True
while grew:
    grew = False
    for p in [q for q in files if plain(q)]:
        body = strip_comments(srcs[p])
        for n, q in classes.items():
            if q != p and not plain(q) and re.search(r'\b%s\b' % re.escape(n), body):
                PLAIN_FILES.add(rel[q])
                print('PLAIN-BY-USE', rel[q], 'named in', rel[p])
                grew = True

compiled = [p for p in files if not plain(p)]
# The export leaves out every compiled script's source, and keeps the plain ones.
ep.write_text(ep.read_text().replace('exclude_filter="*.gd"', 'exclude_filter="%s"' % ','.join(rel[p] for p in compiled)))
print('PLAIN', ' '.join(sorted(rel[p] for p in files if plain(p))))
with concurrent.futures.ThreadPoolExecutor(8) as ex:
    rows = list(ex.map(build, compiled))
for name, ok, size, msg in rows:
    print(('OK  ' if ok else 'BAD ') + name, size, msg)
good = sum(1 for r in rows if r[1])
print(json.dumps({'scripts': len(rows), 'ok': good, 'elf_bytes': sum(r[2] for r in rows)}))
sys.exit(0 if good == len(rows) else 1)
