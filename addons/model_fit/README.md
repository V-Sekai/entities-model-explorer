# Model Fit

Fit one avatar's clothing to another avatar's base body inside Model Explorer, for a pair of avatars: take A's clothing off, hide A's base, fit the clothing to B's base. The body never moves; only the garment does.

## What is here (2026-11-03)
- `avatar_pair.gd`: base/clothing split and the pair plan. Base meshes are matched by full-name regular expressions, default `Body`, `BodyBase`, `BaseBody`, `Base`, and the list is an argument because avatars vary. Clothing is every other visible mesh except hair, ears, tail, eyes, face parts and debug objects (also arguments). `hide_source_base()` hides A's base and returns what it hid. Tests: `tests/test_avatar_pair.gd`.
- `frontier_knots.gd`: the frontier search for the cage knot count of a shell (algorithm in the file header). Every bind probe and fit is recorded; shells of similar size share what worked; a shell where no K binds is reported as such (the cage cannot contain it, another route is needed). No I/O: the caller runs the probes. Tests with planted oracles and controls: `tests/test_frontier_knots.gd`.

Run a test: `godot --headless --path <project> -s res://addons/model_fit/tests/test_frontier_knots.gd` (the bad-JSON `ERROR` line is expected).

## Not here yet
- The cage driver inside Model Explorer: the scripts that drive `cage.elf` (net, bind, fit, bind-only probe) live in the `unity-scene-dump-runtime-fit` skill (`cage_garment.gd`, `knot_search.sh`) and need porting into an addon class that calls `frontier_knots.gd`. Binary translation (`vsk_model_explorer/core/Bintr.gd`) must be on: measured 3.6x (net), 4.3x (bind), 8.3x (fit) on the Maple skirt with byte-identical output.
- Per-shell splitting (`split_shells.gd`: weld by position, connected shells, big shells fitted one by one, small shells move rigidly with the nearest displacement), expansion to all vertices, and the skin transfer back to the target's skeleton.
- Shells the cage cannot contain (measured: Maple Inner, some Obi and Hair Acc shells) need another route.
