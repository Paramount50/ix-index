defmodule Loop.CLI do
  @moduledoc """
  Escript entry. Starts the supervised application (log bus + Bandit), parses
  argv, runs the iteration loop, then halts the VM with the runner's exit
  status. Escripts do not auto-start applications, so the explicit
  `ensure_all_started` is load-bearing.
  """

  @switches [
    branch: :string,
    prompt: :string,
    prompt_file: :string,
    commit_message: :string,
    lint_program: :string,
    agent_program: :string,
    reasoning_effort: :string,
    bypass_sandbox: :boolean,
    iterations: :integer,
    sleep_secs: :integer,
    once: :boolean
  ]

  def main(argv) do
    {:ok, _} = Application.ensure_all_started(:loop)
    cfg = parse!(argv)
    port = Application.get_env(:loop, :web_port, 7878)
    IO.puts("loop: web ui at http://localhost:#{port}")
    Loop.LogBus.publish("loop: web ui at http://localhost:#{port}")
    status = Loop.Runner.run(cfg)
    System.halt(status)
  end

  defp parse!(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      die("unknown flag(s): #{inspect(invalid)}")
    end

    lint = Keyword.get(opts, :lint_program) || die("--lint-program is required")

    iterations =
      if Keyword.get(opts, :once, false), do: 1, else: Keyword.get(opts, :iterations, 0)

    %{
      branch: Keyword.get(opts, :branch, "development"),
      prompt: resolve_prompt(opts),
      commit_message: Keyword.get(opts, :commit_message, "loop: improve repo quality"),
      lint_program: lint,
      agent_program: Keyword.get(opts, :agent_program, "codex"),
      reasoning_effort: Keyword.get(opts, :reasoning_effort, "xhigh"),
      bypass_sandbox: Keyword.get(opts, :bypass_sandbox, true),
      iterations: iterations,
      sleep_ms: Keyword.get(opts, :sleep_secs, 30) * 1000
    }
  end

  # Resolution order, first match wins:
  #   1. `--prompt "..."` literal
  #   2. `--prompt-file path/to/prompt.md` (read once at startup)
  #   3. `LOOP_PROMPT_FILE=...` env var, same shape as flag
  #   4. `./loop-prompt.md` if present in the working directory
  #
  # No built-in default: a giant repo-specific prompt does not belong baked
  # into a binary that is supposed to be agent-agnostic and repo-agnostic.
  # Fail loudly if no source is provided.
  defp resolve_prompt(opts) do
    cond do
      literal = Keyword.get(opts, :prompt) -> literal
      path = Keyword.get(opts, :prompt_file) -> read_prompt!(path)
      path = System.get_env("LOOP_PROMPT_FILE") -> read_prompt!(path)
      File.exists?("loop-prompt.md") -> read_prompt!("loop-prompt.md")
      true ->
        die(
          "no prompt provided. pass --prompt \"...\", --prompt-file path.md, " <>
            "set $LOOP_PROMPT_FILE, or create loop-prompt.md next to the checkout."
        )
    end
  end

  defp read_prompt!(path) do
    case File.read(path) do
      {:ok, text} -> String.trim(text)
      {:error, reason} -> die("could not read prompt file #{path}: #{:file.format_error(reason)}")
    end
  end

  defp die(reason) do
    IO.puts(:stderr, "loop: #{reason}")
    System.halt(2)
  end
end
