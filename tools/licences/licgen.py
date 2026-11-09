"""Write LICENSE.md, NOTICE and CITATION.cff for both desktop download repos from one parts list.

    python3 tools/licences/licgen.py <out dir>      -> <out>/skintokens/{LICENSE.md,NOTICE,CITATION.cff}
                                        <out>/kimodo-motion/{...}
                                        <out>/walk-mode/{...} (no weights)

Both viewers ship the same pck contents (skintokens.elf, motion.elf, usd.elf, headfit.elf, mm.elf, liltoon.tar
and its walk-mode clips, mujoco.elf and the obstacle course, the 18 prompt
embeddings); they differ only in the weights in w/. Licence texts in src/ are copied from each
part's own repository; src/old-citations.yaml holds the reference entries of the two
CITATION.cff files as first published. Upload the three files to each HF repo, then give that
folder to `package_desktop.sh package` as NOTICES. Change a part here, never in the HF repos.
"""
import datetime
import os
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")

FIRE = {"family-names": "Lee", "given-names": "K. S. Ernest (iFire)", "alias": "fire",
        "website": "https://github.com/fire"}

VIEWERS = {
    "skintokens": {
        "app": "skintokens-viewer",
        "title": "SkinTokens viewer (desktop downloads)",
        "repo": "chibifire/interactor-skintokens-viewer",
        "weights": "skintokens",
    },
    "kimodo-motion": {
        "app": "kimodo-motion-viewer",
        "title": "Kimodo motion viewer (desktop downloads)",
        "repo": "chibifire/interactor-kimodo-motion-viewer",
        "weights": "kimodo",
    },
    "walk-mode": {
        "app": "walk-mode-viewer",
        "title": "Walk mode viewer (desktop downloads)",
        "repo": "chibifire/interactor-walk-mode-viewer",
        "weights": "none",
    },
}

GH = "https://github.com/"


def read(name):
    with open(os.path.join(SRC, name)) as f:
        return f.read().strip()


def text_block(name):
    """A src/*.md section already holds its ```text fences; a raw licence file gets them here."""
    t = read(name)
    return t if t.startswith("```") or "\n```" in t[:40] else "```text\n" + t + "\n```"


