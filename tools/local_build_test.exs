#!/usr/bin/env elixir
# Reproduce the Linux leg of .github/workflows/release.yml locally (WSL or any Linux box), so a
# packaging mistake is caught in under a minute instead of a 5+ minute CI round trip.
#
#   elixir tools/local_build_test.exs                full fetch + pck export + package + FDB round trip
#   elixir tools/local_build_test.exs --skip-fetch    reuse an already-populated $LOCAL_BUILD_CACHE
#                                                      (faster re-runs while iterating on
#                                                      package_desktop.exs/export_presets.cfg only)
#
# Needs: gh (authenticated: GH_TOKEN or `gh auth login`), git, perl, zip, tar. elixir/erlang come
# from pixi (pixi.toml) when run as `pixi run build`.

defmodule LocalBuildTest do
  @engine_files ~w(godot.linuxbsd.editor.double.x86_64
                   godot.linuxbsd.template_release.double.x86_64
                   godot.macos.template_release.double.arm64
                   godot.windows.template_release.double.x86_64.llvm.exe
                   libfdb_c.so libfdb_c.dylib fdb_c.dll
                   fdbserver.linux.x86_64 fdbserver.macos.arm64 fdbserver.windows.x86_64.exe
                   SHA256SUMS)
  @cli_files ~w(fdbcli.linux.x86_64 fdbcli.macos.arm64 fdbcli.windows.x86_64.exe)
  @app "skintokens-viewer"
  @weights ~w(mesh-encoder.gguf skin-vae.gguf tokenrig.gguf)

  def main(argv) do
    case run(argv) do
      :ok ->
        0

      {:error, reason} ->
        IO.puts(:stderr, format(reason))
        1
    end
  end

  defp format(r) when is_binary(r), do: r
  defp format(r), do: inspect(r)

  defp run(argv) do
    here = Path.expand(Path.join(__DIR__, ".."))
    cache = System.get_env("LOCAL_BUILD_CACHE") || Path.join(here, ".local-build-cache")
    engine = Path.join(cache, "engine")
    notices = Path.join(cache, "notices")
    skip_fetch = "--skip-fetch" in argv
    engine_tag = System.get_env("ENGINE_TAG") || "v0.0.0-20261106225526-d632cdf2be4c"
    fdb_release = System.get_env("FDB_RELEASE") || "7.3.79-weftspun-dev.2"
    work = mktemp_dir!()

    try do
      with :ok <- maybe_fetch(skip_fetch, here, cache, engine, notices, engine_tag, fdb_release),
           :ok <- export_pck(here, engine, notices, cache, work),
           :ok <- package(work),
           tgz = Path.join([work, "out", "skintokens", "#{@app}-linux-x86_64.tar.gz"]),
           :ok <- (if File.regular?(tgz), do: :ok, else: {:error, "package left no #{tgz}"}),
           d = Path.join(work, "extracted"),
           :ok <- File.mkdir_p(d),
           {:ok, _} <- run("tar", ["-xzf", tgz, "-C", d]),
           :ok <- ls(d),
           :ok <- assert_embedded(d),
           :ok <- fdb_selftest(d, work) do
        IO.puts("LOCAL-BUILD-TEST-OK")
        :ok
      end
    after
      File.rm_rf(work)
    end
  end

  # ---- fetch -------------------------------------------------------------------------------

  defp maybe_fetch(true, _here, cache, engine, _notices, _tag, _fdb) do
    if File.regular?(Path.join(engine, "godot.linuxbsd.editor.double.x86_64")) do
      IO.puts("== --skip-fetch: reusing #{engine}, #{Path.join(cache, "mm-repo")}")
      :ok
    else
      maybe_fetch(false, nil, cache, engine, nil, nil, nil)
    end
  end

  defp maybe_fetch(false, here, cache, engine, notices, engine_tag, fdb_release) do
    IO.puts("== fetching the double-precision engine (#{engine_tag})")

    with :ok <- File.mkdir_p(engine),
         # package_desktop.exs's "package" step lays out macOS, Windows AND Linux unconditionally,
         # even when only the Linux leg is run here, so all three templates are needed. Windows
         # and Linux are the real --export-release embed_pck templates (patch_embed_templates/1
         # in package_desktop.exs points custom_template/release at them); macOS needs the same
         # zipped macos_template.app structure release.yml's "Build the macOS export template"
         # step builds (a bare Mach-O binary makes Godot's macOS exporter fail outright).
         :ok <- gh_release_download(engine_tag, "V-Sekai-fire/entities-zone", @engine_files, engine),
         :ok <- build_macos_template(engine),
         :ok <- Enum.reduce_while(Enum.filter(@engine_files, &String.starts_with?(&1, ["godot.", "fdbserver."])), :ok, fn f, _ ->
           case chmod_x(Path.join(engine, f)) do
             :ok -> {:cont, :ok}
             e -> {:halt, e}
           end
         end),
         {:ok, _} <- File.copy(Path.join(here, "LICENSE"), Path.join(engine, "LICENSE-model-explorer.txt")),
         _ <- IO.puts("== fetching fdbcli (#{fdb_release})"),
         cli = Path.join(engine, "cli"),
         :ok <- File.mkdir_p(cli),
         :ok <- gh_release_download(fdb_release, "V-Sekai-fire/datasource-foundationdb", @cli_files, cli),
         :ok <- move_cli(cli, engine),
         _ <- IO.puts("== fetching the guest programs"),
         {:ok, _} <- System.cmd("tools/fetch_guest_assets.sh", [], cd: here, into: IO.stream(:stdio, :line)),
         :ok <- File.mkdir_p(notices),
         {:ok, _} <- File.copy(Path.join(here, "LICENSE"), Path.join(notices, "LICENSE.md")),
         :ok <- File.write(Path.join(notices, "NOTICE"), "V-Sekai Model Explorer, skintokens viewer (local build test)\n"),
         :ok <- File.write(Path.join(notices, "CITATION.cff"), ~s(cff-version: 1.2.0\nmessage: "local build test"\ntitle: "V-Sekai Model Explorer"\n)) do
      :ok
    end
  end

  # Mirrors release.yml's "Build the macOS export template" step: Godot's macOS exporter wants a
  # zipped macos_template.app/Contents/{MacOS/godot_macos_release.arm64,Info.plist}, not the bare
  # Mach-O binary ENGINE otherwise has.
  defp build_macos_template(engine) do
    app = Path.join(engine, "macos_template.app")
    mac = Path.join(app, "Contents/MacOS")
    File.mkdir_p!(mac)

    with {:ok, _} <- File.cp(Path.join(engine, "godot.macos.template_release.double.arm64"), Path.join(mac, "godot_macos_release.arm64")),
         :ok <- chmod_x(Path.join(mac, "godot_macos_release.arm64")),
         :ok <- File.write(Path.join(app, "Contents/PkgInfo"), "APPL????"),
         :ok <- File.write(Path.join(app, "Contents/Info.plist"), ~s(<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$binary</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle_identifier</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$short_version</string>
  <key>CFBundleSignature</key><string>$signature</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>NSHumanReadableCopyright</key><string>$copyright</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.$app_category</string>
  <key>NSHighResolutionCapable</key>$highres
</dict></plist>
)),
         {:ok, _} <- run("zip", ["-qry", Path.join(engine, "macos-template.zip"), "."], cd: app) do
      File.rm_rf(app)
    end
  end

  defp gh_release_download(tag, repo, files, dest) do
    Enum.reduce_while(files, :ok, fn f, _ ->
      case run("gh", ["release", "download", tag, "-R", repo, "-p", f, "--clobber"], cd: dest) do
        {:ok, _} -> {:cont, :ok}
        e -> {:halt, e}
      end
    end)
  end

  defp move_cli(cli, engine) do
    Enum.reduce_while(@cli_files, :ok, fn f, _ ->
      with {:ok, _} <- File.copy(Path.join(cli, f), Path.join(engine, f)),
           :ok <- chmod_x(Path.join(engine, f)) do
        {:cont, :ok}
      else
        e -> {:halt, e}
      end
    end)
  end

  # ---- pck export + package -----------------------------------------------------------------

  defp export_pck(here, engine, notices, cache, work) do
    IO.puts("== exporting the pck")

    env = [
      {"GODOT", Path.join(engine, "godot.linuxbsd.editor.double.x86_64")},
      {"ENGINE", engine},
      {"NOTICES", notices},
      {"ELF", Path.join(here, "skintokens.elf")},
      {"USD_ELF", Path.join(here, "usd.elf")},
      {"MOTION_ELF", Path.join(here, "motion.elf")},
      {"HEADFIT_ELF", Path.join(here, "headfit.elf")},
      {"PERSONA_ELF", Path.join(here, "persona.elf")},
    ]

    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    case run("elixir", ["tools/package_desktop.exs", "pck", Path.join(work, "out")], cd: here) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  defp package(work) do
    IO.puts("== packaging the linux build (real --export-release embed_pck)")
    # skintokens needs its three weight files present in <w> (package_desktop.exs's need_files),
    # even though this harness only exercises the Linux leg; empty placeholders are enough to
    # satisfy the check and exercise link_weights/3's copy path.
    weights = Path.join(work, "weights")
    File.mkdir_p!(weights)
    Enum.each(@weights, &File.write!(Path.join(weights, &1), ""))

    # NOTE: this harness runs pck export and packaging in one BEAM process, so GODOT set by
    # export_pck/5's System.put_env is still visible here. release.yml runs them as separate
    # `run:` steps (fresh shell each time), so it must `export GODOT=...` again in its own
    # "Package macOS, Windows and Linux" step -- CI run 42483764079 caught this the hard way
    # (fell back to package_desktop.exs's macOS-editor default, enoent on a Linux runner). This
    # harness cannot reproduce that step-boundary class of bug; release.yml is the real gate for it.
    case run("elixir", ["tools/package_desktop.exs", "package", Path.join(work, "out"), weights, "skintokens"]) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  defp ls(d) do
    case File.ls(d) do
      {:ok, names} ->
        Enum.each(names, fn n -> IO.puts("  #{n}") end)
        :ok

      {:error, r} ->
        {:error, "ls #{d}: #{r}"}
    end
  end

  defp assert_embedded(d) do
    sibling = Path.join(d, "#{@app}.pck")

    if File.regular?(sibling) do
      {:error, "a sibling #{@app}.pck shipped on Linux -- embed_pck did not actually embed"}
    else
      IO.puts("ok: no sibling .pck next to the Linux exe (really embedded)")
      :ok
    end
  end

  # ---- FDB-selftest round trip (mirrors release.yml's verify job) ---------------------------

  defp fdb_selftest(d, work) do
    IO.puts("== FDB-selftest round trip (mirrors release.yml's verify job)")
    exe = Path.join(d, @app)
    empty = Path.join(work, "empty")
    File.mkdir_p!(empty)
    state = Path.join(work, "fdb-state")

    cases = [
      {"control: no fdbserver", "1", "FAIL plant=false mode=roundtrip fdbserver and fdbcli not found", empty, []},
      {"round trip through the packaged server", "0", "PASS plant=false mode=roundtrip fdbserver [0-9]+ on port", nil, []},
      {"second start reads the row the first wrote", "0", "PASS plant=false mode=read", nil, ["--fdb-selftest-read"]},
      {"planted wrong value", "1", "FAIL plant=true mode=roundtrip read back", nil, ["--fdb-selftest-plant"]}
    ]

    fails = Enum.reduce(cases, 0, fn {label, want_rc, want, bin, extra}, acc ->
      acc + selftest_case(exe, state, label, want_rc, want, bin, extra)
    end)

    File.rm_rf(state)

    fails =
      fails +
        selftest_case(
          exe,
          state,
          "control: a fresh state has no row",
          "1",
          "FAIL plant=false mode=read no row from an earlier run",
          nil,
          ["--fdb-selftest-read"]
        )

    IO.puts("== no server left running")

    fails =
      case System.cmd("pgrep", ["-l", "fdbserver"], stderr_to_stdout: true) do
        {_, 0} -> fails + 1
        _ -> IO.puts("   none"); fails
      end

    IO.puts("failed cases: #{fails}")
    if fails == 0, do: :ok, else: {:error, "#{fails} FDB-selftest case(s) failed"}
  end

  defp selftest_case(exe, state, label, want_rc, want, bin, extra) do
    File.rm(Path.join(state, "selftest-result.txt"))

    env =
      [{"WEFT_FDB_STATE_DIR", state}] ++
        if bin, do: [{"WEFT_FDB_BIN_DIR", bin}], else: [{"WEFT_FDB_BIN_DIR", nil}]

    args = ["--headless", "--", "--fdb-selftest"] ++ extra
    {out, rc} = System.cmd("perl", ["-e", "alarm 240; exec @ARGV", exe] ++ args, env: env, stderr_to_stdout: true)
    rc_str = Integer.to_string(rc)
    line = result_line(state)
    IO.puts("== #{label}: rc=#{rc} #{line}")

    if rc_str == want_rc and Regex.match?(Regex.compile!(want), line) do
      IO.puts("   ok")
      0
    else
      IO.puts("   WRONG, wanted rc=#{want_rc} and /#{want}/")
      out |> String.split("\n") |> Enum.take(-15) |> Enum.each(&IO.puts/1)
      1
    end
  end

  defp result_line(state) do
    case File.read(Path.join(state, "selftest-result.txt")) do
      {:ok, bin} -> bin |> String.split("\n") |> hd()
      {:error, _} -> ""
    end
  end

  # ---- shared --------------------------------------------------------------------------------

  defp mktemp_dir! do
    dir = Path.join(System.tmp_dir!(), "local-build-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp chmod_x(path), do: File.chmod(path, 0o755)

  defp run(cmd, args, opts \\ []) do
    env = Keyword.get(opts, :env, [])
    opts = Keyword.drop(opts, [:env]) ++ [stderr_to_stdout: true, env: env]

    case System.cmd(cmd, args, opts) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, "#{Path.basename(cmd)} #{Enum.take(args, 3) |> Enum.join(" ")} exited #{code}: #{tail(out)}"}
    end
  rescue
    e in ErlangError -> {:error, "cannot run #{cmd}: #{Exception.message(e)}"}
  end

  defp tail(s), do: s |> String.split("\n", trim: true) |> Enum.take(-10) |> Enum.join(" | ")
end

System.halt(LocalBuildTest.main(System.argv()))