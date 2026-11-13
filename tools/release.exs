#!/usr/bin/env elixir
# Build, test and stage the Model Explorer viewer (desktop packages) in one run.
#
#   pixi run release                          from the smoke-water root (release.exs is linked
#                                             there by the manifest); builds, tests and stages.
#                                             No arguments are needed; nothing is uploaded
#   pixi run release --publish dev            upload the staged run to branch dev of the repo
#   pixi run release --publish main           upload to main instead (the Spaces link main)
#   pixi run release --viewer <key>           publish only that viewer (repeat for more; default all)
#   pixi run release --desk                   refuses: the Windows desk is blocklisted
#   pixi run release --ref <model-explorer ref>   default $RELEASE_REF, else origin/main
#   pixi run release --resume <dir>           continue a stopped run; finished steps are skipped
#                                             (new runs go under $RELEASE_ROOT, default <root>/.release)
#   pixi run release --until <step>           stop after a step (see @steps)
#   pixi run release --skip <step>            leave a step out (repeat for more): the staged folder gets INCOMPLETE.txt
#                                             and --publish refuses
#   pixi run release --branch <repo>=<branch> take that guest's ELF from its newest green run on
#                                             <branch> instead of main (a release candidate);
#                                             repeat for more repos, the source is recorded
#
# It runs on this machine, a Mac (Apple silicon), and nowhere else. The Windows zip is tested under
# Wine on the Mac GPU (Vulkan through MoltenVK to Metal), the macOS image is built, signed (when the
# release-signing keychain exists) and tested natively, the Linux tar is checked and reported
# UNTESTED because no window can run in a container here. The Windows desk and WSL are blocklisted:
# `--desk` refuses. A run STAGES the Model Explorer viewer (SHA256SUMS
# checked); nothing is uploaded unless `--publish dev|main` is given. Every input comes from a green
# main CI run, a release, or a pinned checkout, and its source is written to <dir>/SOURCES.txt:
#   engine     newest *-double.* release of V-Sekai-fire/service-godot-build (SHA256SUMS checked)
#   sandbox    newest green Builds run on V-Sekai-fire/godot-sandbox main
#   guests     newest green guest run on main of interactor-skintokens-guest, -motion-guest,
#              interactor-headfit
#   usd        usd.elf has no CI build: it is carried from the published Model Explorer viewer's pck
# Gates, in order (the run stops at the first failure and says which):
#   each ELF equals the hash written when it was fetched, and a planted corrupt ELF must fail that
#   check; each ELF in the exported pck equals its input; the Windows zip (Wine), the macOS image and
#   the Linux tar start and report their features; the staged folder passes
#   `shasum -c`, and a planted tampered copy must fail it.
# Releases are tagged v<YYYYMMDD>-dev.N (RFD66606-2293), then -beta.N, -rc.N and the bare
# v<YYYYMMDD>; the date is the day the run starts. A run takes each viewer's published tag
# (VERSION in its download repo, else the tag on its Space page; an older vX.Y.Z-dev.N counts) and
# raises N by one; <dir>/version/<viewer> keeps it, so --resume publishes the same tag.
# Tokens come from OpenBao (bao-mint-github, bao-hf-token or bao-env) and never reach argv.
# Functions return {:ok, value} or {:error, reason}; nothing raises.