# (part, where, licence, licence-text section title, citation reference, viewers)
# where: {pck} -> the viewer's pck name, {app} -> the program name.
PARTS = [
    ("[interactor-skintokens-guest](" + GH + "V-Sekai-fire/interactor-skintokens-guest) (rig program `skintokens.elf`)",
     "`skintokens.elf` in `{pck}`",
     "All rights reserved. Licensed only to K. S. Ernest (iFire) Lee; a free and open-source licence is not yet decided",
     "interactor-skintokens-guest", "interactor-skintokens-guest", None),
    ("[skin-tokens-ggml](" + GH + "V-Sekai-fire/skin-tokens-ggml)", "inside `skintokens.elf`", "Apache-2.0",
     None, "skin-tokens-ggml", None),
    ("[SkinTokens](" + GH + "VAST-AI-Research/SkinTokens) by VAST-AI-Research (the model code that skin-tokens-ggml follows)",
     "inside `skintokens.elf`", "MIT", "SkinTokens", "SkinTokens (TokenRig)", None),
    ("[interactor-motion-guest](" + GH + "V-Sekai-fire/interactor-motion-guest) (animation program `motion.elf`)",
     "`motion.elf` in `{pck}`", "MIT", "interactor-motion-guest", "interactor-motion-guest", None),
    ("[kimodo-ggml](" + GH + "V-Sekai-fire/kimodo-ggml) and [motion-bricks-ggml](" + GH + "V-Sekai-fire/motion-bricks-ggml)",
     "inside `motion.elf`", "Apache-2.0", None, "kimodo-ggml", None),
    ("[Kimodo](" + GH + "nv-tlabs/kimodo) by NVIDIA (the model code that kimodo-ggml follows)",
     "inside `motion.elf`", "Apache-2.0", None, "Kimodo", None),
    ("[ggml](" + GH + "ggml-org/ggml)", "inside `skintokens.elf` and `motion.elf`", "MIT", "ggml", "ggml", None),
    ("[ggml-rd](" + GH + "V-Sekai-fire/contract-ggml-rd)", "inside `skintokens.elf` and `motion.elf`", "MIT",
     "ggml-rd", "ggml-rd", None),
    ("[nlohmann/json](" + GH + "nlohmann/json)", "inside `skintokens.elf`", "MIT", "nlohmann/json",
     "JSON for Modern C++", None),
    ("[interactor-headfit](" + GH + "V-Sekai-fire/interactor-headfit) (eye-close shapes `headfit.elf`)",
     "`headfit.elf` in `{pck}`", "MIT", "interactor-headfit", "interactor-headfit", None),
    ("[interactor-motion-matching-guest](" + GH + "V-Sekai-fire/interactor-motion-matching-guest) (walk mode "
     "`mm.elf`, a port of [godot-motion-matching](" + GH + "V-Sekai/godot-motion-matching) by Guilherme Sousa)",
     "`mm.elf` in `{pck}`", "MIT", "interactor-motion-matching-guest", "interactor-motion-matching-guest", None),
    ("Walk-mode clips from the [O3DE MotionMatching gem](" + GH + "o3de/o3de/tree/development/Gems/MotionMatching) "
     "(motion capture, moved onto the SOMA skeleton)",
     "`motion/mm/*.f32` in `{pck}`", "Apache-2.0 OR MIT (used here under MIT)",
     "O3DE MotionMatching gem clips", "O3DE MotionMatching gem", None),
    ("Walk-mode clips made with [Kimodo-SOMA-RP-v1.1](https://huggingface.co/nvidia/Kimodo-SOMA-RP-v1.1) (NVIDIA) "
     "by `motion.elf`. They are the output of a program; no person wrote them. The package does not contain "
     "the Kimodo weights unless listed below",
     "`motion/mm/*.f32` in `{pck}`", "Output of a model under the NVIDIA Open Model License",
     None, "Kimodo-SOMA-RP-v1.1", None),
    ("[mujoco-sandbox-demo](" + GH + "V-Sekai-fire/interactor-mujoco-sandbox-demo) (the obstacle course's "
     "collisions, `mujoco.elf`)", "`mujoco.elf` in `{pck}`", "MIT", "mujoco-sandbox-demo", "mujoco-sandbox-demo", None),
    ("[MuJoCo](" + GH + "google-deepmind/mujoco) 3.14.0 by Google DeepMind", "inside `mujoco.elf`", "Apache-2.0",
     None, "MuJoCo", None),
    ("[libccd](" + GH + "danfis/libccd)", "inside `mujoco.elf`", "BSD-3-Clause", "libccd", "libccd", None),
    ("[Qhull](http://www.qhull.org)", "inside `mujoco.elf`", "Qhull licence", "Qhull", "Qhull", None),
    ("[TinyXML-2](" + GH + "leethomason/tinyxml2)", "inside `mujoco.elf`", "Zlib", "TinyXML-2", "TinyXML-2", None),
    ("[tinyobjloader](" + GH + "tinyobjloader/tinyobjloader)", "inside `mujoco.elf`", "MIT", "tinyobjloader",
     "tinyobjloader", None),
    ("[miniz](" + GH + "richgel999/miniz)", "inside `mujoco.elf`", "MIT", "miniz", "miniz", None),
    ("[LodePNG](" + GH + "lvandeve/lodepng)", "inside `mujoco.elf`", "Zlib", "LodePNG", "LodePNG", None),
    ("Grid balls from [xr-grid](" + GH + "V-Sekai/xr-grid) (the floor grid)", "in `{pck}`", "MIT", "xr-grid",
     "xr-grid", None),
    ("[Model Explorer](" + GH + "V-Sekai-fire/entities-model-explorer) (the viewer)", "`{pck}`", "MIT",
     "Model Explorer", "Model Explorer", None),
    ("[lilToon](" + GH + "lilxyzw/lilToon) by lilxyzw (toon shader files the asset package export adds to each "
     "`.unitypackage`)", "`liltoon.tar` in `{pck}`", "MIT", "lilToon", "lilToon", None),
    ("[godot-vrm and Godot-MToon-Shader](" + GH + "V-Sekai/godot-vrm)", "in `{pck}`", "MIT",
     "godot-vrm and Godot-MToon-Shader", "godot-vrm and Godot-MToon-Shader", None),
    ("[interactor-usd-guest](" + GH + "V-Sekai-fire/interactor-usd-guest) (OpenUSD reader `usd.elf`)",
     "`usd.elf` in `{pck}`", "MIT", "interactor-usd-guest", "interactor-usd-guest", None),
    ("[OpenUSD](https://openusd.org)", "inside `usd.elf`", "Tomorrow Open Source Technology License 1.0",
     "OpenUSD (Tomorrow Open Source Technology License 1.0, with its third-party notices)", "OpenUSD", None),
    ("[oneTBB](" + GH + "uxlfoundation/oneTBB)", "inside `usd.elf`", "Apache-2.0", None, "oneTBB", None),
    ("[Godot Engine](https://godotengine.org)", "`{app}` program",
     "MIT (third-party parts: [COPYRIGHT.txt](" + GH + "godotengine/godot/blob/master/COPYRIGHT.txt))",
     "Godot Engine", "Godot Engine", None),
    ("[godot-sandbox](" + GH + "V-Sekai-fire/godot-sandbox)", "`libgodot_riscv` library", "BSD-3-Clause",
     "godot-sandbox", "godot-sandbox", None),
    ("[libriscv](" + GH + "libriscv/libriscv)", "inside the `libgodot_riscv` library", "BSD-3-Clause",
     "libriscv", "libriscv", None),
    ("Prompt embeddings of the 18 animation clips, made ahead of time by the LLM2Vec encoder "
     "[chibifire/Llama-3-Kimodo-GGML](https://huggingface.co/chibifire/Llama-3-Kimodo-GGML) (Meta Llama 3). "
     "They are the output of a program; no person wrote them. The package does not contain the encoder",
     "`motion/*.f32` in `{pck}`", "Output of a model under the Meta Llama 3 Community License",
     "Meta Llama 3 Community License", "Llama-3-Kimodo-GGML (LLM2Vec encoder, Meta Llama 3)", None),
    ("[SkinTokens](https://huggingface.co/VAST-AI/SkinTokens) weights by VAST-AI-Research, as "
     "[chibifire/SkinTokens-GGUF-BF16](https://huggingface.co/chibifire/SkinTokens-GGUF-BF16)",
     "`w/*.gguf`", "MIT", None, "SkinTokens-GGUF-BF16", {"skintokens"}),
    ("[Kimodo-SOMA-RP-v1.1](https://huggingface.co/nvidia/Kimodo-SOMA-RP-v1.1) weights by NVIDIA, as "
     "[chibifire/Kimodo-SOMA-RP-v1.1-gguf](https://huggingface.co/chibifire/Kimodo-SOMA-RP-v1.1-gguf)",
     "`w/Kimodo-SOMA-RP-v1.1-gguf/`", "NVIDIA Open Model License",
     "Kimodo-SOMA-RP-v1.1 (NVIDIA Open Model License)", "Kimodo-SOMA-RP-v1.1", {"kimodo"}),
]

