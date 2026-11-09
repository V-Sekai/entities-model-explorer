"""Drive the desktop viewer through its MCP server with the official MCP Python SDK: list the
trimmed tools, open a model, auto-rig it, take the result back and a screenshot.

    pixi exec -s python=3.12 -s "mcp>=2.3" python tools/mcp_check.py <godot> <model.glb>

<godot> runs this project (the editor binary with --path, or an exported viewer). The rig needs
the weights in `w`, skintokens.elf and the godot-sandbox library, as the R key does. Exits 1 on
any failed check.
"""

import asyncio
import base64
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

from mcp.client.client import Client

ROOT = Path(__file__).resolve().parent.parent
TOOLS = {"status", "load_model", "auto_rig", "get_file", "screenshot", "ping", "get_scene_tree",
         "get_node", "get_property", "find_nodes", "get_aabb", "get_bone_poses"}
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def data(result):
    if result.structured_content is not None:
        return result.structured_content
    return json.loads(result.content[0].text)


async def run(client, model):
    names = {t.name for t in (await client.list_tools()).tools}
    check(names == TOOLS, f"tools/list: {len(names)} tools, the trimmed set")
    st = data(await client.call_tool("status", {}))
    check(st.get("can_rig") is True and st.get("busy") is False, f"status: {st}")
    t0 = time.time()
    opened = await client.call_tool("load_model", {"path": str(model)})
    check(not opened.is_error and data(opened).get("file") == model.name, f"load_model {model.name} ({time.time() - t0:.1f} s)")
    tree = data(await client.call_tool("get_scene_tree", {"max_depth": 2}))
    check(isinstance(tree, dict) and tree.get("name"), f"get_scene_tree root {tree.get('name')}")
    t0 = time.time()
    rig = await client.call_tool("auto_rig", {}, read_timeout_seconds=1800)
    r = data(rig) if not rig.is_error else {}
    check(not rig.is_error and r.get("result"), f"auto_rig -> {r.get('file') or rig.content[0].text} ({time.time() - t0:.0f} s)")
    if r.get("result"):
        got = await client.call_tool("get_file", {})
        blob = next((c for c in got.content if c.type == "resource"), None)
        raw = base64.b64decode(blob.resource.blob) if blob else b""
        on_disk = Path(r["result"]).read_bytes()
        check(raw == on_disk and raw[:4] == b"glTF", f"get_file: {len(raw)} bytes, same as the file, glTF magic")
        skel = data(await client.call_tool("find_nodes", {"type": "Skeleton3D"}))
        check(len(skel.get("nodes", skel if isinstance(skel, list) else [])) >= 1, f"find_nodes Skeleton3D in the result: {str(skel)[:120]}")
    shot = await client.call_tool("screenshot", {"max_width": 640})
    img = next((c for c in shot.content if c.type == "image"), None)
    png = base64.b64decode(img.data) if img else b""
    check(png[:8] == b"\x89PNG\r\n\x1a\n", f"screenshot: {len(png)} bytes PNG")
    if png:
        Path("/tmp/mcp_check_screenshot.png").write_bytes(png)
    gone = None
    try:
        gone = (await client.call_tool("set_property", {"path": ".", "property": "name", "value": "x"})).is_error
    except Exception as e:
        gone = "unknown tool" in str(e)
    check(gone, "set_property is trimmed away")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def main():
    godot, model = sys.argv[1], Path(sys.argv[2]).resolve()
    base = [godot, "--path", str(ROOT)]
    port = free_port()
    proc = subprocess.Popen([*base, "--", f"--mcp-port={port}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(240):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
                break
            except OSError:
                time.sleep(0.5)
        async with Client(f"http://127.0.0.1:{port}/mcp", mode="auto", read_timeout_seconds=1800) as client:
            check(client.session.protocol_version == "2026-07-28", f"http: {client.session.protocol_version}")
            await run(client, model)
    finally:
        proc.terminate()
        proc.wait(timeout=30)
    print(f"\n[mcp_check] {len(failures)} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    asyncio.run(main())
