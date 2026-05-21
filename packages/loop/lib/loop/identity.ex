defmodule Loop.Identity do
  @moduledoc """
  Reads the operator's git identity once at startup and exposes it as env
  vars that override anything an agent subprocess tries to set itself.

  Without this, codex (and other agents) commit under their own identity:
  even when the outer loop is the one calling `git commit`, any intermediate
  commits the agent makes inside its own session land as `codex <…>` or
  similar. Forcing `GIT_AUTHOR_*` and `GIT_COMMITTER_*` in the spawned
  environment routes every commit, ours or the agent's, through the human's
  configured git identity.
  """

  @doc """
  Returns the env-var list to pass into spawned subprocesses, as charlists
  (the shape `Port.open/2` wants). Returns `[]` if git has no configured
  identity, letting the subprocess fall back to its own resolution.
  """
  def subprocess_env do
    case identity() do
      {name, email} ->
        [
          {~c"GIT_AUTHOR_NAME", String.to_charlist(name)},
          {~c"GIT_AUTHOR_EMAIL", String.to_charlist(email)},
          {~c"GIT_COMMITTER_NAME", String.to_charlist(name)},
          {~c"GIT_COMMITTER_EMAIL", String.to_charlist(email)}
        ]

      :unconfigured ->
        []
    end
  end

  @doc """
  Same identity in the binary-keyed shape `System.cmd/3` expects.
  """
  def system_cmd_env do
    case identity() do
      {name, email} ->
        [
          {"GIT_AUTHOR_NAME", name},
          {"GIT_AUTHOR_EMAIL", email},
          {"GIT_COMMITTER_NAME", name},
          {"GIT_COMMITTER_EMAIL", email}
        ]

      :unconfigured ->
        []
    end
  end

  @doc """
  Public view of the operator's git identity, for callers that need to
  pass it through agent-specific config (codex's `commit_attribution`,
  etc.) rather than env vars.
  """
  def git_user, do: identity()

  defp identity do
    with {name, 0} <- System.cmd("git", ["config", "user.name"]),
         {email, 0} <- System.cmd("git", ["config", "user.email"]),
         name = String.trim(name),
         email = String.trim(email),
         true <- name != "" and email != "" do
      {name, email}
    else
      _ -> :unconfigured
    end
  end
end
