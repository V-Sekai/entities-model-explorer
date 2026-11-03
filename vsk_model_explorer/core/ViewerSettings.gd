extends RefCounted
# The viewer's toggles, remembered between runs: which were on when it closed. One small file in the
# user data folder (user://viewer_settings.cfg), written at each change, read at start.
#   wireframe       L          off by default
#   grid_hidden     G          off by default (the grid shows)
#   controls_card   H, ?       on by default
#   color_chart     C          off by default
#   mcp             the MCP slider; unset until it is used, so the server keeps its own default
# Start with `-- --fresh-settings` to ignore the file and not write it (tests do).
const PATH := "user://viewer_settings.cfg"
const SECTION := "toggles"


static func enabled() -> bool:
	return not ("--fresh-settings" in OS.get_cmdline_user_args())


static func get_bool(key: String, default: bool) -> bool:
	if not enabled():
		return default
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return default
	return bool(cfg.get_value(SECTION, key, default))


static func has_key(key: String) -> bool:
	if not enabled():
		return false
	var cfg := ConfigFile.new()
	return cfg.load(PATH) == OK and cfg.has_section_key(SECTION, key)


static func set_bool(key: String, value: bool) -> void:
	if not enabled():
		return
	var cfg := ConfigFile.new()
	cfg.load(PATH)  # keep the other toggles; a missing file is fine
	cfg.set_value(SECTION, key, value)
	cfg.save(PATH)
