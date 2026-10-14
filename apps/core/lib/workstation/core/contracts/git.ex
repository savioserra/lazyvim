defmodule Workstation.Core.Contracts.Git do
  @moduledoc """
  The pinned-clone recipe kind: a git checkout pinned to an exact commit
  (url + commit + target), provisioned by declared recipe — never placed by
  hand.

  Layer: contract. The contract law: the kernel names no pin source —
  pinned clones are engine vocabulary published through discovery, and
  packages declare pins as data against the kind, never as recipe code
  (implementor policy: this engine module is the pinned-clone kind's only
  implementor, on both the plan-time and apply-time handshakes).

  An engine-owned recipe kind — mechanism vocabulary, like file/symlink — that carries its own effects. The plan-time
  handshake lives here (`Workstation.Core.Contracts.Provider`): the catalog
  discovers `provider: "git"` contributions through it, golden replay
  denormalizes recorded pins through it, and composition returns the pin
  inventory as the provider's composed domain view — the plan's capability
  profile entries the apply-time fold derives clone effects from. The
  apply-time handshake (`Workstation.Core.Contracts.Contract`) lives in the
  sibling `Workstation.Core.Contracts.Git.Effects`: one module per behaviour, so
  the two handshakes never fight over callbacks and both discoveries stay
  behaviour-conformance checks.

  Fail-closed posture, matching the pinned-download contract: https urls
  only, the commit must be a 40-hex lowercase sha, the target is a relative
  literal path that never touches engine-private state, and one checkout
  target may have only one owner.

  Convergence is the kind's law on BOTH edges: a composed pin clones, and a
  RECORDED clone whose recipe was dropped retires. `activate_retirements/2`
  derives the retirement candidates at the apply-mode composition boundary
  (journal-driven, like `Workstation.Core.Source.activate_removals/3` — the
  pure `plan/1` composes no journal, so a replay stays a function of its
  input bytes): a journal target record typed `git` whose target the pin
  inventory no longer names. A candidate must still carry the full
  git-shaped claim (url, 40-hex commit, owner, re-derivable source
  fingerprint) and must not overlap a still-declared pin — anything less is
  journal corruption surfaced at plan time, never a silent skip.
  """

  @behaviour Workstation.Core.Contracts.Provider

  alias Workstation.Core.{CanonicalJSON, Digest}

  @commit_format ~r/\A[0-9a-f]{40}\z/
  @engine_state_target ".local/state/workstation"

  @doc "The wire provider id for pinned-clone contributions."
  @impl Workstation.Core.Contracts.Provider
  @spec id() :: String.t()
  def id, do: "git"

  @doc """
  Build one validated pin from its declared fields. Raises `ArgumentError`
  on any invalid field: the url must be https (the supply-chain posture of a
  pinned checkout), the commit a 40-hex lowercase sha, and the target a safe
  relative literal path that never touches engine-private state.
  """
  @spec recipe(map()) :: map()
  def recipe(attrs) when is_map(attrs) do
    url = field(attrs, :url)
    commit = field(attrs, :commit)
    target = field(attrs, :target)

    validate_url(url)
    validate_commit(commit)
    validate_target(target)

    %{id: id(), url: url, commit: commit, target: target, fingerprint: pin_fingerprint(url, commit, target)}
  end

  @doc "The pin fingerprint: content address over the exact pin fields."
  @spec pin_fingerprint(String.t(), String.t(), String.t()) :: String.t()
  def pin_fingerprint(url, commit, target) do
    Digest.sha256(CanonicalJSON.encode(%{"commit" => commit, "target" => target, "url" => url}))
  end

  @doc """
  Validate one declared pin spec: exactly the three pin fields (a composed
  recipe may additionally carry its derived id/fingerprint). Raises
  `ArgumentError` on the first invalid field.
  """
  @impl Workstation.Core.Contracts.Provider
  @spec validate_spec(map()) :: :ok
  def validate_spec(spec) when is_map(spec) do
    url = field(spec, :url)
    commit = field(spec, :commit)
    target = field(spec, :target)

    validate_url(url)
    validate_commit(commit)
    validate_target(target)

    unknown = Map.keys(spec) -- [:url, :commit, :target, :id, :fingerprint]
    unknown == [] || raise(ArgumentError, "git recipe has unknown fields: #{inspect(unknown)}")

    :ok
  end

  def validate_spec(other), do: raise(ArgumentError, "git recipe must be a map, got: #{inspect(other)}")

  @doc """
  Denormalize one recorded-envelope spec (string-keyed golden bytes) back to
  the validated atom-keyed recipe, so replay compares equal to native
  declarations.
  """
  @impl Workstation.Core.Contracts.Provider
  @spec denormalize_spec(map()) :: map()
  def denormalize_spec(spec) when is_map(spec) do
    recipe(%{
      url: Map.get(spec, "url"),
      commit: Map.get(spec, "commit"),
      target: Map.get(spec, "target")
    })
  end

  def denormalize_spec(other),
    do: raise(ArgumentError, "git recipe must be a table, got: #{inspect(other)}")

  @doc """
  Compose the collected pins (graph-ordered `%{owner:, spec:}` records) into
  the provider's plan contribution: the source record (spliced back into
  the collection under the git provider id) and the composed domain view —
  the pin inventory the effect contract derives its clone effects from. One
  target may have only one owner; duplicate targets conflict instead of
  racing.
  """
  @impl Workstation.Core.Contracts.Provider
  @spec compose([%{required(:owner) => String.t(), required(:spec) => map()}]) :: {map(), [map()]}
  def compose(intents) when is_list(intents) do
    intents != [] || raise(ArgumentError, "git composition requires at least one intent")

    {pins, _seen} =
      Enum.map_reduce(intents, MapSet.new(), fn intent, seen ->
        :ok = validate_spec(intent.spec)
        pin = recipe(intent.spec) |> Map.put(:owner, intent.owner)
        MapSet.member?(seen, pin.target) &&
          raise(ArgumentError, "duplicate git target #{pin.target}: one checkout target may have only one owner")

        {pin, MapSet.put(seen, pin.target)}
      end)

    record = %{owner: "git", provider: id(), spec: pins, attribution: Enum.map(pins, & &1.owner)}
    {record, Enum.map(pins, &Map.put(&1, :git_pin, true))}
  end

  @doc """
  Activate the journal-driven retirement candidates on one composed plan:
  every journal target record typed `git` whose target the plan's pin
  inventory no longer names. The pure `Workstation.Core.Source.plan/1`
  probes no journal, so this runs at the one production composition boundary
  (`Workstation.Pipeline` apply-mode compose), where the journal record the
  plan was built against is readable — the same seam that activates declared
  removals. A nil journal (fresh home, golden replay) retires nothing.

  Fail-closed on the record, not silent: a `git`-typed record that lost any
  part of its claim (url, 40-hex commit, owner, source fingerprint that no
  longer re-derives from the recorded triple) raises — a half-decoded record
  must never arm a deletion. The https posture itself is the recipe
  constructor's law (declared pins only); a recorded candidate is proven by
  the fingerprint re-derivation, which any tampered field breaks. A
  candidate whose target overlaps a still-declared pin (either direction)
  raises too: retirement never deletes through a declared checkout.
  """
  @spec activate_retirements(Workstation.Core.Source.t(), map() | nil) ::
          Workstation.Core.Source.t()
  def activate_retirements(%Workstation.Core.Source{} = plan, journal) do
    recorded = (is_map(journal) && Map.get(journal, "targets")) || %{}
    pinned = MapSet.new(pins(plan), & &1.target)

    candidates =
      recorded
      |> Enum.filter(fn {_target, record} -> is_map(record) && Map.get(record, "type") == "git" end)
      |> Enum.reject(fn {target, _record} -> MapSet.member?(pinned, target) end)
      |> Enum.map(fn {target, record} -> retirement_candidate(target, record, pinned) end)

    %{plan | git_retirements: candidates}
  end

  defp pins(plan), do: plan.profile |> List.wrap() |> Enum.filter(&Map.get(&1, :git_pin))

  defp retirement_candidate(target, record, pinned) do
    url = claim_field(record, "url", target)
    commit = claim_field(record, "commit", target)
    owner = claim_field(record, "owner", target)
    source_fingerprint = claim_field(record, "source_fingerprint", target)

    validate_target(target)
    validate_commit(commit)
    # The recorded url is inert provenance — retirement never dereferences
    # it — and the source-fingerprint re-derivation below is the strictly
    # stronger claim check: any tampered field breaks it.

    source_fingerprint == pin_fingerprint(url, commit, target) ||
      raise(ArgumentError,
        "git retirement of #{target} refused: the journal record's source fingerprint does not re-derive " <>
          "from the recorded pin; the record is not a provable clone claim"
      )

    Enum.each(pinned, fn pin_target ->
      not is_within(target, pin_target) and not is_within(pin_target, target) ||
        raise(ArgumentError,
          "git retirement of #{target} refused: the pin inventory still owns #{pin_target} at the same path; " <>
            "retirement never deletes through a declared checkout"
        )
    end)

    %{target: target, url: url, commit: commit, owner: owner, source_fingerprint: source_fingerprint}
  end

  defp claim_field(record, key, target) do
    value = Map.get(record, key)
    is_binary(value) and value != "" ||
      raise(ArgumentError, "git retirement of #{target} refused: the journal record has no #{key}; " <>
             "a git-typed record without its claim is corruption, not provenance")
    value
  end

  # --- validation ---

  defp field(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    is_binary(value) and value != "" || raise(ArgumentError, "git recipe requires #{key}")
    value
  end

  defp validate_url(url) do
    String.starts_with?(url, "https://") ||
      raise(ArgumentError, "git url must be https (pinned supply chain), got: #{url}")
  end

  defp validate_commit(commit) do
    Regex.match?(@commit_format, commit) ||
      raise(ArgumentError, "git commit must be a 40-hex lowercase sha, got: #{commit}")
  end

  defp validate_target(target) do
    not String.match?(target, ~r/[\x00-\x1f\x7f]/) ||
      raise(ArgumentError, "git target must not contain control characters: #{target}")

    not String.match?(target, ~r/[*?\[\]]/) ||
      raise(ArgumentError, "git target must be a literal path: #{target}")

    not String.starts_with?(target, "/") && not String.starts_with?(target, "~") &&
        not Regex.match?(~r/(\A|\/)\.\.?(\z|\/)/, target) ||
      raise(ArgumentError, "git target must be a relative path inside the home: #{target}")

    not is_within(target, @engine_state_target) && not encompasses(target, @engine_state_target) ||
      raise(ArgumentError, "git target overlaps engine-private state: #{target}")

    :ok
  end

  defp is_within(target, ancestor), do: target == ancestor or String.starts_with?(target, ancestor <> "/")
  defp encompasses(ancestor, target), do: is_within(target, ancestor)
end

defmodule Workstation.Core.Contracts.Git.Effects do
  @moduledoc """
  The pinned-clone effect contract: the apply-time handshake of the git
  recipe kind (`Workstation.Core.Contracts.Contract`, discovered by
  behaviour conformance — the fold never names it).

  Layer: contract. The contract law: the fold never names a mutation —
  every clone effect derives from the plan's composed pin inventory through
  the discovered contract (implementor policy: this engine module is the
  pinned-clone kind's only apply-time implementor).

  One clone effect per composed pin, derived from the plan's capability
  profile (the provider's pin inventory). Idempotent: a checkout already
  carrying the pinned commit is `{:ok, :already_pinned}` — the verify reads
  the local HEAD, so a re-apply neither fetches nor unshallows.
  Fail-closed: a directory that is not a checkout, or a checkout pinned to
  a different commit, is never moved or overwritten (remove it explicitly);
  the claim re-verifies HEAD against the pin and records a git-shaped
  ownership record (type + commit — a checkout's bytes move upstream, the
  pin is the owned identity).

  Retirement is the kind's convergence edge (`Git.activate_retirements/2`
  derives the candidates): a `:retire` effect removes a RECORDED clone whose
  recipe the plan dropped, guarded exactly like a chezmoi removal — the
  recorded identity must still match the live checkout (a directory, HEAD at
  the recorded pin, clean tree) before anything is deleted; on drift the
  effect fails closed naming the divergence (moved HEAD, dirty tree,
  non-checkout), never a silent destructive adoption. An absent target is
  already retired — the idempotent arm. The retire claim is absence: the
  effect verifies the checkout is gone, records nothing, and the next
  applied journal drops the target record.

  Clones are shallow-safe: `git init` + `git fetch --depth 1 origin <sha>`,
  falling back to one unshallowed fetch of the pinned commit when the
  remote refuses shallow SHA fetches; the checkout is a detached HEAD
  verified against the pin after every mutation. The subprocess sees the
  target home as HOME and never prompts.
  """

  @behaviour Workstation.Core.Contracts.Contract

  @doc "The wire contract id of pinned-clone effects (matches the provider id)."
  @impl Workstation.Core.Contracts.Contract
  @spec id() :: String.t()
  def id, do: "git"

  @doc "Validate one declared pin spec (the behaviour's spec entry point)."
  @impl Workstation.Core.Contracts.Contract
  @spec validate_spec(map()) :: :ok
  def validate_spec(spec), do: Workstation.Core.Contracts.Git.validate_spec(spec)

  @doc """
  The plan's clone and retirement effects: one typed effect per composed pin
  (derived from the provider's domain view carried by the plan — the
  capability profile entries marked `git_pin`) and one typed effect per
  activated retirement (the journal-driven candidates the composition
  boundary derived). Per-target phase — every clone and retirement runs
  before the staged-generation apply effect.
  """
  @impl Workstation.Core.Contracts.Contract
  @spec plan_effect(term(), map()) :: [map()]
  def plan_effect(plan, _ctx) do
    clone_effects =
      plan.profile
      |> List.wrap()
      |> Enum.filter(&Map.get(&1, :git_pin))
      |> Enum.map(fn pin ->
        %{
          contract: id(),
          kind: :clone,
          phase: :target,
          owner: pin.owner,
          target: pin.target,
          url: pin.url,
          commit: pin.commit,
          fingerprint: pin.fingerprint
        }
      end)

    retire_effects =
      plan.git_retirements
      |> List.wrap()
      |> Enum.map(fn retirement ->
        %{
          contract: id(),
          kind: :retire,
          phase: :target,
          owner: retirement.owner,
          target: retirement.target,
          url: retirement.url,
          commit: retirement.commit
        }
      end)

    clone_effects ++ retire_effects
  end

  @doc """
  Idempotent pinned clone at the apply boundary, or the guarded retirement
  of a dropped recipe's recorded clone. The git executable is resolved from
  PATH (fail-closed when absent — install git or run bootstrap).
  """
  @impl Workstation.Core.Contracts.Contract
  @spec run_effect(map(), map()) :: :ok
  def run_effect(%{kind: :retire} = effect, ctx) do
    git = git_executable!()
    retire(git, ctx.home, effect)
  end

  def run_effect(effect, ctx) do
    git = git_executable!()
    home = ctx.home
    directory = Path.join(home, effect.target)

    case Workstation.Core.EngineState.lstat(directory) do
      nil ->
        clone(git, home, directory, effect)

      %{type: "directory"} ->
        head = rev_parse(git, home, directory)

        cond do
          head == nil ->
            raise ArgumentError,
                  "git target #{effect.target} exists and is not a git checkout " <>
                    "(pin verify impossible); remove it explicitly"

          head == effect.commit ->
            # Already pinned: the fold treats every effect uniformly, so the
            # outcome surfaces as :ok — the fold never re-fetches a pinned
            # checkout; that is the idempotency, not just a convenience.
            :ok

          true ->
            raise ArgumentError,
                  "git checkout #{effect.target} is pinned to #{head}, refusing to move it to " <>
                    "#{effect.commit}; remove it explicitly"
        end

      %{type: other} ->
        raise ArgumentError, "git target #{effect.target} exists as #{other}; refusing to replace it"
    end
  end

  @doc """
  The verify seam: a git-shaped journal record re-checks HEAD against the
  pinned commit on the ACTUAL checkout; anything else is :unclaimed (the
  default file-fingerprint verification takes it).
  """
  @impl Workstation.Core.Contracts.Contract
  @spec verify_record(map(), map()) :: :ok | :unclaimed
  def verify_record(%{"type" => "git", "commit" => commit}, ctx) do
    directory = Path.join(ctx["home"], ctx["target"])

    unless Workstation.Core.EngineState.lstat(directory) do
      raise ArgumentError, "verify: git target #{ctx["target"]} is gone"
    end

    git = git_executable!()

    unless rev_parse(git, ctx["home"], directory) == commit do
      raise ArgumentError,
            "git pin verify failed for #{ctx["target"]}: HEAD does not carry the pinned commit #{commit}"
    end

    :ok
  end

  def verify_record(_record, _ctx), do: :unclaimed

  @doc """
  The applied-target ownership claim for one effect: the pin verify against
  the ACTUAL checkout — HEAD must carry the pinned commit or the claim
  raises instead of recording. A retirement's claim is ABSENCE: the checkout
  must be gone (an effect that did not produce exactly its declared outcome
  raises instead of recording), and the empty map records nothing — the next
  applied journal drops the target record.
  """
  @impl Workstation.Core.Contracts.Contract
  @spec fingerprint(map(), map()) :: map()
  def fingerprint(%{kind: :retire} = effect, ctx) do
    Workstation.Core.EngineState.lstat(Path.join(ctx.home, effect.target)) &&
      raise(ArgumentError, "git retirement of #{effect.target} did not remove the checkout")

    %{}
  end

  def fingerprint(effect, ctx) do
    directory = Path.join(ctx.home, effect.target)

    unless Workstation.Core.EngineState.lstat(directory) do
      raise(ArgumentError, "apply did not produce git target " <> effect.target)
    end

    git = git_executable!()

    unless rev_parse(git, ctx.home, directory) == effect.commit do
      raise ArgumentError,
            "git pin verify failed for #{effect.target}: HEAD does not carry the pinned commit #{effect.commit}"
    end

    %{effect.target =>
       %{
         "type" => "git",
         "commit" => effect.commit,
         "url" => effect.url,
         "owner" => effect.owner,
         "operation" => "clone",
         "source_fingerprint" => effect.fingerprint
       }}
  end

  # --- clone mechanics (shallow-safe, fail-closed) ---

  # The retirement guard mirrors the chezmoi removal precondition
  # (Workstation.Core.Preconditions.check_removal/3): the recorded identity
  # must still match the live target before anything is deleted. Drift
  # (moved HEAD, dirty tree, non-checkout, wrong type) refuses with the
  # divergence named — the checkout stays on disk for the operator to
  # resolve, never silently deleted. An absent target is already retired.
  defp retire(git, home, effect) do
    directory = Path.join(home, effect.target)

    case Workstation.Core.EngineState.lstat(directory) do
      nil ->
        :ok

      %{type: "directory"} ->
        head = rev_parse(git, home, directory)

        cond do
          head == nil ->
            raise ArgumentError,
                  "git retirement of #{effect.target} refused: it exists and is not a git checkout " <>
                    "(recorded pin #{effect.commit} unverifiable); inspect it and remove it explicitly"

          head != effect.commit ->
            raise ArgumentError,
                  "git retirement of #{effect.target} refused: HEAD is at #{head}, but the recorded pin is " <>
                    "#{effect.commit}; the checkout drifted from its record, resolve it explicitly"

          true ->
            dirty = status_porcelain(git, home, directory)

            dirty == [] ||
              raise ArgumentError,
                    "git retirement of #{effect.target} refused: the checkout carries local changes " <>
                      "(#{Enum.join(dirty, "; ")}); commit or discard them explicitly"

            File.rm_rf!(directory)
            :ok
        end

      %{type: other} ->
        raise ArgumentError,
              "git retirement of #{effect.target} refused: it exists as #{other}, not the recorded checkout"
    end
  end

  defp clone(git, home, directory, effect) do
    File.mkdir_p!(Path.dirname(directory))
    git!(git, home, ["init", "--quiet", directory])
    git!(git, home, ["-C", directory, "remote", "add", "origin", effect.url])

    # Shallow first: a one-commit fetch of the pinned sha. Some remotes
    # refuse SHA-in-want uploads; the fallback is one unshallowed fetch of
    # the same pin — still content-verified by the checkout + rev-parse
    # below, never a blind checkout of a moving ref.
    shallow = git_fetch(git, home, ["-C", directory, "fetch", "--depth", "1", "origin", effect.commit])

    unless shallow, do: git!(git, home, ["-C", directory, "fetch", "origin", effect.commit])

    git!(git, home, ["-C", directory, "checkout", "--quiet", "--detach", "FETCH_HEAD"])

    unless rev_parse(git, home, directory) == effect.commit do
      raise ArgumentError,
            "git clone for #{effect.target} did not land on the pinned commit #{effect.commit}"
    end

    :ok
  end

  defp git_fetch(git, home, args) do
    case System.cmd(git, args, env: git_env(home), stderr_to_stdout: false) do
      {_out, 0} -> true
      {_out, _code} -> false
    end
  rescue
    _error -> false
  end

  defp rev_parse(git, home, directory) do
    case System.cmd(git, ["-C", directory, "rev-parse", "HEAD"], env: git_env(home), stderr_to_stdout: false) do
      {out, 0} -> String.trim_trailing(out)
      {_out, _code} -> nil
    end
  end

  # The clean-tree arm of the retirement guard: `status --porcelain` names
  # every staged, modified or untracked path (ignored files stay ignored —
  # the standard clean-tree definition), so a checkout the operator touched
  # can never be retired behind their back.
  defp status_porcelain(git, home, directory) do
    case System.cmd(git, ["-C", directory, "status", "--porcelain"], env: git_env(home), stderr_to_stdout: false) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.take(3)
      {_out, _code} -> ["status unreadable"]
    end
  end

  defp git!(git, home, args) do
    case System.cmd(git, args, env: git_env(home), stderr_to_stdout: false) do
      {_out, 0} ->
        :ok

      {out, code} ->
        raise ArgumentError, "git failed (exit #{code}): #{Enum.join(args, " ")} -- #{String.trim_trailing(out)}"
    end
  end

  # The subprocess sees the target home as HOME (the operator's ambient
  # config never leaks into a pinned checkout), exactly like the backend
  # apply effect — and it never prompts: a credential-hungry remote is a
  # failure, not an interactive session.
  defp git_env(home), do: %{"HOME" => home, "WORKSTATION_HOME" => home, "GIT_TERMINAL_PROMPT" => "0"}

  defp git_executable! do
    System.find_executable("git") ||
      raise ArgumentError, "git clone failed: no git executable on PATH; install git or run bootstrap"
  end
end
