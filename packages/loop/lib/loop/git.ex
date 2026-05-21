defmodule Loop.Git do
  @moduledoc false

  alias Loop.Identity

  def current_branch, do: out!(~w(branch --show-current))

  def clean?, do: out!(~w(status --porcelain)) == ""

  def fast_forward!(branch) do
    cmd!(["fetch", "origin", branch])
    cmd!(["merge", "--ff-only", "origin/#{branch}"])
    :ok
  end

  def changed_paths do
    [
      ~w(diff --name-only --diff-filter=ACMRTUXB),
      ~w(diff --name-only --diff-filter=D),
      ~w(diff --cached --name-only),
      ~w(ls-files --others --exclude-standard)
    ]
    |> Enum.flat_map(&lines!/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def commit!(message, paths) do
    cmd!(["commit", "-m", message, "--"] ++ paths)
    :ok
  end

  def push!(branch) do
    cmd!(["push", "origin", "HEAD:#{branch}"])
    :ok
  end

  # Every git call routes through here so the operator's GIT_AUTHOR_* /
  # GIT_COMMITTER_* override anything an outer wrapper or shell might have
  # leaked into the env. See `Loop.Identity` for the rationale.
  defp cmd!(args) do
    {_, 0} = System.cmd("git", args, env: Identity.system_cmd_env(), stderr_to_stdout: true)
    :ok
  end

  defp out!(args) do
    {out, 0} = System.cmd("git", args, env: Identity.system_cmd_env())
    String.trim(out)
  end

  defp lines!(args) do
    args
    |> out!()
    |> String.split("\n", trim: true)
  end
end