APACHE_TITLE = ("skin-tokens-ggml, kimodo-ggml, motion-bricks-ggml, Kimodo, MuJoCo and oneTBB "
                "(Apache License 2.0)")

# Licence-text sections in order: (title, body)
def sections(weights):
    s = [("interactor-skintokens-guest", text_block("interactor_skintokens_guest.md")),
         (APACHE_TITLE, "Kimodo: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.\n"
          "MuJoCo: Copyright 2021 DeepMind Technologies Limited.\n\n"
          + text_block("skin_tokens_ggml_and_oneTBB.md")),
         ("skin-tokens-ggml NOTICE", text_block("skin_tokens_ggml_NOTICE.md")),
         ("kimodo-ggml NOTICE", text_block("kimodo-ggml.NOTICE")),
         ("SkinTokens", text_block("SkinTokens.md")),
         ("interactor-motion-guest", text_block("motion-guest.LICENSE")),
         ("ggml", text_block("ggml.md")),
         ("ggml-rd", text_block("ggml_rd.md")),
         ("nlohmann/json", text_block("nlohmann_json.md")),
         ("interactor-headfit", text_block("headfit.LICENSE")),
         ("interactor-motion-matching-guest", text_block("motion-matching-guest.LICENSE")),
         ("O3DE MotionMatching gem clips (MIT)", text_block("o3de.MIT.LICENSE")),
         ("mujoco-sandbox-demo", text_block("mujoco-sandbox-demo.LICENSE")),
         ("libccd", text_block("libccd.BSD")),
         ("Qhull", text_block("qhull.COPYING")),
         ("TinyXML-2", text_block("tinyxml2.LICENSE")),
         ("tinyobjloader", text_block("tinyobjloader.LICENSE")),
         ("miniz", text_block("miniz.LICENSE")),
         ("LodePNG", text_block("lodepng.LICENSE")),
         ("xr-grid", text_block("xr-grid.LICENSE")),
         ("Model Explorer", text_block("Model_Explorer.md")),
         ("lilToon", text_block("liltoon.LICENSE")),
         ("godot-vrm and Godot-MToon-Shader", text_block("godot_vrm_and_Godot_MToon_Shader.md")),
         ("interactor-usd-guest", text_block("interactor_usd_guest.md")),
         ("Godot Engine", text_block("Godot_Engine.md")),
         ("godot-sandbox", text_block("godot_sandbox.md")),
         ("libriscv", text_block("libriscv.md")),
         ("OpenUSD (Tomorrow Open Source Technology License 1.0, with its third-party notices)",
          text_block("OpenUSD.md"))]
    if weights == "kimodo":
        s.append(("Kimodo-SOMA-RP-v1.1 (NVIDIA Open Model License)", text_block("nvidia-oml.LICENSE")))
    s.append(("Meta Llama 3 Community License (the encoder that made the prompt embeddings)",
              text_block("llama3.LICENSE")))
    return s


