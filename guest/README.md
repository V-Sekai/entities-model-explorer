# Model Explorer as godot-sandbox guests

This branch runs Model Explorer with no scene files in the export. Every script is a RISC-V program
(`.sgd.elf`) that godot-sandbox runs, except the plain-GDScript list `PLAIN_FILES`/`PLAIN_DIRS` in
`build.py`, and every scene is a build procedure compiled into one of those programs. It is the viewer of the chibifire SkinTokens Space.

## Build

Needs: the compiler from V-Sekai-fire/entities-godot-sandbox-gdscript-compiler
(`pixi run cmake --build build --target gdscript_to_riscv`), the godot-sandbox addon
(`addons/godot_sandbox` with the double-precision threaded web library), a Godot editor and a
threaded double-precision web export template with WebGPU.

```sh
python3 guest/build.py <work dir> <gdscript_to_riscv> <addons/godot_sandbox> <web template zip> usd.elf skintokens.elf
godot --resolution 640x360 --path <work dir> --import
godot --resolution 640x360 --path <work dir> --export-release Web out/index.html
```

## What the build changes

- `tscn2gd.py` turns each `.tscn` into `<Name>_scene.gd` with `func instantiate()`, and rewrites
  `preload("...tscn")` users to `X.new().instantiate()`.
- `overlay/boot.tscn` is the main scene, an empty Node; the `Boot` autoload (`overlay/boot.gd`)
  builds Model Explorer, gives it a light studio (a backdrop quad, colour ambient light), loads
  the sample model and shows a one-line hint.
- Relative `load`/`preload` paths become `res://` paths: the guest passes the literal string to
  the host.
- On the web: Mobile renderer, no 2D MSAA, no physical light units.

## Guests that start guests

OpenUSD input (`UsdImport.gd`, usd.elf) and the R key's .vrm step (`AutoRig.gd`, skintokens.elf, no
weights) run a second Sandbox. A guest script cannot enter another guest machine on the web ("Too
many VM calls in progress", or a JSPI SuspendError), so these scripts, `VrmExport.gd` and the VRM
add-on stay plain GDScript, and the guest viewer reaches them only from the engine's main loop: the
viewer hands a dropped USD file to `UsdImport.convert_later()` and opens the GLB when `converted`
fires; R reaches `AutoRig` as key input. In the browser R saves a .glb that has a skin (the page's
auto-rig result) as `<name>.vrm` when it passes the humanoid gates, and a .vrm as `<name>.tpose.vrm`,
and the browser downloads the file. The compiler must number its syscalls as the web library does
(`src/syscalls.h`): a compiler older than entities-godot-sandbox-gdscript-compiler 6d7251a calls
ECALL 67 for a packed-array copy, which the library answers as an array window.

## Shader warm-up (export pipeline only)

When the page args contain `--warmup` (copy `index.html` to `warmup.html` with
`"args":["--warmup"]`), `boot.gd` draws one small sphere per StandardMaterial3D shader key the glTF
importer produces, waits 30 frames, prints every file under `user://shader_cache` as
`SCF <path> <part> <parts> <hex>` console lines, then prints `WARMUP done`. A harvester joins the
lines back into files. Normal visits never pass `--warmup`, so they do not run this code.

## See-through materials (glTF transmission)

`overlay/gltf/khr_materials_transmission.gd` is a GLTFDocumentExtension that `boot.gd` registers at
start. It claims `KHR_materials_transmission`, `KHR_materials_volume` and `KHR_materials_ior`, so files
that list them under `extensionsRequired` (Khronos CommercialRefrigerator) import instead of being
refused. Each glTF material with a transmission factor above 0 becomes a ShaderMaterial (the shader
code is a string in the script) that copies the importer's StandardMaterial3D and adds the scene
behind it from Godot's screen texture, tinted by the base colour and blurred by roughness. With a
volume, the view ray is refracted once (IOR), walks the material thickness and is absorbed by
Beer-Lambert (attenuationColor, attenuationDistance), as in the Khronos sample viewer. Transparent
objects behind the glass do not show through it (the screen copy is taken after the opaque pass).

`overlay/sample/mire.glb`: Mille "Mire" Feuille by Mohka Noir, Apache-2.0, converted from MireQuest.blend (see `overlay/sample/NOTICE.txt`). Sample models must allow commercial use and must not be share-alike.
