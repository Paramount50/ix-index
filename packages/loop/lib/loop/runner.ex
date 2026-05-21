defmodule Loop.Runner do
  @moduledoc """
  Iteration loop. Spawns the agent CLI, streams every line to the bus, then
  commits and pushes if the working tree changed. Returns an exit status
  for `System.stop/1`.
  """

  alias Loop.{Git, Identity, LogBus}

  def run(cfg), do: loop(cfg, 1)

  defp loop(cfg, i) do
    cond do
      cfg.iterations != 0 and i > cfg.iterations -> 0
      true ->
        changed? = iteration(cfg, i)
        if changed? and cfg.sleep_ms > 0, do: Process.sleep(cfg.sleep_ms)
        loop(cfg, i + 1)
    end
  end

  defp iteration(cfg, i) do
    LogBus.publish("── iteration #{i} ──")

    branch = Git.current_branch()
    if branch != cfg.branch, do: halt("expected branch #{cfg.branch}, found #{branch}")
    unless Git.clean?(), do: halt("working tree dirty before agent starts")

    Git.fast_forward!(cfg.branch)

    case stream_subprocess(cfg.agent_program, build_argv(cfg)) do
      0 -> :ok
      n -> halt("#{cfg.agent_program} exited #{n}")
    end

    case Git.changed_paths() do
      [] ->
        LogBus.publish("no changes; skipping commit")
        false

      paths ->
        case stream_subprocess(cfg.lint_program, []) do
          0 -> :ok
          n -> halt("lint failed (#{n})")
        end

        Git.commit!(cfg.commit_message, paths)
        Git.push!(cfg.branch)
        LogBus.publish("pushed #{length(paths)} path(s)")
        true
    end
  end

  defp build_argv(cfg) do
    case String.downcase(cfg.agent_program) do
      "codex" -> codex_argv(cfg)
      _ -> [cfg.prompt]
    end
  end

  defp codex_argv(cfg) do
    # Force every GIT_* identity var through codex's shell_environment_policy
    # so internal git operations attribute to the operator, not to the
    # `codex@example.com` placeholder that ships in codex's default git
    # identity (openai/codex#18095).
    git_passthrough =
      ~s|shell_environment_policy.include=["GIT_AUTHOR_NAME","GIT_AUTHOR_EMAIL","GIT_COMMITTER_NAME","GIT_COMMITTER_EMAIL"]|

    base = [
      "exec",
      "--cd",
      ".",
      "-c",
      ~s|model_reasoning_effort="#{cfg.reasoning_effort}"|,
      "-c",
      git_passthrough
    ]

    base = if cfg.bypass_sandbox, do: base ++ ["--dangerously-bypass-approvals-and-sandbox"], else: base
    base ++ [cfg.prompt]
  end

  defp halt(reason) do
    LogBus.publish("HALT: #{reason}")
    IO.puts(:stderr, "loop: #{reason}")
    System.stop(1)
    Process.sleep(:infinity)
  end

  defp stream_subprocess(exe, args) do
    # `Port.open/2` with `:exit_status` and `{:line, _}` gives us
    # line-buffered stdout and a final exit-status message — same shape the
    # Erlang port docs describe. `:stderr_to_stdout` keeps the order
    # readers expect when the agent interleaves the two.
    path =
      case System.find_executable(exe) do
        nil -> halt("agent program not found on PATH: #{exe}")
        p -> p
      end

    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 65_536},
        {:args, args},
        {:env, Identity.subprocess_env()}
      ])

    drain(port)
  end

  defp drain(port) do
    receive do
      {^port, {:data, {_eol_flag, line}}} ->
        LogBus.publish(line)
        drain(port)

      {^port, {:exit_status, status}} ->
        status
    after
      600_000 ->
        LogBus.publish("loop: subprocess receive timeout")
        drain(port)
    end
  end
end