def license_md(v):
    pck = v["app"] + ".pck"
    rows = [f"| {p} | {w.format(pck=pck, app=v['app'])} | {l} |"
            for p, w, l, _, _, only in PARTS if only is None or v["weights"] in only]
    out = ["# Licences", "",
           "The packages in this repository hold parts with different licences. This file lists each part,",
           "its licence, and the full licence text. `CITATION.cff` and this file give the same information.",
           "Each package contains a copy of this file, of `CITATION.cff` and of `NOTICE`.", "",
           "## Parts and licences", "", "| Part | Where it is in a package | Licence |", "|---|---|---|",
           *rows, "",
           "Because the rig program is not under a free and open-source licence, the packages as a whole",
           "are not either. All other parts keep their own licences, given below.", "",
           "## Licence texts", ""]
    for title, body in sections(v["weights"]):
        out += [f"### {title}", "", body, ""]
    return "\n".join(out)


def notice(v):
    lines = []
    if v["weights"] == "kimodo":
        lines += ["Licensed by NVIDIA Corporation under the NVIDIA Open Model License",
                  "(Kimodo-SOMA-RP-v1.1, in w/Kimodo-SOMA-RP-v1.1-gguf/).", ""]
    lines += ["Built with Meta Llama 3. Meta Llama 3 is licensed under the Meta Llama 3 Community License,",
              "Copyright © Meta Platforms, Inc. All Rights Reserved. (The prompt embeddings in",
              f"{v['app']}.pck are the output of an LLM2Vec encoder based on Meta Llama 3.)", "",
              "LICENSE.md lists every part of this package with its full licence text.", ""]
    return "\n".join(lines)


def citation(v, refs):
    want = list(dict.fromkeys(c for _, _, _, _, c, only in PARTS if only is None or v["weights"] in only))
    want.insert(want.index("kimodo-ggml") + 1, "motion-bricks-ggml")
    missing = [w for w in want if w not in refs]
    if missing:
        sys.exit(f"no citation reference for {missing}")
    return {
        "cff-version": "1.2.0", "title": v["title"],
        "message": "If you use these files, please cite them and the upstream sources listed under `references`.",
        "type": "software", "authors": [FIRE],
        "license-url": f"https://huggingface.co/{v['repo']}/blob/main/LICENSE.md",
        "url": f"https://huggingface.co/{v['repo']}", "date-released": datetime.date.today().isoformat(),
        "references": [refs[w] for w in want],
    }


