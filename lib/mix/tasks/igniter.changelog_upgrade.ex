if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Igniter.ChangelogUpgrade.Changelogs do
    defstruct [:mix_dep, :changelog_before, :changelog_after]

    @type t :: %__MODULE__{
            mix_dep: %Mix.Dep{},
            changelog_before: String.t(),
            changelog_after: String.t()
          }
  end

  defmodule Mix.Tasks.Igniter.ChangelogUpgrade do
    use Igniter.Mix.Task
    alias Mix.Tasks.Igniter.ChangelogUpgrade.Changelogs

    @example "mix igniter.changelog_upgrade package1 package2@1.2.1"

    @shortdoc "Fetch and upgrade dependencies, generate deps CHANGELOG summary. A drop in replacement for `mix deps.update` that also runs upgrade tasks."
    @moduledoc """
    #{@shortdoc}

    Updates dependencies via `mix deps.update` and then runs any upgrade tasks for any changed dependencies.

    By default, this task updates to the latest versions allowed by the `mix.exs` file, just like `mix deps.update`.

    To upgrade a package to a specific version, you can specify the version after the package name,
    separated by an `@` symbol. This allows upgrading beyond what your mix.exs file currently specifies,
    i.e if you have `~> 1.0` in your mix.exs file, you can use `mix igniter.upgrade package@2.0` to
    upgrade to version 2.0, which will update your `mix.exs` and run any equivalent upgraders.

    ## Limitations

    The new version of the package must be "compile compatible" with your existing code. See the upgrades guide for more.

    ## Example

    ```bash
    #{@example}
    ```

    ## Options

    * `--yes` or `-y` - Accept all changes automatically
    * `--all` or `-a` - Upgrades all dependencies
    * `--only` or `-o` - only fetches dependencies for given environment
    * `--target` or `-t` - only fetches dependencies for given target
    * `--no-archives-check` or `-n` - does not check archives before fetching deps
    * `--git-ci` or `-g` - Uses git history (HEAD~1) to check the previous versions in the lock file.
      See the upgrade guides for more. Sets --yes automatically.
    """

    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :igniter,
        example: @example,
        positional: [
          packages: [rest: true, optional: true]
        ],
        schema: [
          yes: :boolean,
          all: :boolean,
          only: :string,
          target: :string,
          no_archives_check: :boolean,
          git_ci: :boolean
        ],
        aliases: [y: :yes, a: :all, o: :only, t: :target, n: :no_archives_check, g: :git_ci],
        defaults: [yes: false]
      }
    end

    def igniter(igniter) do
      packages = igniter.args.positional.packages
      options = igniter.args.options

      options =
        if options[:git_ci] do
          Keyword.put(options, :yes, true)
        else
          options
        end

      packages =
        packages
        |> Enum.join(",")
        |> String.split(",")

      if Enum.empty?(packages) && !options[:all] do
        Mix.shell().error("""
        Must specify at least one package to upgrade or use --all to upgrade all packages.
        """)

        exit({:shutdown, 1})
      end

      if options[:only] && !Enum.empty?(packages) do
        Mix.shell().error("""
        Cannot specify both --only and package names.
        """)

        exit({:shutdown, 1})
      end

      if options[:target] && !Enum.empty?(packages) do
        Mix.shell().error("""
        Cannot specify both --target and package names.
        """)

        exit({:shutdown, 1})
      end

      original_deps_info =
        if options[:git_ci] do
          System.cmd("git", ["show", "HEAD~1:mix.lock"])
          |> elem(0)
          |> Code.format_string!()
          |> IO.iodata_to_binary()
          |> Code.eval_string()
          |> elem(0)
          |> Enum.flat_map(fn {key, config} ->
            with {_, _, version, _, _, _, _, _} <- config,
                 {:ok, _version} <- Version.parse(version) do
              [%{app: key, status: {:ok, version}}]
            else
              _ ->
                []
            end
          end)
        else
          Mix.Dep.cached()
          |> expand_deps()
          |> Enum.filter(&match?({:ok, v} when is_binary(v), &1.status))
        end

      Mix.Task.run("compile")

      igniter =
        igniter
        |> Igniter.include_existing_file("mix.exs")
        |> Igniter.include_existing_file("mix.lock")

      original_mix_exs = Rewrite.Source.get(Rewrite.source!(igniter.rewrite, "mix.exs"), :content)

      original_mix_lock =
        Rewrite.Source.get(Rewrite.source!(igniter.rewrite, "mix.lock"), :content)

      validate_packages!(packages)

      package_names =
        packages
        |> Enum.map(&(String.split(&1, "@") |> List.first()))
        |> Enum.map(&String.to_atom/1)

      changelogs = cl_before_update(original_deps_info)
      update_deps_args = update_deps_args(options)

      igniter =
        if options[:git_ci] do
          igniter
        else
          packages
          |> Enum.reduce(igniter, &replace_dep(&2, &1))
          |> Igniter.apply_and_fetch_dependencies(
            error_on_abort?: true,
            yes: options[:yes],
            update_deps: Enum.map(package_names, &to_string/1),
            update_deps_args: update_deps_args,
            force?: true
          )
        end

      try do
        new_deps_info =
          Mix.Dep.load_and_cache()
          |> expand_deps()
          |> then(fn deps ->
            if options[:git_ci] do
              deps
            else
              Enum.map(deps, fn dep ->
                status =
                  Mix.Dep.in_dependency(dep, fn _ ->
                    if File.exists?("mix.exs") do
                      Mix.Project.pop()
                      Installer.Lib.Private.SharedUtils.reevaluate_mix_exs()

                      {:ok, Mix.Project.get!().project()[:version]}
                    else
                      dep.status
                    end
                  end)

                %{dep | status: status}
              end)
            end
          end)
          |> Enum.filter(&match?({:ok, v} when is_binary(v), &1.status))

        Mix.Task.reenable("compile")
        Mix.Task.reenable("loadpaths")
        Mix.Task.run("compile")
        Mix.Task.reenable("compile")

        dep_changes =
          dep_changes_in_order(original_deps_info, new_deps_info)

        cl_after_update(changelogs, dep_changes)

        if !options[:git_ci] &&
             Enum.any?(dep_changes, fn {app, _, _} ->
               app in [:igniter, :glob_ex, :rewrite, :sourceror, :spitfire]
             end) do
          Process.put(:no_recover_mix_exs, true)

          upgrades =
            Enum.map_join(dep_changes, " ", fn {app, from, to} ->
              "#{app}:#{from}:#{to}"
            end)

          Mix.raise("""
          Cannot upgrade igniter or its dependencies with `mix igniter.upgrade` in one command.

          The dependency changes have been saved.

          To complete the upgrade, run the following command:

              mix igniter.apply_upgrades #{upgrades}
          """)
        end

        Enum.reduce(dep_changes, {igniter, []}, fn update, {igniter, missing} ->
          case apply_updates(igniter, update) do
            {:ok, igniter} ->
              {igniter, missing}

            {:missing, missing_package} ->
              {igniter, [missing_package | missing]}
          end
        end)
        |> case do
          {igniter, []} ->
            igniter

          {igniter, missing} ->
            Igniter.add_notice(
              igniter,
              "The packages `#{Enum.join(missing, ", ")}` did not have upgrade tasks."
            )
        end
      rescue
        e ->
          if !options[:git_ci] && !Process.get(:no_recover_mix_exs) do
            recover_mix_exs_and_lock(
              igniter,
              original_mix_exs,
              original_mix_lock,
              Exception.format(:error, e, __STACKTRACE__),
              options
            )
          end

          reraise e, __STACKTRACE__
      catch
        :exit, reason ->
          if !options[:git_ci] && !Process.get(:no_recover_mix_exs) do
            recover_mix_exs_and_lock(
              igniter,
              original_mix_exs,
              original_mix_lock,
              "exit: " <> inspect(reason),
              options
            )
          end

          exit(reason)
      end
    end

    def cl_before_update(original_deps_info) do
      Enum.filter(original_deps_info, & &1.top_level)
      |> Enum.map(fn dep ->
        changelog_before = cl_read_changelog2(dep)

        %Changelogs{
          mix_dep: dep,
          changelog_before: changelog_before
        }
      end)
    end

    def cl_after_update(changelogs, dep_changes, timestamp \\ nil) do
      timestamp = timestamp || :calendar.local_time()

      # dep_changes #=> [
      #   {:money, %Version{major: 1, minor: 12, patch: 3}, %Version{major: 1, minor: 12, patch: 4}}
      # ]

      process_deps =
        Enum.flat_map(changelogs, fn dep ->
          if List.keyfind(dep_changes, dep.mix_dep.app, 0) do
            [%{dep | changelog_after: cl_read_changelog2(dep.mix_dep)}]
          else
            []
          end
        end)

      summary_text =
        Enum.reduce(process_deps, "", fn dep, acc ->
          package_name = dep.mix_dep.app
          {_name, old_version, new_version} = List.keyfind(dep_changes, package_name, 0)

          diff =
            List.myers_difference(
              (dep.changelog_before || "") |> String.split("\n"),
              (dep.changelog_after || "") |> String.split("\n")
            )

          # Gather all inserted blocks and perform some mutations
          insert_text =
            Enum.filter(diff, fn {op, _} -> op == :ins end)
            |> Enum.flat_map(&elem(&1, 1))
            |> cl_limit_vertical_whitespace(2)
            |> cl_shift_md_headings(2)
            |> Enum.join("\n")

          acc <>
            String.trim_trailing("""
            ### `#{package_name}` (#{old_version} ➞ #{new_version})

            #{insert_text}
            """) <> "\n\n\n"
        end)
        |> String.trim_trailing()

      if summary_text != "", do: cl_update_summary_file(summary_text, timestamp)
    end

    defp cl_read_changelog(dep) do
      dest_path = dep.opts.dest

      read_changelog =
        File.read("#{dest_path}/CHANGELOG.md")
        |> case do
          {:error, _reason} -> File.read("#{dest_path}/CHANGELOG")
          {:ok, _contents} = result -> result
        end

      case read_changelog do
        {:ok, changelog_body} -> changelog_body
        {:error, _reason} -> nil
      end
    end

    defp cl_read_changelog2(dep) do
      dest_path = dep.opts[:dest]

      cond do
        (
          r = File.read("#{dest_path}/CHANGELOG.md")
          match?({:ok, _}, r)
        ) ->
          elem(r, 1)

        (
          r = File.read("#{dest_path}/CHANGELOG")
          match?({:ok, _}, r)
        ) ->
          elem(r, 1)

        true ->
          nil
      end
    end

    defp cl_read_changelogs(package_names) do
      Enum.reduce(package_names, [], fn package_name, acc ->
        read_changelog =
          File.read("deps/#{package_name}/CHANGELOG.md")
          |> case do
            {:error, _reason} -> File.read("deps/#{package_name}/CHANGELOG")
            {:ok, _contents} = result -> result
          end

        case read_changelog do
          {:ok, changelog_body} -> Keyword.put(acc, package_name, changelog_body)
          {:error, _reason} -> acc
        end
      end)
    end

    defp cl_update_summary_file(summary_text, timestamp) do
      marker = "<!-- changelog -->"

      default_header = """
      # Dependencies Change Log

      Auto-updated by `deps_changelog`. 💪

      Feel free to edit this file by hand. Updates will be inserted below the following marker:

      #{marker}
      """

      months =
        ~w(January February March April May June July August September October November December)

      {{year, month, day}, _time} = timestamp
      local_date = "#{day}. #{Enum.at(months, month - 1)} #{year}"
      date_header = cl_underlined_md_heading("_#{local_date}_", 2) <> "\n\n"

      updated_summary =
        case File.read("deps.CHANGELOG.md") do
          {:ok, content} ->
            String.replace(
              content,
              marker,
              marker <> "\n\n" <> date_header <> summary_text <> "\n\n"
            )

          _ ->
            default_header <> "\n" <> date_header <> summary_text <> "\n"
        end

      case File.write("deps.CHANGELOG.md", updated_summary) do
        :ok ->
          :ok

        {:error, reason} ->
          Mix.shell().error("Failed to write deps.CHANGELOG.md: #{inspect(reason)}")
      end
    end

    defp cl_underlined_md_heading(text, level) do
      symbol =
        case level do
          1 -> "="
          2 -> "-"
          _ -> raise "Unsupported heading level: #{level}"
        end

      underlines = String.duplicate(symbol, String.length(text))
      "#{text}\n#{underlines}"
    end

    defp cl_shift_md_headings(lines, shift) do
      Enum.map(lines, fn line ->
        case Regex.run(~r/^(#+) /, line) do
          [_, old_prefix] ->
            new_level = min(6, String.length(old_prefix) + shift)
            new_prefix = String.duplicate("#", new_level)
            String.replace_prefix(line, old_prefix, new_prefix)

          _ ->
            line
        end
      end)
    end

    defp cl_limit_vertical_whitespace(lines, max) do
      # Limit the number of consecutive empty strings to `max`.
      # Strips trailing whitespace.
      Enum.reduce(lines, {0, []}, fn line, {empty_count, acc} ->
        if String.trim(line) == "" do
          {empty_count + 1, acc}
        else
          {0, acc ++ Enum.take(List.duplicate("", empty_count), max) ++ [line]}
        end
      end)
      |> elem(1)
    end

    defp update_deps_args(options) do
      update_deps_args =
        if only = options[:only] do
          ["--only", only]
        else
          []
        end

      update_deps_args =
        if target = options[:target] do
          ["--target", target] ++ update_deps_args
        else
          update_deps_args
        end

      update_deps_args =
        if options[:no_archives_check] do
          ["--no-archives-check"] ++ update_deps_args
        else
          update_deps_args
        end

      if options[:all] do
        ["--all"] ++ update_deps_args
      else
        update_deps_args
      end
    end

    defp apply_updates(igniter, {package, from, to}) do
      task =
        if package == :igniter do
          "igniter.upgrade_igniter"
        else
          "#{package}.upgrade"
        end

      with task when not is_nil(task) <- Mix.Task.get(task),
           true <- function_exported?(task, :info, 2) do
        {:ok, Igniter.compose_task(igniter, task, [from, to] ++ igniter.args.argv_flags)}
      else
        _ ->
          {:missing, package}
      end
    end

    defp recover_mix_exs_and_lock(igniter, mix_exs, mix_lock, reason, options) do
      if !igniter.assigns[:test_mode?] do
        if options[:yes] ||
             Igniter.Util.IO.yes?("""
             Something went wrong during the upgrade process.

             #{reason}

             Restore mix.exs and mix.lock to their original contents?

             If you don't do this, you will need to reset them to upgrade again,
             or perform any upgrade steps manually.
             """) do
          File.write!("mix.exs", mix_exs)
          File.write!("mix.lock", mix_lock)
        end
      end
    end

    defp dep_changes_in_order(old_deps_info, new_deps_info) do
      new_deps_info
      |> sort_deps()
      |> Enum.flat_map(fn dep ->
        case Enum.find(old_deps_info, &(&1.app == dep.app)) do
          nil ->
            [{dep.app, nil, Version.parse!(elem(dep.status, 1))}]

          %{status: {:ok, old_version}} ->
            [{dep.app, Version.parse!(old_version), Version.parse!(elem(dep.status, 1))}]

          _other ->
            []
        end
      end)
      |> Enum.reject(fn {_app, old, new} ->
        old == new
      end)
    end

    defp sort_deps([]), do: []

    defp sort_deps(deps) do
      free_dep_name =
        Enum.find_value(deps, fn %{app: app, deps: children} ->
          if !Enum.any?(children, fn child ->
               Enum.any?(deps, &(&1.app == child))
             end) do
            app
          end
        end)

      next_dep_name = free_dep_name || elem(Enum.min_by(deps, &length(&1.deps)), 0)

      {[next_dep], others} = Enum.split_with(deps, &(&1.app == next_dep_name))

      [
        next_dep
        | sort_deps(
            Enum.map(others, fn dep ->
              %{dep | deps: Enum.reject(dep.deps, &(&1.app == next_dep_name))}
            end)
          )
      ]
    end

    defp replace_dep(igniter, package) do
      if String.contains?(package, "@") do
        requirement =
          case Igniter.Project.Deps.determine_dep_type_and_version(package) do
            {package, requirement} ->
              {package, requirement}

            :error ->
              Mix.shell().error("Invalid package identifier: #{package}")
              exit({:shutdown, 1})
          end

        Igniter.Project.Deps.add_dep(igniter, requirement, yes?: true)
      else
        igniter
      end
    end

    defp expand_deps(deps) do
      if Enum.any?(deps, &(&1.deps != [])) do
        expand_deps(Enum.flat_map(deps, &[%{&1 | deps: []} | &1.deps]))
      else
        Enum.uniq_by(deps, & &1.app)
      end
    end

    defp validate_packages!(packages) do
      Enum.each(packages, fn package ->
        package_name = String.split(package, "@") |> Enum.at(0) |> String.to_atom()

        dependency_declaration =
          Mix.Project.get!().project()[:deps] |> Enum.find(&(elem(&1, 0) == package_name))

        if String.contains?(package, "@") do
          is_non_version_updatable_package =
            case dependency_declaration do
              {_dep, opts} when is_list(opts) ->
                !!(opts[:path] || opts[:git] || opts[:github])

              {_dep, _, opts} ->
                !!(opts[:path] || opts[:git] || opts[:github])

              _ ->
                false
            end

          if is_non_version_updatable_package do
            Mix.shell().error("""
            The update specification `#{package}` is invalid because the package `#{package_name}`
            is pointing at a path, git, or github. These do not currently accept versions while upgrading.
            """)
          end
        end

        allowed_envs =
          case dependency_declaration do
            {_dep, opts} when is_list(opts) ->
              opts[:only]

            {_dep, _, opts} ->
              opts[:only]

            _ ->
              nil
          end

        allowed_envs =
          if allowed_envs == [] do
            nil
          else
            allowed_envs
          end

        if allowed_envs && !(Mix.env() in allowed_envs) do
          package_name = String.split(package, "@") |> Enum.at(0)

          Mix.shell().error("""
          Cannot update apply upgrade `#{package}` because the package `#{package_name}` is only included
          in the following environments: `#{inspect(allowed_envs)}`, but the current environment is `#{Mix.env()}`.

          Rerun this command with `MIX_ENV=#{Enum.at(allowed_envs, 0)} mix igniter.upgrade ...`
          """)
        end
      end)
    end
  end
end
