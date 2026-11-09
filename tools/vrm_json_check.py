"""Check a .vrm (VRM 1.0 GLB) the way a VRM player would read it, without Godot.

Prints the humanoid bones, materials with MToon, meta and scene roots, and fails (exit 1) when a
required bone, the MToon extension on any material, or the meta's required fields are missing.
"""
import json
import struct
import sys

REQUIRED = ["hips", "spine", "head", "leftUpperLeg", "leftLowerLeg", "leftFoot", "rightUpperLeg",
            "rightLowerLeg", "rightFoot", "leftUpperArm", "leftLowerArm", "leftHand",
            "rightUpperArm", "rightLowerArm", "rightHand"]
# VRMC_vrm.meta properties in the VRM 1.0 schema (meta.schema.json).
META_KEYS = {"name", "version", "authors", "copyrightInformation", "contactInformation",
             "references", "thirdPartyLicenses", "thumbnailImage", "licenseUrl",
             "avatarPermission", "allowExcessivelyViolentUsage", "allowExcessivelySexualUsage",
             "commercialUsage", "allowPoliticalOrReligiousUsage", "allowAntisocialOrHateUsage",
             "creditNotation", "allowRedistribution", "modification", "otherLicenseUrl",
             "extensions", "extras"}


def read(path):
    b = open(path, "rb").read()
    magic, ver, total = struct.unpack("<III", b[:12])
    assert magic == 0x46546C67 and ver == 2 and total == len(b), "not a GLB 2.0"
    n, kind = struct.unpack("<II", b[12:20])
    assert kind == 0x4E4F534A
    return json.loads(b[20:20 + n])


def main(path):
    j = read(path)
    bad = []
    vrm = j.get("extensions", {}).get("VRMC_vrm")
    if vrm is None:
        print("no VRMC_vrm")
        return 1
    bones = vrm["humanoid"]["humanBones"]
    bad += [f"missing {b}" for b in REQUIRED if b not in bones]
    mats = j.get("materials", [])
    mtoon = sum("VRMC_materials_mtoon" in m.get("extensions", {}) for m in mats)
    if mtoon != len(mats) or not mats:
        bad.append(f"MToon on {mtoon}/{len(mats)} materials")
    meta = vrm.get("meta", {})
    for k in ("name", "authors", "licenseUrl"):
        if not meta.get(k):
            bad.append(f"meta {k} empty")
    # VRoid Hub refuses a meta with keys outside the VRM 1.0 schema or with empty values
    # ("model file is not included in the list"); the glTF validator reports neither.
    bad += [f"meta {k} not in VRM 1.0 schema" for k in meta if k not in META_KEYS]
    bad += [f"meta {k} empty" for k, v in meta.items() if v in ("", [], {})]
    roots = j["scenes"][j.get("scene", 0)]["nodes"]
    print(f"{path.split('/')[-1]}: spec {vrm.get('specVersion')} humanBones {len(bones)} "
          f"mtoon {mtoon}/{len(mats)} roots {[j['nodes'][r].get('name') for r in roots]} "
          f"used {j.get('extensionsUsed')}")
    for b in bad:
        print("  FAIL", b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(max(main(p) for p in sys.argv[1:]))
