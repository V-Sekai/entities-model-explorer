extends SceneTree
# Writes triangle meshes as .usdz with usd.elf (the test fixtures; the scene data itself is OpenUSD, not OBJ). The points go in as they are, in
# the caller's frame; the OBJ is only the source these were converted from once.
# usage: -- <usd.elf> <in.obj> <out.usdz> [<in2.obj> <out2.usdz> ...]

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var elf := FileAccess.get_file_as_bytes(a[0])
	for i in range(1, a.size(), 2):
		var pts := PackedFloat32Array()
		var tri := PackedInt32Array()
		for l in FileAccess.get_file_as_string(a[i]).split("\n"):
			var t := l.split(" ", false)
			if l.begins_with("v "):
				pts.append(float(t[1]))
				pts.append(float(t[2]))
				pts.append(float(t[3]))
			elif l.begins_with("f "):
				for k in 3:
					tri.append(int(t[k + 1].split("/")[0]) - 1)
		var nf := tri.size() / 3
		var ints := PackedInt32Array()
		ints.resize(nf)
		ints.fill(3)
		ints.append_array(tri)
		var sb = ClassDB.instantiate("Sandbox")
		sb.memory_max = 1024
		sb.references_max = 4096
		sb.allocations_max = 1000000
		sb.execution_timeout = 300000
		root.add_child(sb)
		sb.load_buffer(elf)
		sb.vmcall("usd_init")
		var header := "%s\nnp=%d\nnuv=0\nnrest=0\nnf=%d\nni=%d" % [a[i + 1].get_file().get_basename(), pts.size() / 3, nf, tri.size()]
		var pkg = sb.vmcall("usd_write_mesh", pts, ints, header, "")
		if typeof(pkg) != TYPE_PACKED_BYTE_ARRAY:
			print("FAILED ", a[i + 1], ": ", str(pkg).left(200))
			continue
		FileAccess.open(a[i + 1], FileAccess.WRITE).store_buffer(pkg)
		print("wrote %s: %d points, %d triangles, %d bytes" % [a[i + 1], pts.size() / 3, nf, pkg.size()])
	quit(0)
