#!/usr/bin/env python3
"""Turn Godot .tscn scenes into GDScript builders, so a scene is a procedure compiled into the
script's .sgd.elf instead of data that names scripts.

    tscn2gd.py <project dir>

For every res://X/Name.tscn this writes res://X/Name_scene.gd with `static func instantiate()`
(the same call a PackedScene answers), rewrites preload/load of the .tscn in every .gd to the
builder, deletes the .tscn, and prints one line per scene. Supported: ext_resource (scripts are
attached, other resources loaded), sub_resource, nested nodes, instance=, groups=, node_paths=
(Node exports resolved after the tree is built), [connection]. Anything else stops the build.
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1]).resolve()
HEAD = re.compile(r'^\[(\w+)((?:\s+\w+=(?:"[^"]*"|\S+?))*)\s*\]$')
ATTR = re.compile(r'(\w+)=("(?:[^"\\]|\\.)*"|PackedStringArray\([^)]*\)|\[[^\]]*\]|ExtResource\("[^"]*"\)|[^\s\]]+)')

def sections(text):
    cur = None
    for line in text.splitlines():
        if line.startswith('[') and line.rstrip().endswith(']'):
            m = HEAD.match(line.strip())
            if not m:
                raise SystemExit(f'unparsed header: {line}')
            cur = {'tag': m.group(1), 'attrs': dict((k, v) for k, v in ATTR.findall(m.group(2))), 'props': []}
            yield cur
        elif cur is not None and ' = ' in line and not line.startswith(' '):
            k, v = line.split(' = ', 1)
            cur['props'].append([k, v])
        elif cur is not None and line.strip() and cur['props']:
            cur['props'][-1][1] += '\n' + line  # continuation of a multi-line value
        elif line.strip():
            raise SystemExit(f'unparsed line: {line}')

unq = lambda s: s[1:-1] if s.startswith('"') else s
ident = lambda s: re.sub(r'\W', '_', s)

def convert(tscn):
    ext, sub, out, nodes, conns = {}, {}, [], [], []
    rel = tscn.relative_to(root).as_posix()
    for s in sections(tscn.read_text()):
        t, a = s['tag'], s['attrs']
        if t == 'gd_scene':
            continue
        if t == 'ext_resource':
            ext[unq(a['id'])] = (unq(a['type']), unq(a['path']))
        elif t == 'sub_resource':
            sub[unq(a['id'])] = s
        elif t == 'node':
            nodes.append(s)
        elif t == 'connection':
            conns.append(a)
        else:
            raise SystemExit(f'{rel}: unsupported section [{t}]')

    def value(v):
        def er(m):
            typ, path = ext[m.group(1)]
            if path.endswith('.tscn'):
                return f'preload("{path[:-5]}_scene.gd").new()'
            return f'load("{path}")'
        v = re.sub(r'ExtResource\("([^"]*)"\)', er, v)
        v = re.sub(r'SubResource\("([^"]*)"\)', lambda m: 'r_' + ident(m.group(1)), v)
        def t3(m):
            # Text Transform3D lists basis rows then origin; GDScript's Basis() takes columns.
            n = [x.strip() for x in m.group(1).split(',')]
            col = lambda c: f'Vector3({n[c]}, {n[3 + c]}, {n[6 + c]})'
            return f'Transform3D(Basis({col(0)}, {col(1)}, {col(2)}), Vector3({n[9]}, {n[10]}, {n[11]}))'
        v = re.sub(r'Transform3D\(((?:[^,()]+,){11}[^,()]+)\)', t3, v)
        if re.search(r'\bObject\(', v):
            raise SystemExit(f'{rel}: Object() values are not supported: {v[:80]}')
        return v

    out.append(f'# Generated from {rel} by tscn2gd.py: the scene as a procedure. Do not edit.')
    out.append('extends RefCounted\n')
    out.append('func instantiate() -> Node:')
    for sid, s in sub.items():
        out.append(f'\tvar r_{ident(sid)} = {unq(s["attrs"]["type"])}.new()')
        for k, v in s['props']:
            out.append(f'\tr_{ident(sid)}.set("{k}", {value(v)})')
    names = {}
    for i, n in enumerate(nodes):
        a = n['attrs']
        var = 'root' if i == 0 else f'n{i}'
        parent = unq(a['parent']) if 'parent' in a else None
        path = '.' if parent is None else (unq(a['name']) if parent == '.' else parent + '/' + unq(a['name']))
        names[path] = var
        if 'instance' in a:
            out.append(f'\tvar {var}: Node = {value(a["instance"])}.instantiate()')
        else:
            out.append(f'\tvar {var}: Node = {unq(a["type"])}.new()')
        out.append(f'\t{var}.name = "{unq(a["name"])}"')
        props = dict(n['props'])
        if 'script' in props:
            sid = re.match(r'ExtResource\("([^"]*)"\)', props['script']).group(1)
            out.append(f'\t{var}.set_script(load("{ext[sid][1]}"))')
        if parent is not None:
            out.append(f'\t{names[parent]}.add_child({var})')
            out.append(f'\t{var}.owner = root')
        node_paths = re.findall(r'"([^"]*)"', a.get('node_paths', ''))
        for k, v in n['props']:
            if k == 'script' or k in node_paths:
                continue
            out.append(f'\t{var}.set("{k}", {value(v)})')
        for g in re.findall(r'"([^"]*)"', a.get('groups', '')):
            out.append(f'\t{var}.add_to_group("{g}", true)')
        n['var'], n['node_paths'] = var, node_paths
    for n in nodes:
        for k, v in n['props']:
            if k in n['node_paths']:
                out.append(f'\t{n["var"]}.set("{k}", {n["var"]}.get_node({v}))')
    for c in conns:
        src, dst = names[unq(c['from'])], names[unq(c['to'])]
        flags = int(c.get('flags', '0'))
        out.append(f'\t{src}.connect("{unq(c["signal"])}", Callable({dst}, "{unq(c["method"])}"), {flags})')
    out.append('\treturn root\n')
    return '\n'.join(out)

scenes = sorted(p for p in root.rglob('*.tscn') if '.godot' not in p.parts and p.name != 'boot.tscn' and 'guest' not in p.relative_to(root).parts)
for p in scenes:
    gd = p.with_name(p.stem + '_scene.gd')
    gd.write_text(convert(p))
    print(f'{p.relative_to(root)} -> {gd.relative_to(root)}')
for g in root.rglob('*.gd'):
    s = g.read_text(errors='replace')
    t = re.sub(r'((?:pre)?load\(\s*"res://[^"]*?)\.tscn"', r'\1_scene.gd"', s)
    # A builder is a script, not a PackedScene: X.instantiate() becomes X.new().instantiate().
    for name in re.findall(r'^const\s+(\w+)\s*=\s*preload\("res://[^"]*_scene\.gd"\)', t, re.M):
        t = re.sub(r'\b%s\.instantiate\(' % name, name + '.new().instantiate(', t)
    if t != s:
        g.write_text(t)
for p in scenes:
    p.unlink()