def refs_table():
    with open(os.path.join(SRC, "old-citations.yaml")) as f:
        old = yaml.safe_load(f)
    refs = {}
    for c in old.values():
        for r in c["references"]:
            refs.setdefault(r["title"], r)
    refs["kimodo-ggml"] = {"type": "software", "title": "kimodo-ggml", "authors": [FIRE],
                           "repository-code": GH + "V-Sekai-fire/kimodo-ggml", "license": "Apache-2.0",
                           "notes": "The ggml port of Kimodo, vendored in motion.elf."}
    refs["motion-bricks-ggml"] = {"type": "software", "title": "motion-bricks-ggml", "authors": [FIRE],
                                  "repository-code": GH + "V-Sekai-fire/motion-bricks-ggml",
                                  "license": "Apache-2.0", "notes": "Vendored in motion.elf."}
    refs["interactor-headfit"] = {"type": "software", "title": "interactor-headfit", "authors": [FIRE],
                                  "repository-code": GH + "V-Sekai-fire/interactor-headfit", "license": "MIT",
                                  "notes": "headfit.elf, the eye-close shapes of a rigged VRM."}
    refs["interactor-motion-matching-guest"] = {
        "type": "software", "title": "interactor-motion-matching-guest", "authors": [FIRE],
        "repository-code": GH + "V-Sekai-fire/interactor-motion-matching-guest", "license": "MIT",
        "notes": "mm.elf, the walk mode (M). A port of godot-motion-matching by Guilherme Sousa "
                 "(https://github.com/V-Sekai/godot-motion-matching, MIT)."}
    refs["O3DE MotionMatching gem"] = {
        "type": "software", "title": "O3DE MotionMatching gem", "authors": [{"name": "Contributors to the Open 3D Engine"}],
        "repository-code": GH + "o3de/o3de/tree/development/Gems/MotionMatching", "license": "MIT",
        "notes": "Apache-2.0 OR MIT, used under MIT. 21 motion-capture clips of the walk mode, moved onto the SOMA skeleton."}
    refs["lilToon"] = {
        "type": "software", "title": "lilToon", "authors": [{"alias": "lilxyzw"}],
        "repository-code": GH + "lilxyzw/lilToon", "license": "MIT",
        "notes": "Version 2.3.4, vendored in thirdparty/lilToon. Its shader files go into every .unitypackage "
                 "that the asset package export writes."}
    def soft(title, url, lic, notes, authors):
        refs[title] = {"type": "software", "title": title, "authors": [{"name": a} for a in authors],
                       "repository-code": url, "license": lic, "notes": notes}
    refs["mujoco-sandbox-demo"] = {"type": "software", "title": "mujoco-sandbox-demo", "authors": [FIRE],
                                   "repository-code": GH + "V-Sekai-fire/interactor-mujoco-sandbox-demo",
                                   "license": "MIT", "notes": "mujoco.elf, the obstacle course's collisions."}
    soft("MuJoCo", GH + "google-deepmind/mujoco", "Apache-2.0", "3.14.0 at 53197e6, inside mujoco.elf.",
         ["Google DeepMind"])
    soft("libccd", GH + "danfis/libccd", "BSD-3-Clause", "Inside mujoco.elf.", ["Daniel Fiser"])
    soft("Qhull", "http://www.qhull.org", "Qhull", "Inside mujoco.elf.", ["C.B. Barber", "The Geometry Center"])
    soft("TinyXML-2", GH + "leethomason/tinyxml2", "Zlib", "Inside mujoco.elf.", ["Lee Thomason"])
    soft("tinyobjloader", GH + "tinyobjloader/tinyobjloader", "MIT", "Inside mujoco.elf.", ["Syoyo Fujita"])
    soft("miniz", GH + "richgel999/miniz", "MIT", "Inside mujoco.elf.", ["Rich Geldreich", "RAD Game Tools", "Valve Software"])
    soft("LodePNG", GH + "lvandeve/lodepng", "Zlib", "Inside mujoco.elf.", ["Lode Vandevenne"])
    soft("xr-grid", GH + "V-Sekai/xr-grid", "MIT", "The grid-ball shader and mesh (commit ff71e92), in the pck.",
         ["V-Sekai Contributors"])
    r = refs["Llama-3-Kimodo-GGML (LLM2Vec encoder, Meta Llama 3)"]
    r["notes"] = ("Meta Llama 3 Community License. Made the 18 prompt embeddings in the pck ahead of time. "
                  "These inputs are the output of a program; no person wrote them. The downloads do not "
                  "contain the encoder or the Llama 3 model. Built with Meta Llama 3.")
    return refs


def check_sections():
    for w in ("skintokens", "kimodo"):
        have = [t for t, _ in sections(w)]
        for _, _, _, sec, _, only in PARTS:
            if sec and (only is None or w in only) and not any(h.startswith(sec) for h in have):
                sys.exit(f"no licence text for {sec} ({w})")


def main(out):
    check_sections()
    refs = refs_table()
    for key, v in VIEWERS.items():
        d = os.path.join(out, key)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "LICENSE.md"), "w") as f:
            f.write(license_md(v))
        with open(os.path.join(d, "NOTICE"), "w") as f:
            f.write(notice(v))
        with open(os.path.join(d, "CITATION.cff"), "w") as f:
            yaml.safe_dump(citation(v, refs), f, sort_keys=False, allow_unicode=True, width=100)
        print(key, "ok")


if __name__ == "__main__":
    main(sys.argv[1])
