# V-Sekai Model Explorer

<!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->

[![All Contributors](https://img.shields.io/badge/all_contributors-3-orange.svg?style=flat-square)](#contributors-)

<!-- ALL-CONTRIBUTORS-BADGE:END -->

> :warning: **Warning**: Please check the releases section. [V-Sekai/TOOL_model_explorer/releases](https://github.com/V-Sekai/TOOL_model_explorer/releases)

V-Sekai Model Explorer is a comprehensive 3D model viewer, designed with the powerful Godot 4 engine. It's an excellent tool for anyone interested in exploring the intricacies of 3D models.

<div style="width: 50%; margin: auto; overflow: hidden;">
	<img src=".github/Screenshot 2023-09-21 105018.png" alt="Model Explorer Image">
</div>

## Features

| Supported Formats |
| ----------------- |
| VRM               |
| glTF 2.0          |
| FBX               |

1. **Detailed Viewing**: Inspect every component of a 3D model, from meshes and materials to textures and animations.
2. **Animation Playback**: Play back animations within the model for a dynamic viewing experience.
3. **Interactive Controls**: Navigate around the model with ease using intuitive controls.
4. **Double-Click Action**: Get a closer look at any part of the model with a simple double-click.
5. **Wireframe/Explode/Hide Grid**: Press L for wireframe, E to take the model apart into its separate pieces and G to hide the grid; the controls card lists every key.

## MCP server

An MCP client (an AI agent) can open a model in the viewer, auto-rig it, and take the result. The tools are `status`, `load_model`, `auto_rig`, `get_file`, `screenshot` and `persona_ask` (the persona's plan for a goal, from `persona.elf`), plus read-only scene tools (`get_scene_tree`, `get_node`, `get_property`, `find_nodes`, `get_aabb`, `get_bone_poses`, `ping`). The server is `addons/vsekai_godot_mcp` (from V-Sekai-fire/transport-godot-mcp, trimmed in `project.godot`); the tools are `vsk_model_explorer/core/RigTools.gd`.

The server runs in the desktop viewer; the web viewer does not have it.

- HTTP: start the viewer with `-- --mcp-port=8789`. Streamable HTTP is at `http://127.0.0.1:8789/mcp`, and the older HTTP+SSE transport is at `/sse`.

Every protocol version from 2024-11-05 to 2026-07-28 works. `tools/mcp_check.py` checks the desktop viewer with the MCP Python SDK.

## Release notes

`.fbx`, `.vrm`, `.glb`, and `.gltf` files can be viewed.

## Features

- View gltf 2.0 models
- Show meshes inside
- Show materials inside
  - View material properties
- Show textures inside
  - Quick view texture
- Show animations inside
  - Quick play animation
- Toggle wireframe mode

## Special Thanks to AllenDang

Thanks to AllenDang for creating the original version.

[AllenDang's Model Explorer](https://github.com/AllenDang/model_explorer_godot4)

## Contributors ✨

Thanks goes to these wonderful people ([emoji key](https://allcontributors.org/docs/en/emoji-key)):

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
	<tr>
	  <td align="center" valign="top" width="14.28%"><a href="https://github.com/Illauriel"><img src="https://avatars.githubusercontent.com/u/10573379?v=4?s=100" width="100px;" alt="Illauriel"/><br /><sub><b>Illauriel</b></sub></a><br /><a href="#ideas-Illauriel" title="Ideas, Planning, & Feedback">🤔</a> <a href="https://github.com/V-Sekai/TOOL_model_explorer/commits?author=Illauriel" title="Code">💻</a> <a href="https://github.com/V-Sekai/TOOL_model_explorer/commits?author=Illauriel" title="Tests">⚠️</a></td>
	  <td align="center" valign="top" width="14.28%"><a href="https://chibifire.com"><img src="https://avatars.githubusercontent.com/u/32321?v=4?s=100" width="100px;" alt="K. S. Ernest (iFire) Lee"/><br /><sub><b>K. S. Ernest (iFire) Lee</b></sub></a><br /><a href="#ideas-fire" title="Ideas, Planning, & Feedback">🤔</a> <a href="https://github.com/V-Sekai/TOOL_model_explorer/commits?author=fire" title="Code">💻</a> <a href="#infra-fire" title="Infrastructure (Hosting, Build-Tools, etc)">🚇</a></td>
	  <td align="center" valign="top" width="14.28%"><a href="https://github.com/AllenDang"><img src="https://avatars.githubusercontent.com/u/18550?v=4?s=100" width="100px;" alt="Allen Dang"/><br /><sub><b>Allen Dang</b></sub></a><br /><a href="https://github.com/V-Sekai/TOOL_model_explorer/commits?author=AllenDang" title="Code">💻</a></td>
	</tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

This project follows the [all-contributors](https://github.com/all-contributors/all-contributors) specification. Contributions of any kind welcome!
