#!/usr/bin/env elixir
# Build the desktop viewer packages with the auto-rig and its weights.
#
#   elixir tools/package_desktop.exs pck <out dir>            export skintokens-viewer.pck from HEAD
#   elixir tools/package_desktop.exs package <out dir> <w> [skintokens|kimodo-motion|walk-mode]
#                                                     lay out and archive the three packages
#                                                     in <out dir>/<viewer>/ with SHA256SUMS
#
# One pck, two viewers. Each feature is on when its weights are in the package's w folder:
#   skintokens     skintokens-viewer, the rig weights (R auto-rigs), no Kimodo (the default)
#   kimodo-motion  kimodo-motion-viewer, the Kimodo weights (the Motion list), no rig weights
#   walk-mode      walk-mode-viewer, no weights (M walks a rigged model; <w> is unused)
#
# Inputs (environment):
#   GODOT    optional: the double editor that exports the pck and (for `package`) runs
#            --export-release (default $ENGINE/godot.macos.editor.double.arm64;
#            godot.linuxbsd.editor.double.x86_64 on Linux)
#   ENGINE   dir with godot.macos.editor.double.arm64 and the three template_release runtimes
#            from a V-Sekai-fire/entities-zone release, which has the Sandbox class built in, plus the
#            FoundationDB client beside them (libfdb_c.dylib, fdb_c.dll, libfdb_c.so) and LICENSE-model-explorer.txt
#            windows.template_release and linuxbsd.template_release are also the real embed_pck
#            templates: `pck` points export_presets.cfg's custom_template/release at them (they carry
#            the linker-emitted "pck" section from entities-godot's platform/<os>/godot_<os>.cpp), and
#            `package` runs Godot's own --export-release against each, so the shipped exe has the pck
#            appended and the section header patched by the engine's own fixup_embedded_pck() --
#            not a `cat` and not a same-named sibling .pck (macOS has no embed_pck option in Godot's
#            bundle exporter, so it still gets a bare binary + Resources-style sibling pck below).
#   ELF      skintokens.elf
#   USD_ELF  usd.elf (interactor-usd-guest), the OpenUSD reader for .usd, .usda, .usdc and .usdz
#   MOTION_ELF  motion.elf (interactor-motion-guest)
#   HEADFIT_ELF optional: headfit.elf (interactor-headfit), the anime eye closes of a rigged VRM.
#            Unset, `pck` downloads it with gh from the newest green `guest` run of
#            interactor-headfit's ${HEADFIT_BRANCH:-main}, and writes where it came from to
#            <out dir>/headfit.elf.source.txt
#   MM_ELF   mm.elf (interactor-motion-matching-guest), the motion-matching controller (M)
#   MUJOCO_ELF  mujoco.elf, double-precision build (mujoco-sandbox-demo project/plans/
#            mujoco.double.elf), the obstacle course's colliders
#   PERSONA_ELF  persona.elf (interactor-taskweft-persona), the persona's plan for a goal
#   MM_DATA  that repo's clip dirs, ':'-separated (data/kimodo-locomotion:data/o3de-motionmatching):
#            one dir per clip (transforms.f32, skeleton.txt, parents.txt, and loop.txt for a
#            steady gait cut as a loop), the controller's pose
#            database; written into res://motion/mm/
#   NOTICES  dir with LICENSE.md, NOTICE and CITATION.cff for the viewer, as written by
#            tools/licences/licgen.py and published in its HF download repo
#            (chibifire/interactor-skintokens-viewer or chibifire/interactor-kimodo-motion-viewer).
#            Each package gets the three files at the top level: the MIT, BSD and Apache-2.0
#            parts require their notices to ship with the binaries, and the NVIDIA Open Model
#            License and the Meta Llama 3 licence require a NOTICE file. `package` stops if one
#            is missing.
#   BINTR    optional: dir with macos/, windows/ and linux/, each holding that OS's native
#            translations bintr-<HASH>.dylib, .dll or .so (tools/compile_bintr.sh); a package
#            without them runs every guest in the interpreter
# <w> holds mesh-encoder.gguf, skin-vae.gguf and tokenrig.gguf (skintokens), or
# Kimodo-SOMA-RP-v1.1-gguf/kimodo-soma-rp-v1.1.gguf (kimodo-motion, chibifire/Kimodo-SOMA-RP-v1.1-gguf).
# The pck is OS-independent; `package` runs anywhere with zip (macOS/Windows archives); the Linux
# tar.gz is written by :erl_tar, no external tar needed. Archives store the weights uncompressed
# (zip -0 for .gguf).