defmodule Release do
  @steps ~w(engine sandbox guests weights source notices pck package dmg test_windows test_mac test_linux web test_load stage publish)
  @max_private_mb 8192
  @win_run_ms 1_800_000
  @em_x86_64 62
  # The macOS image is signed with this Developer ID (in the Mac's release-signing keychain) and
  # notarized; the test then checks Gatekeeper accepts it.
  @sign_id "Developer ID Application: Ernest Lee (F48WQK5Y2R)"
  @viewers [
    %{key: "skintokens", app: "skintokens-viewer", name: "Model Explorer",
      repo: "chibifire/interactor-skintokens-viewer", space: "chibifire/skintokens-auto-rig", rig: true, mac_zip: true,
      web: false}
  ]
  @elfs ~w(skintokens.elf usd.elf motion.elf headfit.elf persona.elf)
  @weights ~w(mesh-encoder.gguf skin-vae.gguf tokenrig.gguf)
  @editor "godot.macos.editor.double.arm64"
  @wine_version "11.18"
  @engine_files ~w(godot.macos.editor.double.arm64 godot.linuxbsd.template_release.double.x86_64
                   godot.macos.template_release.double.arm64 godot.windows.template_release.double.x86_64.llvm.exe)
  @guests [
    {"interactor-skintokens-guest", "skintokens-elf-", "skintokens.elf"},
    {"interactor-motion-guest", "motion-elf-", "motion.elf"},
    {"interactor-headfit", "headfit-elf-", "headfit.elf"},
    {"interactor-taskweft-persona", "persona-elf-", "persona.elf"}
  ]

  def main(argv) do
    result =
      if :os.type() == {:unix, :darwin},
        do: run(argv),
        else: {:error, "the release runs on a Mac (Apple silicon) only; the Windows desk and WSL are blocklisted"}

    case result do
      {:ok, dir} ->
        IO.puts("RELEASE-OK #{dir}")
        0

      {:error, reason} ->
        IO.puts(:stderr, "RELEASE-FAIL #{format(reason)}")
        1
    end
  end

  defp format(r) when is_binary(r), do: r
  defp format(r), do: inspect(r)

  defp run(argv) do
    {opts, _, bad} =
      OptionParser.parse(argv, strict: [desk: :boolean, publish: :string, ref: :string, resume: :string, until: :string, skip: :keep, branch: :keep, viewer: :keep])

    with :ok <- if(opts[:desk], do: {:error, "--desk refuses: the Windows desk is blocklisted, the release runs on this Mac"}, else: :ok),
         :ok <- if(bad == [], do: :ok, else: {:error, "unknown options #{inspect(bad)}"}),
         {:ok, root} <- workspace_root(),
         publish = opts[:publish] || "none",
         :ok <- if(publish in ~w(none dev main), do: :ok, else: {:error, "--publish is none, dev or main"}),
         skip = Keyword.get_values(opts, :skip),
         only = Keyword.get_values(opts, :viewer),
         :ok <- if(Enum.all?(only, &(&1 in Enum.map(@viewers, fn v -> v.key end))), do: :ok, else: {:error, "--viewer is one of #{Enum.map_join(@viewers, " ", & &1.key)}"}),
         :ok <- if(Enum.all?(skip, &(&1 in @steps)), do: :ok, else: {:error, "--skip is one of #{Enum.join(@steps, " ")}"}),
         :ok <- if(skip == [] or publish == "none", do: :ok, else: {:error, "--skip leaves the release incomplete: it cannot be published"}),
         until = opts[:until] || List.last(@steps),
         :ok <- if(until in @steps, do: :ok, else: {:error, "--until is one of #{Enum.join(@steps, " ")}"}),
         dir = opts[:resume] || Path.join(release_root(root), stamp()),
         :ok <- File.mkdir_p(Path.join(dir, ".done")) do
      ctx = %{root: root, dir: dir, publish: publish, ref: opts[:ref] || System.get_env("RELEASE_REF") || "origin/main", id: Path.basename(dir), skip: skip, only: only,
              branches: Map.new(Keyword.get_values(opts, :branch), &List.to_tuple(String.split(&1, "=", parts: 2)))}
      IO.puts("release #{ctx.id} in #{dir} (publish: #{publish})")
      steps = Enum.take_while(@steps, &(&1 != until)) ++ [until]

      Enum.reduce_while(steps, {:ok, dir}, fn step, acc ->
        # Publishing to dev and then to main from the same folder are two different steps.
        marker = Path.join([dir, ".done", if(step == "publish", do: Enum.join(["publish", publish | Enum.sort(only)], "-"), else: step)])

        cond do
          step in skip ->
            IO.puts("== #{step}: SKIPPED by --skip; the staged folder is marked incomplete")
            {:cont, acc}

          File.exists?(marker) ->
            IO.puts("== #{step}: done in an earlier run")
            {:cont, acc}

          true ->
            IO.puts("== #{step}")

            case apply(__MODULE__, String.to_atom("step_" <> step), [ctx]) do
              :ok -> File.write(marker, stamp()); {:cont, acc}
              {:error, reason} -> {:halt, {:error, {String.to_atom(step), reason}}}
            end
        end
      end)
    end
  end

  defp workspace_root do
    start = Path.expand(__DIR__)

    Stream.iterate(start, &Path.dirname/1)
    |> Enum.take(8)
    |> Enum.find(&File.dir?(Path.join(&1, ".repo")))
    |> case do
      nil -> {:error, "no .repo above #{start}: run from the smoke-water root"}
      root -> {:ok, root}
    end
  end

  # A release folder holds about 4 GB (the engine, sandbox libraries, packages and web build).
  # RELEASE_ROOT picks where; the default is <client>/.release.
  defp release_root(root), do: System.get_env("RELEASE_ROOT") || Path.join(root, ".release")

  defp stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")

  # ---- steps ---------------------------------------------------------------------------------

  def step_engine(ctx) do
    d = Path.join(ctx.dir, "engine")

    with {:ok, tok} <- gh_token("V-Sekai-fire"),
         {:ok, json} <- cap("gh", ~w(release list -R V-Sekai-fire/service-godot-build -L 30 --json tagName), gh_env(tok)),
         {:ok, list} <- decode(json),
         tag when is_binary(tag) <- Enum.find_value(list, &(String.contains?(&1["tagName"], "-double.") && &1["tagName"])) || {:error, "no double release"},
         :ok <- File.mkdir_p(d),
         pats = Enum.flat_map(["SHA256SUMS" | @engine_files], &["-p", &1]),
         {:ok, _} <- cap("gh", ["release", "download", tag, "-R", "V-Sekai-fire/service-godot-build", "-D", d, "--clobber" | pats], gh_env(tok)),
         :ok <- check_sums(d, @engine_files),
         :ok <- Enum.reduce_while(@engine_files, :ok, fn f, _ -> chmod_x(Path.join(d, f)) end),
         {:ok, _} <- File.copy(Path.join(ctx.root, "4-entities/model-explorer/LICENSE"), Path.join(d, "LICENSE-model-explorer.txt")) do
      source(ctx, "engine V-Sekai-fire/service-godot-build #{tag}")
    end
  end

  def step_sandbox(ctx) do
    d = Path.join(ctx.dir, "sandbox")
    names = ~w(godot-sandbox-macos-universal-double godot-sandbox-windows-x86_64-double godot-sandbox-linux-x86_64-double)

    with {:ok, tok} <- gh_token("V-Sekai-fire"),
         {:ok, run, sha} <- green_run(tok, "V-Sekai-fire/godot-sandbox", "Builds"),
         :ok <- clean(d),
         :ok <- Enum.reduce_while(names, :ok, fn n, _ ->
           case cap("gh", ["run", "download", run, "-R", "V-Sekai-fire/godot-sandbox", "-n", n, "-D", Path.join(d, n)], gh_env(tok)) do
             {:ok, _} -> {:cont, :ok}
             e -> {:halt, e}
           end
         end),
         :ok <- flatten_libs(d),
         :ok <- need(d, ~w(libgodot_riscv.macos.template_release.double.universal.framework
                          libgodot_riscv.windows.template_release.double.x86_64.dll
                          libgodot_riscv.linux.template_release.double.x86_64.so)) do
      source(ctx, "sandbox V-Sekai-fire/godot-sandbox Builds run #{run} (#{sha})")
    end
  end

  def step_guests(ctx) do
    d = Path.join(ctx.dir, "elf")

    with {:ok, tok} <- gh_token("V-Sekai-fire"),
         :ok <- clean(d),
         :ok <- Enum.reduce_while(@guests, :ok, fn {repo, prefix, file}, _ ->
           case guest(ctx, tok, repo, prefix, file, d) do
             :ok -> {:cont, :ok}
             e -> {:halt, e}
           end
         end),
         :ok <- usd_from_published(ctx, d) do
      write_sums(d, @elfs)
    end
  end

  defp guest(ctx, tok, repo, prefix, file, d) do
    r = "V-Sekai-fire/" <> repo

    with {:ok, run, sha} <- green_run(tok, r, "guest", Map.get(ctx.branches, repo, "main")),
         {:ok, json} <- cap("gh", ["api", "repos/#{r}/actions/runs/#{run}/artifacts"], gh_env(tok)),
         {:ok, %{"artifacts" => arts}} <- decode(json),
         name when is_binary(name) <- Enum.find_value(arts, &(String.starts_with?(&1["name"], prefix) && &1["name"])) || {:error, "#{r} run #{run} has no #{prefix} artifact"},
         tmp = Path.join(d, "ci-" <> repo),
         {:ok, _} <- cap("gh", ["run", "download", run, "-R", r, "-n", name, "-D", tmp], gh_env(tok)),
         {:ok, _} <- File.copy(Path.join(tmp, file), Path.join(d, file)) do
      source(ctx, "#{file} #{r} #{Map.get(ctx.branches, repo, "main")} guest run #{run} artifact #{name}")
    end
  end

  # usd.elf has no CI build. Carry it from the published Model Explorer viewer (its Windows zip is the
  # smallest package holding the pck), after checking that zip against the repo's SHA256SUMS.
  defp usd_from_published(ctx, d) do
    repo = "chibifire/interactor-skintokens-viewer"
    zip = Path.join(d, "previous-skintokens-windows.zip")

    with {:ok, tok} <- hf_token(),
         {:ok, sums} <- hf_get(tok, repo, "SHA256SUMS", Path.join(d, "previous-SHA256SUMS")),
         want when is_binary(want) <- sum_for(sums, "skintokens-viewer-windows-x86_64.zip") || {:error, "#{repo} SHA256SUMS lacks the Windows zip"},
         {:ok, _} <- hf_get(tok, repo, "skintokens-viewer-windows-x86_64.zip", zip),
         {:ok, ^want} <- sha256(zip),
         {:ok, [{_, pck}]} <- :zip.extract(String.to_charlist(zip), [{:file_list, [~c"skintokens-viewer.pck"]}, :memory]),
         {:ok, files} <- pck_files(pck),
         usd when is_binary(usd) <- files["usd.elf"] || {:error, "the published pck has no usd.elf"},
         :ok <- File.write(Path.join(d, "usd.elf"), usd),
         :ok <- File.rm(zip) do
      source(ctx, "usd.elf carried from #{repo} main skintokens-viewer-windows-x86_64.zip #{String.slice(want, 0, 12)} (sha256 #{hex(:crypto.hash(:sha256, usd)) |> String.slice(0, 12)})")
    else
      {:ok, other} when is_binary(other) -> {:error, "the published skintokens-viewer zip does not match its SHA256SUMS (#{String.slice(other, 0, 12)})"}
      e -> e
    end
  end

  def step_weights(ctx) do
    if Enum.any?(@viewers, & &1.rig), do: weights(ctx), else: (IO.puts("  no viewer here needs weights"); :ok)
  end

  defp weights(ctx) do
    d = Path.join(ctx.dir, "w")
    repo = "chibifire/SkinTokens-GGUF-BF16"

    with {:ok, tok} <- hf_token(),
         :ok <- File.mkdir_p(d),
         {:ok, sums} <- hf_get(tok, repo, "SHA256SUMS", Path.join(d, "SHA256SUMS")),
         :ok <- Enum.reduce_while(@weights, :ok, fn f, _ ->
           p = Path.join(d, f)
           want = sum_for(sums, f)

           with true <- is_binary(want) || {:error, "#{repo} SHA256SUMS lacks #{f}"},
                {:ok, have} <- (if File.exists?(p), do: sha256(p), else: {:ok, ""}),
                {:ok, _} <- (if have == want, do: {:ok, :kept}, else: hf_get(tok, repo, f, p)),
                {:ok, ^want} <- sha256(p) do
             {:cont, :ok}
           else
             {:ok, _} -> {:halt, {:error, "#{f} does not match #{repo} SHA256SUMS"}}
             e -> {:halt, e}
           end
         end) do
      source(ctx, "weights #{repo} main (SHA256SUMS checked)")
    end
  end

  def step_source(ctx) do
    me = Path.join(ctx.root, "4-entities/model-explorer")
    src = Path.join(ctx.dir, "model-explorer")

    with {:ok, _} <- cap("git", ["-C", me, "fetch", "-q", "origin"]),
         {:ok, sha} <- cap("git", ["-C", me, "rev-parse", ctx.ref <> "^{commit}"]),
         sha = String.trim(sha),
         _ = cap("git", ["-C", me, "worktree", "remove", "--force", src]),
         {:ok, _} <- cap("git", ["-C", me, "worktree", "add", "--detach", src, sha]),
         :ok <- need(src, ~w(tools/licences/licgen.py)),
         {:ok, {_cmd, pkg_path}} <- pkg_script(src),
         {:ok, _pkg} <- File.read(pkg_path) do
      source(ctx, "viewer source V-Sekai-fire/entities-model-explorer #{sha} (#{ctx.ref})")

      Enum.reduce_while(@viewers, :ok, fn v, _ ->
        case version(ctx, v) do
          {:ok, ver} -> source(ctx, "version #{v.key} #{ver}"); {:cont, :ok}
          e -> {:halt, e}
        end
      end)
    end
  end

  def step_notices(ctx) do
    out = Path.join(ctx.dir, "notices")

    with :ok <- clean(out),
         {:ok, _} <- cap("python", [Path.join(ctx.dir, "model-explorer/tools/licences/licgen.py"), out]) do
      need(out, Enum.flat_map(@viewers, fn v -> Enum.map(~w(LICENSE.md NOTICE CITATION.cff), &Path.join(v.key, &1)) end))
    end
  end

  def step_pck(ctx) do
    out = Path.join(ctx.dir, "pck")
    elf = Path.join(ctx.dir, "elf")

    env = [
      {"ENGINE", Path.join(ctx.dir, "engine")},
      {"GODOT", Path.join(ctx.dir, "engine/" <> @editor)},
      {"SANDBOX", Path.join(ctx.dir, "sandbox")},
      {"ELF", Path.join(elf, "skintokens.elf")},
      {"USD_ELF", Path.join(elf, "usd.elf")},
      {"MOTION_ELF", Path.join(elf, "motion.elf")},
      {"HEADFIT_ELF", Path.join(elf, "headfit.elf")},
      {"PERSONA_ELF", Path.join(elf, "persona.elf")}
    ]

    with :ok <- check_sums(elf, @elfs),
         :ok <- control("guest ELFs", elf, @elfs),
         {:ok, {cmd, script}} <- pkg_script(Path.join(ctx.dir, "model-explorer")),
         {:ok, log} <- cap(cmd, [script, "pck", out], env),
         true <- String.contains?(log, "PCK-OK") || {:error, "#{Path.basename(script)} pck printed no PCK-OK"},
         {:ok, bin} <- File.read(Path.join(out, "skintokens-viewer.pck")),
         {:ok, files} <- pck_files(bin) do
      Enum.reduce_while(@elfs, :ok, fn f, _ ->
        case {File.read(Path.join(elf, f)), Map.fetch(files, f)} do
          {{:ok, b}, {:ok, b}} -> {:cont, :ok}
          {{:ok, _}, {:ok, _}} -> {:halt, {:error, "#{f} in the pck differs from its input"}}
          {{:ok, _}, :error} -> {:halt, {:error, "the pck lacks #{f}"}}
          {e, _} -> {:halt, e}
        end
      end)
    end
  end

  def step_package(ctx) do
    out = Path.join(ctx.dir, "pck")

    Enum.reduce_while(@viewers, :ok, fn v, _ ->
      env = [{"ENGINE", Path.join(ctx.dir, "engine")}, {"SANDBOX", Path.join(ctx.dir, "sandbox")},
             {"GODOT", Path.join(ctx.dir, "engine/" <> @editor)},
             {"NOTICES", Path.join([ctx.dir, "notices", v.key])}]

      with {:ok, {cmd, script}} <- pkg_script(Path.join(ctx.dir, "model-explorer")),
           {:ok, log} <- cap(cmd, [script, "package", out, Path.join(ctx.dir, "w"), v.key], env),
           true <- String.contains?(log, "PACKAGE-OK") || {:error, "#{v.key}: no PACKAGE-OK"},
           # The archives are the release; the per-OS folders they were made from are not kept.
           :ok <- Enum.reduce_while(~w(macos windows linux), :ok, fn os, _ ->
             case File.rm_rf(Path.join([out, v.key, os])) do
               {:ok, _} -> {:cont, :ok}
               {:error, r, f} -> {:halt, {:error, "cannot remove #{f}: #{r}"}}
             end
           end) do
        {:cont, :ok}
      else
        e -> {:halt, e}
      end
    end)
  end

  def step_dmg(ctx) do
    Enum.reduce_while(@viewers, :ok, fn v, _ ->
      o = Path.join([ctx.dir, "pck", v.key])
      m = Path.join([ctx.dir, "mac", v.key])
      zip = "#{v.app}-macos-arm64.zip"
      dmg = "#{v.app}-macos-arm64.dmg"

      with :ok <- clean(m),
           {:ok, _} <- File.copy(Path.join(o, zip), Path.join(m, zip)),
           {:ok, ver} <- version(ctx, v),
           {:ok, out} <- mac(ctx, dmg_script(v, m, zip, dmg, ctx.id, ver)),
           {:ok, _} <- File.copy(Path.join(m, dmg), Path.join(o, dmg)),
           :ok <- sums(o, v) do
        IO.puts("  macos #{v.key}: #{tail(out)}")
        {:cont, :ok}
      else
        e -> {:halt, e}
      end
    end)
  end

  # One SHA256SUMS per viewer: the files that viewer publishes.
  defp sums(o, v) do
    files = archives(v)

    Enum.reduce_while(files, {:ok, []}, fn f, {:ok, acc} ->
      case sha256(Path.join(o, f)) do
        {:ok, h} -> {:cont, {:ok, ["#{h}  #{f}\n" | acc]}}
        e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, lines} -> File.write(Path.join(o, "SHA256SUMS"), lines |> Enum.reverse())
      e -> e
    end
  end

  defp archives(v) do
    mac = if v.mac_zip, do: ["#{v.app}-macos-arm64.zip", "#{v.app}-macos-arm64.dmg"], else: ["#{v.app}-macos-arm64.dmg"]
    mac ++ ["#{v.app}-windows-x86_64.zip", "#{v.app}-linux-x86_64.tar.gz"]
  end

  # The image is signed with the Developer ID and notarized only when this Mac already holds the
  # release-signing keychain; its password and the notary key come from OpenBao. Without the
  # keychain the image is built unsigned and signed.txt says so. No credential is ever created here.
  defp dmg_script(v, dir, zip, dmg, id, ver) do
    """
    set -eu
    cd '#{dir}'
    rm -rf unz stage; mkdir unz; (cd unz && unzip -q ../#{zip})
    C="stage/#{v.name}.app/Contents"; mkdir -p "$C/MacOS" "$C/Resources" "$C/Frameworks"
    cp unz/#{v.app} "$C/MacOS/"
    # codesign takes every file in MacOS/ for code, so the weights sit in Resources/ behind a link.
    [ ! -d unz/w ] || { cp -R unz/w "$C/Resources/w"; ln -s ../Resources/w "$C/MacOS/w"; }
    cp unz/#{v.app}.pck unz/LICENSE.md unz/NOTICE unz/CITATION.cff unz/LICENSE-model-explorer.txt "$C/Resources/"
    cp -R unz/libgodot_riscv.macos.template_release.double.universal.framework "$C/Frameworks/"
    cat > "$C/Info.plist" <<'P'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>#{v.app}</string>
    <key>CFBundleIdentifier</key><string>com.chibifire.#{v.app}</string>
    <key>CFBundleName</key><string>#{v.name}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>#{short_version(ver)}</string>
    <key>CFBundleVersion</key><string>#{id}</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    </dict></plist>
    P
    plutil -lint "$C/Info.plist" >/dev/null
    find stage -name '._*' -delete; xattr -cr stage
    export PATH=/opt/homebrew/bin:$PATH
    KC=$HOME/Library/Keychains/release-signing.keychain-db
    ID="#{@sign_id}"
    if [ -f "$KC" ]; then
      . ~/.local/bin/bao-login.sh >/dev/null 2>&1
      security unlock-keychain -p "$(bao kv get -field=password "secret/agents-own/$BAO_CN/apple-signing-keychain")" "$KC"
      security list-keychains -d user | grep -q release-signing || security list-keychains -d user -s "$KC" "$HOME/Library/Keychains/login.keychain-db"
      cat > ent.plist <<'P'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
    P
      FW="$C/Frameworks/libgodot_riscv.macos.template_release.double.universal.framework"
      mkdir -p "$FW/Resources"
      cat > "$FW/Resources/Info.plist" <<'P'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>CFBundleExecutable</key><string>libgodot_riscv.macos.template_release.double.universal</string><key>CFBundleIdentifier</key><string>com.chibifire.libgodot_riscv.macos.template_release.double.universal</string><key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleName</key><string>libgodot_riscv.macos.template_release.double.universal</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1</string></dict></plist>
    P
      codesign --force --timestamp --options runtime -s "$ID" "$FW"
      codesign --force --timestamp --options runtime --entitlements ent.plist -s "$ID" "stage/#{v.name}.app"
      codesign --verify --deep --strict "stage/#{v.name}.app"
    fi
    ln -s /Applications stage/Applications; cp unz/LICENSE.md unz/NOTICE unz/CITATION.cff stage/
    COPYFILE_DISABLE=1 hdiutil create -quiet -volname "#{v.name}" -srcfolder stage -fs APFS -format ULFO -ov #{dmg}
    hdiutil verify -quiet #{dmg}
    if [ -f "$KC" ]; then
      codesign --force --timestamp -s "$ID" #{dmg}
      K=$(mktemp -d); trap 'rm -rf "$K"' EXIT
      bao kv get -format=json "secret/agents-own/$BAO_CN/apple-notary-key" | python3 -c '
    import json, re, sys, os
    d = json.load(sys.stdin)["data"]["data"]
    b = re.sub(r"[^A-Za-z0-9+/=]", "", re.sub(r"-----(BEGIN|END) PRIVATE KEY-----", "", d["p8"]))
    k = sys.argv[1]
    open(os.path.join(k, "key.p8"), "w").write("-----BEGIN PRIVATE KEY-----\\n" + "\\n".join(b[i:i+64] for i in range(0, len(b), 64)) + "\\n-----END PRIVATE KEY-----\\n")
    open(os.path.join(k, "id"), "w").write(d["key_id"].strip()); open(os.path.join(k, "iss"), "w").write(d["issuer_id"].strip())' "$K"
      xcrun notarytool submit #{dmg} --key "$K/key.p8" --key-id "$(cat "$K/id")" --issuer "$(cat "$K/iss")" --wait --timeout 2h > notary.log 2>&1 || true
      grep -q "status: Accepted" notary.log || { tail -5 notary.log; exit 1; }
      xcrun stapler staple -q #{dmg}
      spctl -a -t open --context context:primary-signature #{dmg}
      echo SIGNED > signed.txt
      echo "DMG-OK signed and notarized"
    else
      echo UNSIGNED > signed.txt
      echo "DMG-OK UNSIGNED (this Mac has no release-signing keychain)"
    fi
    rm -rf unz stage ent.plist
    """
  end

  # ---- Windows under Wine on the Mac GPU ---------------------------------------------------------
  #
  # The Windows build runs in a real window: Vulkan through Wine's winevulkan and MoltenVK to Metal.
  # Headless and the dummy renderer are blocklisted. Wine comes from Gcenx/macOS_Wine_builds (the
  # asset's sha256 digest is checked) into RELEASE_CACHE; Rosetta must already be installed.

  defp cache_dir, do: System.get_env("RELEASE_CACHE") || Path.expand("~/.cache/smoke-water-release")
  defp wine_root, do: Path.join(cache_dir(), "wine")
  defp wine_bin, do: Path.join(wine_root(), "Wine Devel.app/Contents/Resources/wine/bin/wine")

  defp wine_env, do: [{"WINEPREFIX", Path.join(wine_root(), "prefix")}, {"WINEDEBUG", "-all"}, {"WINEDLLOVERRIDES", "mscoree,mshtml="}]

  defp ensure_wine do
    with {:ok, _} <- cap("arch", ["-x86_64", "/usr/bin/true"]) |> rosetta() do
      if File.exists?(wine_bin()), do: :ok, else: install_wine()
    end
  end

  defp rosetta({:ok, o}), do: {:ok, o}
  defp rosetta({:error, why}), do: {:error, "Wine needs Rosetta (softwareupdate --install-rosetta): #{why}"}

  defp install_wine do
    sh = ~S"""
    set -eu
    NAME=wine-devel-$1-osx64.tar.xz
    mkdir -p "$WINE_ROOT"; cd "$WINE_ROOT"
    LINE=$(curl -sf "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/tags/$1" | /usr/bin/python3 -c "
    import json, sys
    for a in json.load(sys.stdin)['assets']:
        if a['name'] == '$NAME':
            print(a['browser_download_url'], a.get('digest', ''))")
    [ -n "$LINE" ] || { echo "no asset $NAME in release $1"; exit 1; }
    URL=${LINE%% *}; SUM=$(echo "$LINE" | awk '{print $2}' | sed 's/^sha256://')
    [ -n "$SUM" ] || { echo "release gives no digest for $NAME"; exit 1; }
    curl -sfLO "$URL"
    echo "$SUM  $NAME" | shasum -a 256 -c
    tar -xJf "$NAME"; rm -f "$NAME"
    xattr -dr com.apple.quarantine . 2>/dev/null || true
    """

    with {:ok, _} <- cap("sh", ["-c", sh, "sh", @wine_version], [{"WINE_ROOT", wine_root()}]), do: :ok
  end

  # Run a Windows exe under Wine, in its own folder, and return its peak resident memory in MB once
  # its output holds `want` and names the Apple GPU. /usr/bin/time -l reports the peak.
  defp win_run(exe, args, want, log) do
    argv = ["-l", wine_bin(), Path.basename(exe), "--rendering-driver", "vulkan", "--fixed-fps", "60", "--" | args]
    task = Task.async(fn -> System.cmd("/usr/bin/time", argv, env: wine_env(), stderr_to_stdout: true, cd: Path.dirname(exe)) end)

    case Task.yield(task, @win_run_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, _code}} ->
        File.write(log, out)

        cond do
          not String.contains?(out, want) -> {:error, "#{Path.basename(log)}: no #{want}; last lines: #{tail(out)}"}
          not Regex.match?(~r/Using Device #\d+: Apple/, out) -> {:error, "#{Path.basename(log)}: Wine did not draw on the Apple GPU"}
          true ->
            case Regex.run(~r/(\d+)\s+maximum resident set size/, out) do
              [_, b] -> {:ok, div(String.to_integer(b), 1_048_576)}
              _ -> {:error, "#{Path.basename(log)}: no peak memory line"}
            end
        end

      _ ->
        cap("pkill", ["-f", "wineserver"])
        {:error, "#{Path.basename(exe)} did not finish in #{div(@win_run_ms, 60_000)} min under Wine"}
    end
  end

  defp girl(ctx), do: Path.join(ctx.root, "3-interactor/test-godot-vrm-motion-checker/fire_motion_check/art/three_girl/three-vrm-girl.vrm")

  def step_test_windows(ctx) do
    with :ok <- ensure_wine() do
      Enum.reduce_while(@viewers, :ok, fn v, _ ->
        d = Path.join([ctx.dir, "test-windows", v.key])
        exe = Path.join(d, v.app <> ".exe")

        with :ok <- clean(d),
             {:ok, _} <- cap("unzip", ["-q", Path.join([ctx.dir, "pck", v.key, "#{v.app}-windows-x86_64.zip"]), "-d", d]),
             {:ok, _} <- File.copy(girl(ctx), Path.join(d, "three-vrm-girl.vrm")),
             {:ok, peak} <- win_run(exe, ["--features-quit"], "VIEWER-FEATURES rig=#{v.rig}", Path.join(d, "features.log")),
             true <- peak < @max_private_mb || {:error, "#{v.key} features run under Wine peaked at #{peak} MB (limit #{@max_private_mb})"} do
          IO.puts("  windows (Wine, Apple GPU) #{v.key}: features OK, peak #{peak} MB resident")
          {:cont, :ok}
        else
          e -> {:halt, e}
        end
      end)
    end
  end

  def step_test_mac(ctx) do
    t = Path.join(ctx.dir, "test")

    with :ok <- File.mkdir_p(t),
         {:ok, _} <- File.copy(girl(ctx), Path.join(t, "three-vrm-girl.vrm")) do
      Enum.reduce_while(@viewers, :ok, fn v, _ ->
        case mac(ctx, mac_test_script(v, Path.join([ctx.dir, "mac", v.key]), t)) do
          {:ok, out} ->
            if String.contains?(out, "MAC-TEST-OK"),
              do: (IO.puts("  macos #{v.key}: #{tail(out)}"); {:cont, :ok}),
              else: {:halt, {:error, "macos #{v.key}: #{tail(out)}"}}

          e ->
            {:halt, e}
        end
      end)
    end
  end

  defp mac_test_script(v, dir, t) do
    """
    set -eu
    T='#{t}'; cd '#{dir}'
    rm -rf mnt app; mkdir mnt app
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$PWD/mnt" #{v.app}-macos-arm64.dmg
    codesign --verify --deep --strict "mnt/#{v.name}.app"
    if grep -q '^SIGNED' signed.txt; then
      spctl -a -t open --context context:primary-signature #{v.app}-macos-arm64.dmg
      xcrun stapler validate -q #{v.app}-macos-arm64.dmg
    fi
    ditto "mnt/#{v.name}.app" "app/#{v.name}.app"; hdiutil detach -quiet mnt
    A="$PWD/app/#{v.name}.app"
    if grep -q '^SIGNED' signed.txt; then spctl -a -t exec "$A"; fi
    open -n -W --stdout "$PWD/features.log" --stderr "$PWD/features.err" "$A" --args -- --features-quit
    grep -q "VIEWER-FEATURES rig=#{v.rig}" features.log || { echo "no VIEWER-FEATURES rig=#{v.rig}"; tail -5 features.log; exit 1; }
    echo "MAC-TEST-OK $(cat signed.txt)"
    """
  end

  # The Linux tar is checked to hold an x86-64 ELF and is reported UNTESTED: it cannot run on this
  # Mac, and the container machine has no display server, so no window can open. A headless or
  # virtual-display run would not be the real-window test, so none is made.
  def step_test_linux(ctx) do
    Enum.reduce_while(@viewers, :ok, fn v, _ ->
      d = Path.join([ctx.dir, "test-linux", v.key])
      exe = Path.join(d, v.app)

      with :ok <- clean(d),
           {:ok, _} <- cap("tar", ["-xf", Path.join([ctx.dir, "pck", v.key, "#{v.app}-linux-x86_64.tar.gz"]), "-C", d]),
           {:ok, bin} <- File.read(exe),
           :ok <- elf_x86_64(bin, "linux #{v.key}"),
           {:error, _} <- elf_x86_64(<<0x7F, "ELF", 2, 1, 1, 0::size(72), 3::little-16, 183::little-16>>, "control"),
           :ok <- File.write(Path.join(d, "UNTESTED.txt"), "linux #{v.key}: x86-64 ELF present, not run (no window can open in a container here)\n") do
        IO.puts("  linux #{v.key}: UNTESTED (x86-64 ELF present; no window can open in a container here)")
        {:cont, :ok}
      else
        :ok -> {:halt, {:error, "linux #{v.key}: the planted non-x86 control PASSED; the gate is broken"}}
        e -> {:halt, e}
      end
    end)
  end

  # e_ident is 16 bytes (magic 4 + 12), then e_type (2), then e_machine (2). The control above feeds an
  # aarch64 header (machine 183): the gate must refuse it, or it checks nothing.
  defp elf_x86_64(<<0x7F, "ELF", _::binary-size(12), _type::little-16, machine::little-16, _::binary>>, what) do
    if machine == @em_x86_64, do: :ok, else: {:error, "#{what}: the program is not x86-64 (e_machine #{machine})"}
  end

  defp elf_x86_64(_, what), do: {:error, "#{what}: the program is not an ELF"}

  # ---- web viewer (the Spaces' godot/ frame) ---------------------------------------------------
  #
  # The web viewer is the same model-explorer source built as godot-sandbox guests (guest/build.py)
  # and exported with the threaded, double-precision, dlink WebGPU template. No release ships that
  # template, so it is built here from entities-godot dev/webgpu-rebase with Emscripten
  # @emsdk_version; the compiler (gdscript_to_riscv) is built from its main. Both live in a cache
  # folder (RELEASE_CACHE) that later runs build on incrementally; their commits go to SOURCES.txt.
  @emsdk_version "6.0.12"
  @web_elfs ~w(skintokens.elf usd.elf headfit.elf persona.elf)

  def step_web(ctx) do
    cache = cache_dir()
    d = Path.expand(Path.join(ctx.dir, "web"))
    env = []

    with :ok <- File.mkdir_p(cache),
         :ok <- clean(d),
         {:ok, tok} <- gh_token("V-Sekai-fire"),
         {:ok, run} <- sandbox_run(ctx),
         {:ok, _} <- cap("gh", ["run", "download", run, "-R", "V-Sekai-fire/godot-sandbox", "-n", "godot-sandbox-web-wasm32-double", "-D", Path.join(d, "sandbox-web")], gh_env(tok)),
         {:ok, log} <- cap("bash", ["-c", web_script(), "web", ctx.root, cache, d, ctx.dir, @emsdk_version, Enum.join(@web_elfs, " ")], env),
         true <- String.contains?(log, "WEB-OK") || {:error, "web build printed no WEB-OK: #{tail(log)}"},
         [_, gsha, csha] <- Regex.run(~r/WEB-OK godot (\w+) compiler (\w+)/, log) || {:error, "no commits in the web log"},
         out = Path.join(d, "out"),
         {:ok, html} <- File.read(Path.join(out, "index.html")),
         {:ok, shell} <- web_shell(html),
         :ok <- File.write(Path.join(out, "index.html"), shell),
         {:ok, bin} <- File.read(Path.join(out, "index.pck")),
         {:ok, files} <- pck_files(bin),
         :ok <- web_pck_check(ctx, files) do
      source(ctx, "web template V-Sekai-fire/entities-godot dev/webgpu-rebase #{gsha} (Emscripten #{@emsdk_version}); compiler V-Sekai-fire/entities-godot-sandbox-gdscript-compiler #{csha}; web sandbox library from Builds run #{run}")
    end
  end

  defp sandbox_run(ctx) do
    with {:ok, s} <- File.read(Path.join(ctx.dir, "SOURCES.txt")),
         [_, run] <- Regex.run(~r/^sandbox V-Sekai-fire\/godot-sandbox Builds run (\d+)/m, s) || {:error, "SOURCES.txt has no sandbox run"} do
      {:ok, run}
    end
  end

  # Each guest ELF in the web pck equals the release's ELF.
  defp web_pck_check(ctx, files) do
    elf = Path.join(ctx.dir, "elf")

    Enum.reduce_while(@web_elfs, :ok, fn f, _ ->
      case {File.read(Path.join(elf, f)), Map.fetch(files, f)} do
        {{:ok, b}, {:ok, b}} -> {:cont, :ok}
        {{:ok, _}, {:ok, _}} -> {:halt, {:error, "#{f} in the web pck differs from its input"}}
        {{:ok, _}, :error} -> {:halt, {:error, "the web pck lacks #{f}"}}
        {e, _} -> {:halt, e}
      end
    end)
  end

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(_, msg), do: {:error, msg}

  defp web_script do
    ~S"""
    set -euo pipefail
    R=$1 C=$2 D=$3 REL=$4 EMV=$5 ELFS=$6
    [ -d "$C/emsdk" ] || git clone -q https://github.com/emscripten-core/emsdk "$C/emsdk"
    (cd "$C/emsdk" && git pull -q && ./emsdk install "$EMV" >/dev/null && ./emsdk activate "$EMV" >/dev/null)
    G=$R/4-entities/godot
    git -C "$G" fetch -q origin dev/webgpu-rebase
    GS=$(git -C "$G" rev-parse FETCH_HEAD)
    [ -d "$C/godot-webgpu" ] || git -C "$G" worktree add -q --detach "$C/godot-webgpu" "$GS"
    git -C "$C/godot-webgpu" checkout -q --detach "$GS"
    set +u; source "$C/emsdk/emsdk_env.sh" >/dev/null 2>&1; set -u
    (cd "$C/godot-webgpu" && ~/.pixi/bin/pixi exec --spec scons==4.11.1 --spec sccache -- \
      scons c_compiler_launcher=sccache cpp_compiler_launcher=sccache platform=web target=template_release \
      webgpu=yes threads=yes precision=double dlink_enabled=yes -j"$(getconf _NPROCESSORS_ONLN)" > "$D/template.log" 2>&1) \
      || { tail -20 "$D/template.log"; exit 1; }
    TPL=$C/godot-webgpu/bin/godot.web.template_release.double.wasm32.dlink.zip
    P=$R/4-entities/godot-sandbox-gdscript-compiler
    git -C "$P" fetch -q origin main
    CS=$(git -C "$P" rev-parse FETCH_HEAD)
    [ -d "$C/compiler" ] || git -C "$P" worktree add -q --detach "$C/compiler" "$CS"
    # ext/ is vendored as subtrees (no submodules to fetch).
    (cd "$C/compiler" && git checkout -q --detach "$CS" \
      && ~/.pixi/bin/pixi run configure > "$D/compiler.log" 2>&1 \
      && ~/.pixi/bin/pixi run cmake --build build --target gdscript_to_riscv >> "$D/compiler.log" 2>&1) \
      || { tail -20 "$D/compiler.log"; exit 1; }
    mkdir -p "$D/addon/bin"
    find "$D/sandbox-web" -name 'libgodot_riscv.web.*double*.wasm' -exec cp {} "$D/addon/bin/" \;
    ls "$D/addon/bin/"libgodot_riscv.web.template_release.double.wasm32.wasm >/dev/null
    E=""; for f in $ELFS; do E="$E $REL/elf/$f"; done
    python3 "$REL/model-explorer/guest/build.py" "$D/work" "$C/compiler/build/src/gdscript/compiler/gdscript_to_riscv" \
      "$D/addon" "$TPL" $E > "$D/guest-build.log" 2>&1 || { grep -E '^BAD|^\{' "$D/guest-build.log" | head; exit 1; }
    tail -1 "$D/guest-build.log"
    GD=$REL/engine/godot.macos.editor.double.arm64
    mkdir -p "$D/out"
    "$GD" --resolution 640x360 --path "$D/work" --import > "$D/import.log" 2>&1 || true
    "$GD" --resolution 640x360 --path "$D/work" --export-release Web "$D/out/index.html" > "$D/export.log" 2>&1 \
      || { tail -20 "$D/export.log"; exit 1; }
    if grep -q "SCRIPT ERROR\|Parse Error" "$D/export.log"; then grep -m5 "SCRIPT ERROR\|Parse Error" "$D/export.log"; exit 1; fi
    for f in index.html index.js index.wasm index.side.wasm index.pck libgodot_riscv.web.template_release.double.wasm32.wasm; do
      [ -s "$D/out/$f" ] || { echo "the export lacks $f"; exit 1; }
    done
    echo "WEB-OK godot $GS compiler $CS"
    """
  end

  # The Space shell: AppSignal in <head> (Space commit as the version), Godot's printed errors and
  # start failures reported once each, and the disclaimer when the frame is opened on its own.
  # The disclaimer's insertAdjacentHTML takes a fixed literal, never page or user input.
  @appsignal_head ~S"""
  <script src="https://cdn.jsdelivr.net/npm/@appsignal/browser@1.0.0-beta.7/dist/browser.umd.js" integrity="sha384-CWzXW1jdvf+NDcpV/CxtCvagiHvI4AddcUZtqCXhn8JUAL4xM9OMpacAnunN2pcl" crossorigin="anonymous"></script>
  <script>
  (function () { var v = "local"; try { var x = new XMLHttpRequest(); x.open("HEAD", location.href.split("#")[0], false); x.send(); v = (x.getResponseHeader("X-Repo-Commit") || v).slice(0, 7); } catch (e) {}
  try { AppsignalBrowser.init({ key: "43d19674-b7e6-4d77-aae1-edf73c7088c3", endpoint: "https://appsignal-endpoint.net", active: true, appVersion: v }); } catch (e) {} })();
  </script>
  """
  @appsignal_print ~S"""
  (function () { var seen = new Set(), msg = null; function flush() { if (msg && !seen.has(msg) && seen.size < 50) { seen.add(msg); try { AppsignalBrowser.captureError(new Error(msg)); } catch (e) {} } msg = null; }
  GODOT_CONFIG.onPrintError = function () { var m = Array.prototype.join.call(arguments, " "); console.error(m);
  if (/^(SCRIPT )?ERROR:/.test(m)) { flush(); msg = m; queueMicrotask(flush); } else if (msg && msg.length < 4000) { msg += "\n" + m; } }; })();
  """
  @appsignal_note ~S"""
  	<script>if (window.top === window) document.body.insertAdjacentHTML("beforeend", '<p id="appsignal-note" style="position:fixed;left:8px;bottom:4px;margin:0;font:10px/1.3 system-ui,sans-serif;color:#888;opacity:.75;z-index:2147483647;pointer-events:none">This page sends error reports and browser data to AppSignal. We use them to find and correct errors.</p>');</script>
  """

  def web_shell(html) do
    fail = "\t\ttry { AppsignalBrowser.captureError(err instanceof Error ? err : new Error(String(err))); } catch (e) {}\n"

    with true <- String.contains?(html, "</title>\n") || {:error, "index.html has no </title>"},
         true <- String.contains?(html, "const engine = new Engine(GODOT_CONFIG);") || {:error, "index.html has no Engine(GODOT_CONFIG)"},
         true <- String.contains?(html, "function displayFailureNotice(err) {\n") || {:error, "index.html has no displayFailureNotice"},
         true <- String.contains?(html, "</body>") || {:error, "index.html has no </body>"},
         false <- String.contains?(html, "AppsignalBrowser") && {:error, "index.html already has AppSignal"} do
      {:ok,
       html
       |> String.replace("</title>\n", "</title>\n" <> @appsignal_head, global: false)
       |> String.replace("const engine = new Engine(GODOT_CONFIG);", @appsignal_print <> "const engine = new Engine(GODOT_CONFIG);", global: false)
       |> String.replace("function displayFailureNotice(err) {\n", "function displayFailureNotice(err) {\n" <> fail, global: false)
       |> String.replace("</body>", @appsignal_note <> "</body>", global: false)}
    end
  end

  # ---- load time (the Meta Quest TRC allows 4 s from open to first useful frame, cold) -------
  #
  # A faux gate for now (operator: "be incremental"): it measures every viewer on every OS and the
  # web viewer, prints PASS or FAIL against @load_limit_ms and writes LOAD.txt, but never stops the
  # run. Desktop: the viewer's --load-time-quit prints LOAD-MS, the time from engine start to the
  # second drawn frame with three-vrm-girl.vrm on screen, with the shader cache emptied first.
  # Web: Chrome with a fresh profile, from navigation start to "BOOT loaded" (sample model shown).
  @load_limit_ms 4000

  def step_test_load(ctx) do
    # A viewer that lacks the flag never quits, so it is not run: the source must carry it.
    gd = Path.join(ctx.dir, "model-explorer/vsk_model_explorer/core/ModelExplorer.gd")
    flag? = match?({:ok, t} when is_binary(t), File.read(gd)) and String.contains?(File.read!(gd), "--load-time-quit")

    rows =
      if flag? do
        Enum.flat_map(@viewers, fn v -> [load_windows(ctx, v), load_mac(ctx, v), load_linux(v)] end) ++
          [load_web(ctx)]
      else
        [{"all viewers", {:error, "#{ctx.ref} predates --load-time-quit, so no viewer was run"}}]
      end

    lines =
      Enum.map(rows, fn
        {what, {:ok, ms}} -> "LOAD #{what} #{ms} ms #{if ms <= @load_limit_ms, do: "PASS", else: "FAIL"} (limit #{@load_limit_ms} ms)"
        {what, {:error, why}} -> "LOAD #{what} no measurement: #{why}"
      end)

    Enum.each(lines, &IO.puts("  " <> &1))
    IO.puts("  (faux gate: a FAIL is reported, the run goes on)")
    File.write(Path.join(ctx.dir, "LOAD.txt"), Enum.join(lines, "\n") <> "\n")
  end

  defp load_ms(text, re) do
    case Regex.run(re, text) do
      [_, ms] -> {:ok, String.to_integer(ms)}
      _ -> {:error, "no load line; last lines: #{tail(text)}"}
    end
  end

  # Under Wine the time includes Wine's own start; it is reported as such.
  defp load_windows(ctx, v) do
    what = "#{v.key} windows (Wine, Apple GPU)"
    d = Path.join([ctx.dir, "test-windows", v.key])
    log = Path.join(d, "load.log")

    for f <- Path.wildcard(Path.join(wine_root(), "prefix/drive_c/users/*/AppData/Roaming/Godot/app_userdata/ModelExplorer/shader_cache")), do: File.rm_rf(f)

    with {:ok, _} <- win_run(Path.join(d, v.app <> ".exe"), ["three-vrm-girl.vrm", "--load-time-quit"], "LOAD-MS", log),
         {:ok, out} <- File.read(log) do
      {what, load_ms(out, ~r/LOAD-MS (\d+)/)}
    else
      {:error, why} -> {what, {:error, why}}
    end
  end

  defp load_mac(ctx, v) do
    what = "#{v.key} macos"
    t = Path.join(ctx.dir, "test")

    script = """
    set -eu
    cd '#{Path.join([ctx.dir, "mac", v.key])}'
    rm -rf "$HOME/Library/Application Support/Godot/app_userdata/ModelExplorer/shader_cache"
    open -n -W --stdout "$PWD/load.log" --stderr "$PWD/load.log" "$PWD/app/#{v.name}.app" --args -- '#{t}/three-vrm-girl.vrm' --load-time-quit
    grep LOAD-MS load.log || tail -5 load.log
    """

    case mac(ctx, script) do
      {:ok, out} -> {what, load_ms(out, ~r/LOAD-MS (\d+)/)}
      {:error, why} -> {what, {:error, why}}
    end
  end

  defp load_linux(v), do: {"#{v.key} linux", {:error, "UNTESTED (see test_linux)"}}

  # The web export is served from this Mac with the Space's headers (COOP/COEP/CORP) and timed in
  # Chrome here.
  defp load_web(ctx) do
    what = "web viewer (Chrome, macOS)"
    out = Path.join([ctx.dir, "web", "out"])
    tool = Path.join(ctx.dir, "model-explorer/tools/web_load_time.mjs")

    script = """
    set -eu
    cd '#{Path.join(ctx.dir, "web")}'
    cat > serve.py <<'PY'
    import functools, http.server, sys
    class H(http.server.SimpleHTTPRequestHandler):
        def end_headers(self):
            for k, v in (("Cross-Origin-Embedder-Policy", "require-corp"), ("Cross-Origin-Opener-Policy", "same-origin"), ("Cross-Origin-Resource-Policy", "cross-origin"), ("Cache-Control", "no-store")):
                self.send_header(k, v)
            super().end_headers()
        def log_message(self, *a):
            pass
    s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=sys.argv[1]))
    print(s.server_address[1], flush=True)
    s.serve_forever()
    PY
    exec 3< <(exec python3 serve.py out)
    read -r PORT <&3
    trap 'pkill -f "serve.py out" || true' EXIT
    node '#{tool}' "http://127.0.0.1:$PORT/index.html" 120
    """

    with true <- File.dir?(out) || {:error, "no web export (the web step has not run)"},
         {:ok, log} <- mac(ctx, script) do
      {what, load_ms(log, ~r/WEB-LOAD-MS (\d+)/)}
    else
      {:error, why} -> {what, {:error, why}}
    end
  end

  # Stage the finished run in ~/release-<id>/<viewer>: the archives, SHA256SUMS (checked here), the
  # notices, the sources, the load times and the .done markers. Nothing is uploaded.
  def step_stage(ctx) do
    dest = Path.join(System.user_home!(), "release-" <> ctx.id)

    Enum.reduce_while(@viewers, :ok, fn v, _ ->
      o = Path.join([ctx.dir, "pck", v.key])
      t = Path.join(dest, v.key)
      keep = archives(v)

      with :ok <- clean(t),
           :ok <- copy_all(keep, o, t),
           {:ok, ver} <- version(ctx, v),
           :ok <- File.write(Path.join(t, "VERSION"), ver <> "\n"),
           :ok <- copy_all(~w(LICENSE.md NOTICE CITATION.cff), Path.join([ctx.dir, "notices", v.key]), t),
           :ok <- copy_all(Enum.filter(~w(SOURCES.txt LOAD.txt), &File.exists?(Path.join(ctx.dir, &1))), ctx.dir, t),
           :ok <- copy_all(Path.wildcard(Path.join(ctx.dir, "test-linux/#{v.key}/UNTESTED.txt")) |> Enum.map(&Path.basename/1), Path.join([ctx.dir, "test-linux", v.key]), t),
           :ok <- (if ctx.skip == [], do: :ok, else: File.write(Path.join(t, "INCOMPLETE.txt"), "skipped by --skip: #{Enum.join(ctx.skip, " ")}\n")),
           {:ok, _} <- File.cp_r(Path.join(ctx.dir, ".done"), Path.join(t, ".done")) |> cp_ok(),
           :ok <- (if v.web, do: stage_web(ctx, t), else: :ok),
           :ok <- stage_checksums(t, archives(v)),
           :ok <- check_sums(t, archives(v)),
           :ok <- control("staged archives", t, archives(v)) do
        IO.puts("  staged #{t}")
        {:cont, :ok}
      else
        e -> {:halt, e}
      end
    end)
  end

  defp cp_ok({:ok, l}), do: {:ok, l}
  defp cp_ok({:error, r, f}), do: {:error, "cannot copy #{f}: #{r}"}

  defp stage_web(ctx, t) do
    src = Path.join([ctx.dir, "web", "out"])
    if File.exists?(Path.join(ctx.dir, ".done/web")) and File.dir?(src), do: (with {:ok, _} <- File.cp_r(src, Path.join(t, "godot")) |> cp_ok(), do: :ok), else: :ok
  end

  defp stage_checksums(t, archives) do
    files = archives |> Enum.join(" ")
    {_, code} = System.cmd("sh", ["-c", "cd \"#{t}\" && shasum -a 256 #{files} > SHA256SUMS"], [])
    if code == 0 do
      :ok
    else
      {:error, "cannot shasum staged archives in #{t} (sh exited #{code})"}
    end
  end

  defp copy_all(names, from, to) do
    Enum.reduce_while(names, :ok, fn f, _ ->
      case File.copy(Path.join(from, f), Path.join(to, f)) do
        {:ok, _} -> {:cont, :ok}
        {:error, r} -> {:halt, {:error, "cannot copy #{Path.join(from, f)}: #{r}"}}
      end
    end)
  end

  # ---- checksum gates, each with its planted failing control ------------------------------------

  # Every file in `files` equals its line in d/SHA256SUMS.
  defp check_sums(d, files) do
    with {:ok, sums} <- File.read(Path.join(d, "SHA256SUMS")) do
      Enum.reduce_while(files, :ok, fn f, _ ->
        with want when is_binary(want) <- sum_for(sums, f) || {:error, "#{d}/SHA256SUMS lacks #{f}"},
             {:ok, got} <- sha256(Path.join(d, f)),
             true <- got == want || {:error, "#{f} does not match #{d}/SHA256SUMS"} do
          {:cont, :ok}
        else
          e -> {:halt, e}
        end
      end)
    end
  end

  # A check that cannot fail proves nothing: flip one byte of the smallest file in a copy, and the
  # same check must refuse the copy.
  defp control(name, d, files) do
    t = Path.join(d, ".control")
    {small, _} = files |> Enum.map(&{&1, File.stat!(Path.join(d, &1)).size}) |> Enum.min_by(&elem(&1, 1))

    with :ok <- clean(t),
         {:ok, _} <- File.copy(Path.join(d, "SHA256SUMS"), Path.join(t, "SHA256SUMS")),
         {:ok, <<first, rest::binary>>} <- File.read(Path.join(d, small)),
         :ok <- File.write(Path.join(t, small), <<Bitwise.bxor(first, 0xFF), rest::binary>>) do
      result = check_sums(t, [small])
      File.rm_rf(t)

      case result do
        {:error, _} -> IO.puts("  control #{name}: a corrupted #{small} failed the check, as planned"); :ok
        :ok -> {:error, "control #{name}: a corrupted #{small} PASSED the check; the gate is broken"}
      end
    end
  end

  defp write_sums(d, files) do
    Enum.reduce_while(files, {:ok, []}, fn f, {:ok, acc} ->
      case sha256(Path.join(d, f)) do
        {:ok, h} -> {:cont, {:ok, ["#{h}  #{f}\n" | acc]}}
        e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, lines} -> File.write(Path.join(d, "SHA256SUMS"), Enum.reverse(lines))
      e -> e
    end
  end

  def step_publish(%{publish: "none"}), do: (IO.puts("  --publish none: nothing uploaded"); :ok)

  def step_publish(ctx) do
    # The gate comes from interactor-skintokens-qlora main as fetched now, not from whatever commit
    # the client's checkout sits on (an old checkout has no REVISION and would publish to main).
    q = Path.join(ctx.root, "3-interactor/skintokens-qlora")
    gd = Path.join(ctx.dir, "gate")
    gate = Path.join(gd, "tools/space_gate.py")

    with {:ok, _} <- cap("git", ["-C", q, "fetch", "-q", "origin", "main"]),
         :ok <- clean(gd),
         {:ok, _} <- cap("sh", ["-c", "git -C \"$1\" archive FETCH_HEAD tools | tar -x -C \"$2\"", "sh", q, gd]),
         {:ok, g} <- File.read(gate),
         gate_abs = Path.expand(gate),
         true <- ctx.publish == "main" or String.contains?(g, "REVISION") ||
                   {:error, "#{gate} cannot commit to a branch (no REVISION): update the checkout"},
         {:ok, tok} <- hf_token() do
      Enum.filter(@viewers, &(ctx.only == [] or &1.key in ctx.only))
      |> Enum.reduce_while(:ok, fn v, _ ->
        o = Path.join([ctx.dir, "pck", v.key])
        files = archives(v) ++ ~w(SHA256SUMS LICENSE.md NOTICE CITATION.cff VERSION)

        with {:ok, ver} <- version(ctx, v),
             :ok <- File.write(Path.join(o, "VERSION"), ver <> "\n"),
             :ok <- Enum.reduce_while(~w(LICENSE.md NOTICE CITATION.cff), :ok, fn f, _ ->
               case File.copy(Path.join([ctx.dir, "notices", v.key, f]), Path.join(o, f)) do
                 {:ok, _} -> {:cont, :ok}
                 e -> {:halt, e}
               end
             end),
             env = [{"HF_UPLOAD_TOKEN", tok}, {"REVISION", if(ctx.publish == "main", do: "", else: ctx.publish)},
                    {"MSG", "Release #{ver}"}],
             {:ok, out} <- cap("sh", ["-c", "printf '%s' \"$HF_UPLOAD_TOKEN\" | python \"$@\"", "sh", gate, "push", v.repo, "model", o | files], env),
             true <- String.contains?(out, "live matches") || {:error, "#{v.repo}: #{tail(out)}"},
             :ok <- (if ctx.publish == "main", do: space_update(ctx, v, o, gate_abs, tok, ver), else: :ok),
             :ok <- tag(ctx, v, ver, tok) do
          IO.puts("  #{v.repo}: #{out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, "commit"))}")
          {:cont, :ok}
        else
          e -> {:halt, e}
        end
      end)
    end
  end

  # ---- helpers -------------------------------------------------------------------------------

  # The tag is the Go pseudo-version of the model-explorer HEAD commit (RFD66606-2312, gate
  # check_release_tags.exs): v0.0.0-YYYYMMDDHHMMSS-<12-hex> (UTC commit time + first 12 hex
  # of the SHA); CalVer is rejected after the 2026-10-13 cutover. The download repo and the
  # Space kicker still carry the human CalVer version, which stays separate from the tag.
  defp tag(ctx, v, _ver, hf_tok) do
    rev = if ctx.publish == "main", do: "main", else: ctx.publish
    dir = Path.join(ctx.dir, "model-explorer")
    py = "import sys,huggingface_hub as h; a=h.HfApi(token=sys.stdin.read().strip()); " <>
         "t=[x.name for x in a.list_repo_refs(sys.argv[1]).tags]; " <>
         "sys.argv[2] in t or a.create_tag(sys.argv[1], tag=sys.argv[2], revision=sys.argv[3], tag_message='Release '+sys.argv[2]); print('HF-TAG-OK')"

    with {:ok, sha} <- cap("git", ["-C", dir, "rev-parse", "HEAD"]),
         sha = String.trim(sha),
         {:ok, utc} <- cap("git", ["-C", dir, "log", "-1", "--format=%cd",
            "--date=format-local:%Y%m%d%H%M%S", "HEAD"], [{"TZ", "UTC"}]),
         utc = String.trim(utc),
         pver = "v0.0.0-#{utc}-#{String.slice(sha, 0, 12)}",
         {:ok, gh} <- gh_token("V-Sekai-fire"),
         :ok <- gh_tag(gh, pver, sha),
         {:ok, out} <- cap("sh", ["-c", "printf '%s' \"$HF_TAG_TOKEN\" | python -c \"$1\" \"$2\" \"$3\" \"$4\"", "sh", py, v.repo, pver, rev], [{"HF_TAG_TOKEN", hf_tok}]),
         true <- String.contains?(out, "HF-TAG-OK") || {:error, "#{v.repo}: no tag #{pver}: #{tail(out)}"} do
      IO.puts("  tag #{pver}: entities-model-explorer #{String.slice(sha, 0, 7)}, #{v.repo} #{rev}")
      :ok
    end
  end

  # An existing tag on the same commit is fine (two viewers share one tag); on another commit it fails.
  defp gh_tag(gh, ver, sha) do
    repo = "repos/V-Sekai-fire/entities-model-explorer/git"

    case cap("gh", ["api", "#{repo}/ref/tags/#{ver}", "--jq", ".object.sha"], gh_env(gh)) do
      {:ok, have} ->
        if String.trim(have) == sha, do: :ok, else: {:error, "tag #{ver} already names #{String.trim(have)}, not #{sha}"}

      {:error, _} ->
        with {:ok, _} <- cap("gh", ["api", "#{repo}/refs", "-f", "ref=refs/tags/#{ver}", "-f", "sha=#{sha}"], gh_env(gh)), do: :ok
    end
  end

  defp version_re, do: ~r/\bv(\d{8}|\d+\.\d+\.\d+)(-(dev|beta|rc)\.\d+)?\b/

  defp version(ctx, v) do
    f = Path.join([ctx.dir, "version", v.key])

    case File.read(f) do
      {:ok, s} ->
        {:ok, String.trim(s)}

      _ ->
        with {:ok, tok} <- hf_token(),
             {:ok, cur} <- published_version(ctx, tok, v),
             {:ok, next} <- next_version(cur),
             :ok <- File.mkdir_p(Path.dirname(f)),
             :ok <- File.write(f, next <> "\n") do
          IO.puts("  #{v.key}: published #{cur}, this release #{next}")
          {:ok, next}
        end
    end
  end

  # VERSION in the download repo wins; a repo without one falls back to the Space page's version.
  defp published_version(ctx, tok, v) do
    d = Path.join([ctx.dir, "version", "published-" <> v.key])

    with :ok <- clean(d) do
      from_repo =
        with {:ok, p} <- hf_get(tok, v.repo, "VERSION", Path.join(d, "VERSION")),
             {:ok, s} <- File.read(p),
             [m | _] <- Regex.run(version_re(), s) do
          m
        else
          _ -> nil
        end

      from_space =
        with {:ok, p} <- hf_get(tok, "spaces/" <> v.space, "index.html", Path.join(d, "index.html")),
             {:ok, s} <- File.read(p),
             [m | _] <- Regex.run(version_re(), s) do
          m
        else
          _ -> nil
        end

      case from_repo || from_space do
        nil -> {:error, "#{v.key}: no published version in #{v.repo}/VERSION or on #{v.space}; publish one by hand first"}
        m -> {:ok, m}
      end
    end
  end

  # Today's date with the stage kept and N raised by one; after a bare tag the next is dev.1.
  defp next_version(cur) do
    day = Calendar.strftime(NaiveDateTime.local_now(), "%Y%m%d")

    case Regex.run(~r/^v(?:\d{8}|\d+\.\d+\.\d+)(?:-(dev|beta|rc)\.(\d+))?$/, cur) do
      [_, stage, n] -> {:ok, "v#{day}-#{stage}.#{String.to_integer(n) + 1}"}
      [_] -> {:ok, "v#{day}-dev.1"}
      _ -> {:error, "cannot read the tag #{inspect(cur)}"}
    end
  end

  # macOS wants dotted numbers: v20261026-dev.2 is 2026.10.26.
  defp short_version(ver) do
    case Regex.run(~r/^v(\d{4})(\d{2})(\d{2})/, ver) do
      [_, y, m, d] -> "#{y}.#{String.to_integer(m)}.#{String.to_integer(d)}"
      _ -> ver |> String.trim_leading("v") |> String.split("-") |> hd()
    end
  end

  # Publishing to main also brings the viewer's Spaces up to date: each download card on the
  # desktop Space's index.html gets the new SHA-256 and size, and a viewer with `web: true` gets
  # this release's web viewer as godot/ on its own `web_space` (operator: the WebGPU build never
  # sits on the Space with the desktop downloads). Dev publishes leave the Spaces alone.
  defp space_update(ctx, v, o, gate, tok, ver) do
    sd = Path.join([ctx.dir, "space", v.key])
    web = Path.join([ctx.dir, "web", "out"])

    with :ok <- clean(sd),
         {:ok, _} <- hf_get(tok, "spaces/" <> v.space, "index.html", Path.join(sd, "index.html")),
         {:ok, html} <- File.read(Path.join(sd, "index.html")),
         {:ok, html} <- cards(html, o, archives(v)),
         html = String.replace(html, version_re(), ver),
         :ok <- File.write(Path.join(sd, "index.html"), html),
         :ok <- space_push(sd, gate, tok, %{ctx | id: ver}, v.space, ["index.html"]),
         :ok <- (if v.web, do: web_update(ctx, v, web, gate, tok), else: :ok) do
      :ok
    end
  end

  defp web_update(ctx, v, web, gate, tok) do
    wd = Path.join([ctx.dir, "space", v.key <> "-web"])

    with true <- is_binary(Map.get(v, :web_space)) || {:error, "#{v.key}: web: true needs a web_space"},
         true <- v.web_space != v.space || {:error, "#{v.key}: web_space must not be the desktop Space"},
         :ok <- clean(wd),
         {:ok, godot} <- copy_web(web, Path.join(wd, "godot")) do
      space_push(wd, gate, tok, ctx, v.web_space, godot)
    end
  end

  defp space_push(dir, gate, tok, ctx, space, files) do
    # ctx.id is the version on a Space update and the run id elsewhere.
    env = [{"HF_UPLOAD_TOKEN", tok}, {"REVISION", ""}, {"MSG", "Release #{ctx.id}"}]

    with {:ok, out} <- cap("sh", ["-c", "cd \"$1\" && shift && printf '%s' \"$HF_UPLOAD_TOKEN\" | python \"$@\"", "sh", dir, gate, "push", space, "space", "." | files], env),
         true <- String.contains?(out, "live matches") || {:error, "Space #{space}: #{tail(out)}"} do
      IO.puts("  Space #{space}: #{length(files)} file(s)")
      :ok
    end
  end

  # One card per archive: the card that links resolve/main/<archive> holds its size label and hash.
  defp cards(html, o, files) do
    [head | rest] = String.split(html, ~s(<div class="card">))

    Enum.reduce_while(files, {:ok, rest}, fn f, {:ok, cs} ->
      case Enum.find_index(cs, &String.contains?(&1, "/resolve/main/#{f}")) do
        nil ->
          {:cont, {:ok, cs}}

        i ->
          with {:ok, h} <- sha256(Path.join(o, f)),
               {:ok, %{size: n}} <- File.stat(Path.join(o, f)) do
            c = cs |> Enum.at(i)
                |> String.replace(~r/SHA-256 [0-9a-f]{64}/, "SHA-256 " <> h, global: false)
                |> String.replace(~r/\d+(\.\d)? [MG]B/, size_label(n), global: false)
            {:cont, {:ok, List.replace_at(cs, i, c)}}
          else
            e -> {:halt, e}
          end
      end
    end)
    |> case do
      {:ok, cs} -> {:ok, Enum.join([head | cs], ~s(<div class="card">))}
      e -> e
    end
  end

  defp size_label(n) when n >= 1_000_000_000, do: :erlang.float_to_binary(n / 1.0e9, decimals: 1) <> " GB"
  defp size_label(n), do: "#{round(n / 1.0e6)} MB"

  defp copy_web(web, dst) do
    files = ~w(index.html index.js index.wasm index.side.wasm index.pck index.png index.audio.worklet.js
               index.audio.position.worklet.js libgodot_riscv.web.template_release.double.wasm32.wasm)

    with :ok <- File.mkdir_p(dst) do
      Enum.reduce_while(files, {:ok, []}, fn f, {:ok, acc} ->
        case File.cp(Path.join(web, f), Path.join(dst, f)) do
          :ok -> {:cont, {:ok, acc ++ ["godot/" <> f]}}
          {:error, r} -> {:halt, {:error, "web export lacks #{f}: #{r}"}}
        end
      end)
    end
  end

  # Godot pck (format 3 or 4, unencrypted): %{path => bytes}.
  def pck_files(<<0x43504447::little-32, version::little-32, _::binary-12, flags::little-32,
                  file_base::little-64, dir::little-64, _::binary>> = bin)
      when version in [3, 4] and Bitwise.band(flags, 1) == 0 do
    case bin do
      <<_::binary-size(^dir), count::little-32, entries::binary>> -> read_entries(entries, count, file_base, bin, %{})
      _ -> {:error, "pck directory offset is past the end"}
    end
  end

  def pck_files(_), do: {:error, "not an unencrypted Godot pck (format 3 or 4)"}

  defp read_entries(_, 0, _, _, acc), do: {:ok, acc}

  defp read_entries(<<len::little-32, path::binary-size(len), ofs::little-64, size::little-64,
                      _md5::binary-16, _flags::little-32, rest::binary>>, n, base, bin, acc) do
    name = path |> String.trim_trailing(<<0>>) |> String.replace_prefix("res://", "")

    if base + ofs + size <= byte_size(bin),
      do: read_entries(rest, n - 1, base, bin, Map.put(acc, name, binary_part(bin, base + ofs, size))),
      else: {:error, "pck entry #{name} is past the end"}
  end

  defp read_entries(_, _, _, _, _), do: {:error, "truncated pck directory"}

  # Prefers tools/package_desktop.exs (the Elixir port); falls back to tools/package_desktop.sh
  # for an older --ref checked out from before the port, so a historical release still builds.
  defp pkg_script(src) do
    exs = Path.join(src, "tools/package_desktop.exs")
    sh = Path.join(src, "tools/package_desktop.sh")

    cond do
      File.exists?(exs) -> {:ok, {"elixir", exs}}
      File.exists?(sh) -> {:ok, {"sh", sh}}
      true -> {:error, "no tools/package_desktop.exs or .sh in #{src}"}
    end
  end

  defp cap(cmd, args, env \\ [], cd \\ nil) do
    case System.find_executable(cmd) do
      nil ->
        {:error, "#{cmd} is not on PATH"}

      exe ->
        opts = [env: env, stderr_to_stdout: true] ++ if(cd, do: [cd: cd], else: [])

        case System.cmd(exe, args, opts) do
          {out, 0} -> {:ok, out}
          {out, code} -> {:error, "#{cmd} #{Enum.take(args, 3) |> Enum.join(" ")} exited #{code}: #{tail(out)}"}
        end
    end
  end

  # A shell script run here, on the Mac.
  defp mac(ctx, script) do
    f = Path.join(ctx.dir, "step-#{System.unique_integer([:positive])}.sh")

    with :ok <- File.write(f, script) do
      r = cap("bash", [f])
      File.rm(f)
      r
    end
  end

  defp tail(s), do: s |> String.split("\n", trim: true) |> Enum.take(-6) |> Enum.join(" | ")

  defp decode(json) do
    case :json.decode(json) do
      v -> {:ok, v}
    end
  rescue
    _ -> {:error, "not JSON: #{String.slice(json, 0, 120)}"}
  end

  defp green_run(tok, repo, workflow, branch \\ "main") do
    with {:ok, json} <- cap("gh", ["run", "list", "-R", repo, "--branch", branch, "--workflow", workflow, "--status", "success",
                                   "-L", "1", "--json", "databaseId,headSha"], gh_env(tok)),
         {:ok, [%{"databaseId" => id, "headSha" => sha}]} <- decode(json) do
      {:ok, Integer.to_string(id), sha}
    else
      {:ok, []} -> {:error, "no green #{workflow} run on #{repo} #{branch}"}
      e -> e
    end
  end

  defp gh_token(org) do
    helper = System.find_executable("bao-mint-github") || Path.expand("~/.local/bin/bao-mint-github")

    # bao-mint-github prints one line per OpenBao host it tried ({:error, ...} for one that is
    # down) before the token, so take the word that is a GitHub token, not the first word.
    with true <- File.exists?(helper) || {:error, "no bao-mint-github on this machine"},
         {out, 0} <- System.cmd("sh", ["-c", "\"$0\" \"$1\" 2>/dev/null", helper, org]),
         tok when is_binary(tok) <- out |> String.split() |> Enum.find(&String.match?(&1, ~r/^gh[sopu]_/)) do
      {:ok, tok}
    else
      {:error, _} = e -> e
      _ -> {:error, "bao-mint-github #{org} gave no token"}
    end
  end

  defp gh_env(tok), do: [{"GH_TOKEN", tok}]

  defp hf_token do
    case System.find_executable("bao-hf-token") do
      nil ->
        sh = ~S|eval "$(bao-env)" >/dev/null 2>&1; bao kv get -field=token -mount=secret "agents-own/$BAO_CN/huggingface-token"|

        case System.cmd("sh", ["-c", sh]) do
          {out, 0} -> {:ok, String.trim(out)}
          _ -> {:error, "no Hugging Face token from OpenBao (bao-env)"}
        end

      helper ->
        case System.cmd(helper, []) do
          {out, 0} -> {:ok, String.trim(out)}
          _ -> {:error, "bao-hf-token gave no token"}
        end
    end
  end

  defp hf_get(tok, repo, file, out) do
    sh = ~s(curl -fsSL -H "Authorization: Bearer $HF_GET_TOKEN" -o "$2" "https://huggingface.co/$1/resolve/main/$3")

    with {:ok, _} <- cap("sh", ["-c", sh, "sh", repo, out, file], [{"HF_GET_TOKEN", tok}]) do
      if String.ends_with?(file, "SHA256SUMS"), do: File.read(out), else: {:ok, out}
    end
  end

  defp sum_for(sums, f) do
    sums |> String.split("\n") |> Enum.find_value(fn l ->
      case String.split(l) do
        [h, ^f] -> h
        [h, "*" <> ^f] -> h
        _ -> nil
      end
    end)
  end

  defp sha256(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        h = IO.binstream(io, 8 * 1024 * 1024) |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        File.close(io)
        {:ok, hex(:crypto.hash_final(h))}

      e ->
        e
    end
  end

  defp hex(b), do: Base.encode16(b, case: :lower)

  defp chmod_x(p) do
    case File.chmod(p, 0o755) do
      :ok -> {:cont, :ok}
      e -> {:halt, e}
    end
  end

  defp clean(d) do
    case File.rm_rf(d) do
      {:ok, _} -> File.mkdir_p(d)
      {:error, r, f} -> {:error, "cannot remove #{f}: #{r}"}
    end
  end

  defp need(d, names) do
    case Enum.reject(names, &File.exists?(Path.join(d, &1))) do
      [] -> :ok
      miss -> {:error, "missing in #{d}: #{Enum.join(miss, " ")}"}
    end
  end

  # gh run download keeps each artifact in its own folder; the libraries go beside each other
  # (a .framework is a folder: move it whole, never the files inside it).
  defp flatten_libs(d) do
    Path.wildcard(Path.join(d, "*/**/libgodot_riscv.*"))
    |> Enum.reject(&(Path.relative_to(&1, d) |> Path.dirname() |> String.contains?(".framework")))
    |> Enum.reduce_while(:ok, fn p, _ ->
      case File.rename(p, Path.join(d, Path.basename(p))) do
        :ok -> {:cont, :ok}
        e -> {:halt, e}
      end
    end)
  end

  defp source(ctx, line) do
    IO.puts("  " <> line)
    File.write(Path.join(ctx.dir, "SOURCES.txt"), line <> "\n", [:append])
  end
end

System.halt(Release.main(System.argv()))