defmodule PackageDesktop do
  @pck_name "skintokens-viewer.pck"
  @pck_files ~w(skintokens.elf usd.elf motion.elf headfit.elf mm.elf liltoon.tar
                AssetPackageExport.sgd mujoco.elf colliders.json AutoRig.gd FdbServer.gd
                FaceBlink.gd FaceRoles.gd UsdImport.gd Motion.gd MotionMatch.gd Bintr.gd
                clips.tsv walk.f32 mm/skeleton.txt)
  @station_files ~w(station.gd slug.double.elf texture_means.json)

  def main(argv) do
    case run(argv) do
      :ok -> 0
      {:error, reason} -> IO.puts(:stderr, format(reason)); 1
    end
  end

  defp format(r) when is_binary(r), do: r
  defp format(r), do: inspect(r)

  defp run(["pck", out]), do: pck(out)
  defp run(["package", out, w]), do: package(out, w, "skintokens")
  defp run(["package", out, w, variant]), do: package(out, w, variant)
  defp run(_), do: {:error, usage()}

  defp usage do
    """
    elixir tools/package_desktop.exs pck <out dir>            export skintokens-viewer.pck from HEAD
    elixir tools/package_desktop.exs package <out dir> <w> [skintokens|kimodo-motion|walk-mode]
                                                      lay out and archive the three packages
                                                      in <out dir>/<viewer>/ with SHA256SUMS
    """
  end

  # ---- pck ------------------------------------------------------------------------------------

  defp pck(out) do
    with {:ok, out} <- ensure_dir(out),
         here = Path.expand(Path.join(__DIR__, "..")),
         lock = Path.join(out, ".pck.lock"),
         :ok <- lock(lock) do
      try do
        do_pck(out, here)
      after
        File.rmdir(lock)
      end
    end
  end

  defp lock(lock) do
    case File.mkdir(lock) do
      :ok -> :ok
      {:error, :eexist} -> {:error, "another pck build is using #{Path.dirname(lock)}"}
      {:error, r} -> {:error, "cannot create #{lock}: #{r}"}
    end
  end

  defp do_pck(out, here) do
    src = Path.join(out, "src")

    with :ok <- clean(src),
         {:ok, _} <- archive_to(here, src),
         :ok <- (File.rm_rf(Path.join(src, "guest")); :ok),
         :ok <- patch_embed_templates(Path.join(src, "export_presets.cfg")),
         :ok <- write_build_label(here, src),
         :ok <- File.cp(req_env!("ELF"), Path.join(src, "skintokens.elf")),
         :ok <- File.cp(req_env!("USD_ELF"), Path.join(src, "usd.elf")),
         :ok <- File.cp(req_env!("MOTION_ELF"), Path.join(src, "motion.elf")),
         {:ok, headfit} <- headfit_elf(out),
         {:ok, true} <- double_precision?(headfit, "hf_anime_shape"),
         :ok <- File.cp(headfit, Path.join(src, "headfit.elf")),
         :ok <- File.cp(req_env!("MM_ELF"), Path.join(src, "mm.elf")),
         mujoco = req_env!("MUJOCO_ELF"),
         {:ok, true} <- double_precision?(mujoco, "mjc_player_band"),
         :ok <- File.cp(mujoco, Path.join(src, "mujoco.elf")),
         persona = req_env!("PERSONA_ELF"),
         {:ok, true} <- double_precision?(persona, "persona_ask_json"),
         :ok <- File.cp(persona, Path.join(src, "persona.elf")),
         :ok <- copy_station(src),
         :ok <- copy_mm_data(src),
         {:ok, godot} <- godot_bin(),
         {:ok, _} <- run(godot, hl_args() ++ ["--path", src, "--import"]),
         {:ok, pack_log} <- run(godot, hl_args() ++ ["--path", src, "--script", "tools/liltoon_pack.gd"]),
         :ok <- (if String.contains?(pack_log, "SCRIPT ERROR"), do: {:error, "SCRIPT ERROR in liltoon_pack.gd:\n#{pack_log}"}, else: :ok),
         pck_path = Path.join(out, @pck_name),
         {:ok, export_log} <- run(godot, hl_args() ++ ["--path", src, "--export-pack", "Linux", pck_path]),
         :ok <- (if String.contains?(export_log, "SCRIPT ERROR"), do: {:error, "SCRIPT ERROR in export.log:\n#{export_log}"}, else: :ok),
         {:ok, pck_bin} <- File.read(pck_path),
         :ok <- contains_all(pck_bin, @pck_files, "pck"),
         :ok <- (if System.get_env("STATION_DIR"), do: contains_all(pck_bin, @station_files, "pck (campus)"), else: :ok) do
      IO.puts("PCK-OK #{byte_size(pck_bin)} bytes")
      :ok
    end
  end

  defp archive_to(repo, dest) do
    tar = Path.join(System.tmp_dir!(), "package-desktop-#{System.unique_integer([:positive])}.tar")

    with {:ok, _} <- run("git", ["-C", repo, "archive", "--format=tar", "-o", tar, "HEAD"]),
         {:ok, out} <- run("tar", ["-xf", tar, "-C", dest]) do
      File.rm(tar)
      {:ok, out}
    end
  end

  # Points export_presets.cfg's custom_template/release at this run's downloaded template_release
  # runtime for Windows and Linux (the real embed_pck templates). export_presets.cfg in git keeps
  # both blank: $ENGINE is a per-run temp dir, so the path is injected here, not hardcoded. macOS
  # has no custom_template/release option for embed_pck's exporter, so it is left untouched.
  defp patch_embed_templates(path) do
    engine = req_env!("ENGINE")
    win_tpl = Path.join(engine, "godot.windows.template_release.double.x86_64.llvm.exe")
    linux_tpl = Path.join(engine, "godot.linuxbsd.template_release.double.x86_64")

    lines = File.read!(path) |> String.split("\n")

    {patched, _cur} =
      Enum.map_reduce(lines, nil, fn line, cur ->
        cond do
          String.starts_with?(line, ~s(name=")) ->
            [_, name] = Regex.run(~r/name="([^"]*)"/, line)
            {line, name}

          String.starts_with?(line, "custom_template/release=") and cur in ["Windows", "Linux"] ->
            tpl = if cur == "Windows", do: win_tpl, else: linux_tpl
            {~s(custom_template/release="#{tpl}"), cur}

          true ->
            {line, cur}
        end
      end)

    File.write(path, Enum.join(patched, "\n"))
  end

  defp write_build_label(repo, src) do
    with {:ok, sha} <- run("git", ["-C", repo, "rev-parse", "--short", "HEAD"]) do
      sha = String.trim(sha)
      now = DateTime.utc_now()
      date_str = Calendar.strftime(now, "%Y-%m-%d")
      unix_time = DateTime.to_unix(now)

      File.write(Path.join(src, "addons/vsk_version/build_constants.gd"), """
      # Set by the build system, do not modify!

      const BUILD_LABEL = "build @ #{sha}"
      const BUILD_DATE_STR = "#{date_str}"
      const BUILD_UNIX_TIME = #{unix_time}
      """)
    end
  end

  # Unset HEADFIT_ELF: the newest green `guest` run of interactor-headfit's ${HEADFIT_BRANCH:-main},
  # with the run and artifact named to <out>/headfit.elf.source.txt.
  defp headfit_elf(out) do
    case System.get_env("HEADFIT_ELF") do
      nil -> fetch_headfit(out)
      "" -> fetch_headfit(out)
      path -> {:ok, path}
    end
  end

  defp fetch_headfit(out) do
    repo = "V-Sekai-fire/interactor-headfit"
    branch = System.get_env("HEADFIT_BRANCH") || "main"
    ci = Path.join(out, "headfit-ci")

    with {:ok, json} <- run("gh", ["run", "list", "-R", repo, "--workflow", "guest", "--branch", branch,
                                    "--status", "success", "--limit", "1", "--json", "databaseId",
                                    "--jq", ".[0].databaseId"]),
         {:ok, run_id} <- nonempty(json, "no green guest run on #{repo} #{branch}"),
         {:ok, art_json} <- run("gh", ["api", "repos/#{repo}/actions/runs/#{run_id}/artifacts", "--jq",
                                        ~s/.artifacts | map(select(.name | startswith("headfit-elf-"))) | .[0].name/]),
         {:ok, name} <- nonempty(art_json, "#{repo} run #{run_id} has no headfit-elf- artifact"),
         :ok <- clean(ci),
         {:ok, _} <- run("gh", ["run", "download", run_id, "-R", repo, "-n", name, "-D", ci]),
         {:ok, siblings} <- File.read(Path.join(ci, "headfit.elf.siblings.txt")),
         :ok <- File.write(Path.join(out, "headfit.elf.source.txt"), "#{repo} run #{run_id} artifact #{name}\n#{siblings}") do
      {:ok, Path.join(ci, "headfit.elf")}
    end
  end

  # The double-precision viewer refuses a guest whose .sandbox_variant does not name a 40-byte
  # Variant, and the host resolves every guest function through .symtab.
  defp double_precision?(path, marker) do
    with {:ok, bin} <- File.read(path) do
      sbxv = :binary.match(bin, "SBXV(\0\0\0") != :nomatch
      has_marker = :binary.match(bin, marker <> <<0>>) != :nomatch

      if sbxv and has_marker,
        do: {:ok, true},
        else: {:error, "#{path} is not a double-precision build with #{marker}"}
    end
  end

  # The campus: the station addon and its slug guests from a checkout of
  # V-Sekai-fire/entities-sakuragaoka-station (STATION_DIR, pinned by the release). Unset, the pck
  # has no campus and the viewer shows no P row.
  defp copy_station(src) do
    case System.get_env("STATION_DIR") do
      nil -> :ok
      "" -> :ok
      dir ->
        addons = Path.join(src, "addons")
        File.mkdir_p!(addons)

        with {:ok, _} <- File.cp_r(Path.join(dir, "addons/sakuragaoka_station"), Path.join(addons, "sakuragaoka_station")),
             :ok <- File.cp(Path.join(dir, "slug.elf"), Path.join(src, "slug.elf")),
             :ok <- File.cp(Path.join(dir, "slug.double.elf"), Path.join(src, "slug.double.elf")) do
          :ok
        end
    end
  end

  defp copy_mm_data(src) do
    mm = Path.join(src, "motion/mm")
    File.mkdir_p!(mm)
    sets = (req_env!("MM_DATA") |> String.split(":", trim: true))

    dirs =
      Enum.flat_map(sets, fn set ->
        set |> Path.join("*") |> Path.wildcard() |> Enum.filter(&File.dir?/1) |> Enum.sort()
      end)

    if dirs == [], do: raise("MM_DATA names no clip dirs")

    clips =
      Enum.map(dirs, fn d ->
        k = Path.basename(d)
        File.cp!(Path.join(d, "transforms.f32"), Path.join(mm, "#{k}.f32"))

        phase = Path.join(d, "phase.f32")
        if File.exists?(phase), do: File.cp!(phase, Path.join(mm, "#{k}.phase.f32"))

        if File.exists?(Path.join(d, "loop.txt")), do: "#{k}\tloop", else: k
      end)

    File.write!(Path.join(mm, "clips.tsv"), Enum.join(clips, "\n") <> "\n")

    first = hd(dirs)
    # Drop the first three lines (the gdenv/Variant header Godot's binary writer prepends).
    skeleton = File.read!(Path.join(first, "skeleton.txt")) |> String.split("\n") |> Enum.drop(3) |> Enum.join("\n")
    File.write!(Path.join(mm, "skeleton.txt"), skeleton)
    File.cp!(Path.join(first, "parents.txt"), Path.join(mm, "parents.txt"))
    :ok
  end

  defp contains_all(bin, names, what) do
    missing = Enum.reject(names, &(:binary.match(bin, &1) != :nomatch))

    if missing == [],
      do: :ok,
      else: {:error, "the #{what} lacks #{Enum.join(missing, ", ")}"}
  end

  # ---- package ---------------------------------------------------------------------------------

  @variants %{
    "skintokens" => {"skintokens-viewer", ~w(mesh-encoder.gguf skin-vae.gguf tokenrig.gguf)},
    "kimodo-motion" => {"kimodo-motion-viewer", ~w(Kimodo-SOMA-RP-v1.1-gguf/kimodo-soma-rp-v1.1.gguf)},
    "walk-mode" => {"walk-mode-viewer", []}
  }

  defp package(out, w, variant) do
    with {app, weights} <- Map.get(@variants, variant, {:error, "unknown viewer #{variant}"}),
         :ok <- need_files(w, weights, "missing"),
         notices = req_env!("NOTICES"),
         :ok <- need_files(notices, ~w(LICENSE.md NOTICE CITATION.cff), "missing $NOTICES"),
         pck_bin = Path.join(out, @pck_name),
         src = Path.join(out, "src"),
         :ok <- lay(out, variant, app, weights, w, notices, "macos", "godot.macos.template_release.double.arm64", "", "libfdb_c.dylib", "macos.arm64", nil, pck_bin, src),
         :ok <- lay(out, variant, app, weights, w, notices, "windows", "godot.windows.template_release.double.x86_64.llvm.exe", ".exe", "fdb_c.dll", "windows.x86_64.exe", "Windows", pck_bin, src),
         :ok <- lay(out, variant, app, weights, w, notices, "linux", "godot.linuxbsd.template_release.double.x86_64", "", "libfdb_c.so", "linux.x86_64", "Linux", pck_bin, src),
         vdir = Path.join(out, variant),
         :ok <- archive(vdir, app) do
      IO.puts("PACKAGE-OK")
      :ok
    end
  end

  defp need_files(dir, names, what) do
    missing = Enum.reject(names, &File.exists?(Path.join(dir, &1)))

    if missing == [],
      do: :ok,
      else: {:error, "#{what} #{Enum.map_join(missing, ", ", &Path.join(dir, &1))}"}
  end

  # <preset> is nil for macOS, which has no embed_pck option in Godot's bundle exporter here: it
  # keeps the bare binary + same-named sibling .pck (Godot's own fallback lookup), the real
  # mechanism on that OS, not a stand-in for one. Windows and Linux run Godot's own
  # --export-release against the project `pck` left imported at <out>/src, with
  # custom_template/release already pointed at this run's downloaded runtime and
  # binary_format/embed_pck=true in export_presets.cfg -- so the engine appends and patches the
  # pck itself (fixup_embedded_pck): one self-contained binary, nothing to go missing beside it.
  defp lay(out, variant, app, weights, w, notices, os, runtime, suffix, fdb_client, server_platform, preset, pck_bin, src) do
    engine = req_env!("ENGINE")
    d = Path.join([out, variant, os, app])

    with :ok <- clean(d),
         :ok <- place_binary(preset, d, app, suffix, engine, runtime, pck_bin, src) do
      with :ok <- File.cp(Path.join(engine, fdb_client), Path.join(d, fdb_client)),
           :ok <- File.cp(Path.join(engine, "fdbserver.#{server_platform}"), Path.join(d, "fdbserver#{suffix}")),
           :ok <- chmod_x(Path.join(d, "fdbserver#{suffix}")),
           :ok <- File.cp(Path.join(engine, "fdbcli.#{server_platform}"), Path.join(d, "fdbcli#{suffix}")),
           :ok <- chmod_x(Path.join(d, "fdbcli#{suffix}")),
           :ok <- File.cp(Path.join(engine, "LICENSE-model-explorer.txt"), Path.join(d, "LICENSE-model-explorer.txt")),
           :ok <- File.cp(Path.join(notices, "LICENSE.md"), Path.join(d, "LICENSE.md")),
           :ok <- File.cp(Path.join(notices, "NOTICE"), Path.join(d, "NOTICE")),
           :ok <- File.cp(Path.join(notices, "CITATION.cff"), Path.join(d, "CITATION.cff")),
           :ok <- link_weights(d, weights, w),
           :ok <- link_bintr(d, os) do
        :ok
      end
    end
  end

  defp place_binary(nil, d, app, suffix, engine, runtime, pck_bin, _src) do
    exe = Path.join(d, "#{app}#{suffix}")

    with :ok <- File.cp(Path.join(engine, runtime), exe),
         :ok <- chmod_x(exe) do
      # macOS fallback: Godot loads the pck named after the program.
      File.cp(pck_bin, Path.join(d, "#{app}.pck"))
    end
  end

  defp place_binary(preset, d, app, suffix, _engine, _runtime, _pck_bin, src) do
    with {:ok, godot} <- godot_bin(),
         exe = Path.join(d, "#{app}#{suffix}"),
         {:ok, log} <- run(godot, hl_args() ++ ["--path", src, "--export-release", preset, exe]) do
      cond do
        String.contains?(log, "SCRIPT ERROR") -> {:error, "SCRIPT ERROR exporting #{preset}:\n#{log}"}
        not File.regular?(exe) -> {:error, "--export-release #{preset} produced no #{exe}:\n#{log}"}
        true -> chmod_x(exe)
      end
    end
  end

  defp link_weights(_d, [], _w), do: :ok

  defp link_weights(d, weights, w) do
    Enum.reduce_while(weights, :ok, fn f, _ ->
      dest = Path.join([d, "w", f])
      File.mkdir_p!(Path.dirname(dest))
      src = Path.join(w, f)

      # A hard link where it can (same file system): three layouts of the 1.25 GB weights fit.
      case :file.make_link(String.to_charlist(src), String.to_charlist(dest)) do
        :ok -> {:cont, :ok}
        {:error, _} ->
          case File.cp(src, dest) do
            :ok -> {:cont, :ok}
            e -> {:halt, e}
          end
      end
    end)
  end

  defp link_bintr(d, os) do
    case System.get_env("BINTR") do
      nil -> :ok
      "" -> :ok
      dir ->
        bintr = Path.join(dir, os)
        target = Path.join(d, "bintr")
        File.mkdir_p!(target)

        bintr
        |> Path.join("bintr-*")
        |> Path.wildcard()
        |> Enum.reduce_while(:ok, fn f, _ ->
          case File.cp(f, Path.join(target, Path.basename(f))) do
            :ok -> {:cont, :ok}
            e -> {:halt, e}
          end
        end)
    end
  end

  # Archives hold the files at the top level: Explorer and Archive Utility already extract into a
  # folder named after the archive, so a top folder inside it would give <app>-*/<app>/.
  defp archive(vdir, app) do
    with :ok <- zip(Path.join([vdir, "macos", app]), Path.join(vdir, "#{app}-macos-arm64.zip")),
         :ok <- zip(Path.join([vdir, "windows", app]), Path.join(vdir, "#{app}-windows-x86_64.zip")),
         :ok <- tar_gz(Path.join([vdir, "linux", app]), Path.join(vdir, "#{app}-linux-x86_64.tar.gz")),
         :ok <- write_sums(vdir, app) do
      File.rm_rf(Path.join(vdir, "macos"))
      File.rm_rf(Path.join(vdir, "windows"))
      File.rm_rf(Path.join(vdir, "linux"))
      :ok
    end
  end

  defp zip(dir, out) do
    File.rm(out)

    case run("zip", ["-qry", "-n", ".gguf", out, "."], cd: dir) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  # No external tar needed: :erl_tar writes the gzip tarball directly, with AppleDouble sidecars
  # (._*) skipped the same way the old inline python3 step did.
  defp tar_gz(dir, out) do
    entries =
      files(dir)
      |> Enum.map(fn abs ->
        rel = Path.relative_to(abs, dir)
        {String.to_charlist(rel), String.to_charlist(abs)}
      end)

    File.rm(out)

    case :erl_tar.create(String.to_charlist(out), entries, [:compressed]) do
      :ok -> :ok
      {:error, r} -> {:error, "tar #{out}: #{inspect(r)}"}
    end
  end

  defp files(dir) do
    File.ls!(dir)
    |> Enum.reject(&String.starts_with?(&1, "._"))
    |> Enum.flat_map(fn name ->
      full = Path.join(dir, name)

      cond do
        File.dir?(full) -> files(full)
        File.regular?(full) -> [full]
        true -> []
      end
    end)
  end

  defp write_sums(vdir, app) do
    names =
      [Path.join(vdir, "#{app}-macos-arm64.zip"),
       Path.join(vdir, "#{app}-windows-x86_64.zip"),
       Path.join(vdir, "#{app}-linux-x86_64.tar.gz")]

    lines =
      Enum.map(names, fn p ->
        bin = File.read!(p)
        hex = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
        "#{hex}  #{Path.basename(p)}"
      end)

    File.write!(Path.join(vdir, "SHA256SUMS"), Enum.join(lines, "\n") <> "\n")
    IO.puts(Enum.join(lines, "\n"))
    :ok
  end

  # ---- shared -----------------------------------------------------------------------------------

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         {:ok, abs} <- {:ok, Path.expand(dir)} do
      {:ok, abs}
    end
  end

  defp clean(dir) do
    with {:ok, _} <- File.rm_rf(dir) do
      File.mkdir_p(dir)
    end
  end

  defp chmod_x(path), do: File.chmod(path, 0o755)

  defp req_env!(name) do
    case System.get_env(name) do
      nil -> raise "#{name} is required"
      "" -> raise "#{name} is required"
      v -> v
    end
  end

  # Elixir's `||` only falls through on nil/false, not on "": a trimmed empty or literal "null"
  # string (gh's --jq prints "null" for a missing field) must be checked explicitly.
  defp nonempty(s, err) do
    case String.trim(s) do
      "" -> {:error, err}
      "null" -> {:error, err}
      v -> {:ok, v}
    end
  end

  defp godot_bin do
    case System.get_env("GODOT") || default_godot() do
      nil -> {:error, "no GODOT and no ENGINE/godot.macos.editor.double.arm64"}
      path -> {:ok, path}
    end
  end

  defp default_godot do
    case System.get_env("ENGINE") do
      nil -> nil
      engine -> Path.join(engine, "godot.macos.editor.double.arm64")
    end
  end

  # Headless is blocklisted on the Mac: the editor opens a real (small) window while it exports.
  defp hl_args do
    case :os.type() do
      {:unix, :darwin} -> ["--resolution", "320x180"]
      _ -> ["--headless"]
    end
  end

  defp run(cmd, args, opts \\ []) do
    case System.cmd(cmd, args, [stderr_to_stdout: true] ++ opts) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, "#{Path.basename(cmd)} #{Enum.take(args, 3) |> Enum.join(" ")} exited #{code}: #{tail(out)}"}
    end
  rescue
    e in ErlangError -> {:error, "cannot run #{cmd}: #{Exception.message(e)}"}
  end

  defp tail(s), do: s |> String.split("\n", trim: true) |> Enum.take(-6) |> Enum.join(" | ")
end

System.halt(PackageDesktop.main(System.argv()))
