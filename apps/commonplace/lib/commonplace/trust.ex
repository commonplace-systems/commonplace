defmodule Commonplace.Trust do
  @moduledoc """
  The trust boundary: `authorized?(commit, verb, scope)`.

  The real gate topology (CX-vyrs — see `posture/0` for a one-call summary
  of where each lane currently sits):

    * **Gate A** (import, `CommitStore.import_commit`) — calls this module
      UNCONDITIONALLY; no knob softens it.
    * **local-write gate** (`CommitStore`'s `local_write_gate_check/2`,
      every local commit create) — calls `authorized_to_write?/4`, staged
      by the `:local_write_gate` knob (`:off` | `:dry_run` (default) |
      `:enforce`; CX-qat5.7 wires an env-var activation path).
    * **Gate B** (execute, `authorized_to_execute?/3`) and the sandboxed
      define-verb gate — STRUCTURAL, always on; not staged by any knob.
    * **read gates** — the P1/P2 surfaces (MudLive, `World.room_snapshot`,
      MCP `cat`, GitBridge) call `reader_authorized?/6` DIRECTLY and are
      PINNED `:enforce`; the P3 cohort (TreeLive/WikiLive, `@dump`, MCP
      `tail_red`/`invoke_view_action`/`tree://`, `fork`'s source-check)
      goes through `Trust.Read.gate/3`, staged by the SEPARATE
      `:local_read_gate` knob (`:permissive` (default) | `:dry_run` |
      `:enforce`; CX-a7i2 wires its env-var activation path).

  Every lane bottoms out in this module's `authorized?/authorized_to_*`
  family — never an allowlist or capability store directly — so phase-3's
  capability-chain walk swaps in underneath without any call site
  changing. See docs/trust-and-attenuation.md (commonplace-plan) §2/§4/§7.

  ## Phase-1 semantics (flat allowlist)

  Config is two values, both **workspace-local** — never read from a
  synced document, because a federated peer can write any synced doc
  (including the `__identities__` key registry), so synced state cannot
  anchor trust:

    * `accept_unsigned` — the permissive/strict knob. Defaults to `true`
      (back-compat: existing workspaces are full of unsigned commits);
      flips to `false` once federation is live.
    * `trusted_identities` — pinned `identity_uuid => public_key` entries
      (base64 keys, single or list per identity). Pinned locally for the
      same reason: the identity docs' own `public_keys` field is
      peer-writable.

  Decision table (verb/scope are accepted now so phase-3 doesn't reshape
  the call sites, but the allowlist body ignores them):

  | commit                                   | permissive | strict |
  |------------------------------------------|------------|--------|
  | unsigned                                 | ok         | `:unsigned` |
  | trusted identity, valid signature        | ok         | ok |
  | trusted identity, INVALID signature      | `:invalid_signature` | same |
  | unknown identity                         | ok         | `{:untrusted_signer, uuid}` |
  | malformed signer_id                      | ok         | `:invalid_signer_id` |

  A bad signature from a *trusted* identity rejects in **both** modes: no
  legitimate flow signs with a key other than the pinned one (and the
  signature lives outside the content address, so `verify_id` cannot
  catch it) — it is forgery or corruption either way.

  ## Config resolution

  `config/0`: application env `:commonplace, :trust` (used by tests and
  embedders) → `<data_dir>/trust.json` → `default_config/0`. The JSON
  file lives beside the workspace's other local state (`root`,
  `node_id`) under `.commonplace/`, which is exactly the
  not-synced-not-peer-writable surface the anchor decision requires.
  """

  alias Commonplace.Crypto.Signing
  alias Commonplace.Store.Commit

  # CX-0a9a (presence-carve, W3): the content-check reconstructs and
  # value-diffs the target doc, so it reaches for the doc/tree layer.
  alias Commonplace.Document.ContentType
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.{Doc, Encoding}

  require Logger

  @type verb :: :write | :execute | :read
  @type scope :: {:doc, String.t()}
  @type config :: %{
          accept_unsigned: boolean(),
          trusted_identities: %{String.t() => String.t() | [String.t()]}
        }

  @doc """
  Is this commit's signer authorized for `verb` at `scope`?

  Returns `:ok` or `{:error, reason}`. The 3-arity head resolves config
  via `config/0`; the 4-arity head takes it explicitly (pure, for tests
  and callers that batch-load config).
  """
  @spec authorized?(Commit.t(), verb(), scope()) :: :ok | {:error, term()}
  def authorized?(%Commit{} = commit, verb, scope) do
    authorized?(commit, verb, scope, config())
  end

  @doc """
  As `authorized?/3` but with explicit config (and, for the phase-3
  capability path, an explicit cert store). The gates call the 3-arity
  head; `store` defaults to `CommitStoreClient` so the seam is unchanged.
  """
  @spec authorized?(Commit.t(), verb(), scope(), config(), GenServer.server()) ::
          :ok | {:error, term()}
  def authorized?(commit, verb, scope, cfg, store \\ Commonplace.Store.CommitStoreClient)

  def authorized?(%Commit{signature: nil}, _verb, _scope, cfg, _store) do
    if cfg.accept_unsigned, do: :ok, else: {:error, :unsigned}
  end

  def authorized?(%Commit{} = commit, verb, scope, cfg, store) do
    case Signing.parse_signer_id(commit.signer_id || "") do
      {:ok, identity_uuid, _fingerprint} ->
        case Map.fetch(cfg.trusted_identities, identity_uuid) do
          {:ok, pinned} ->
            # (a) degenerate fast-path: a locally-pinned identity is an
            # unattenuated root — R1/R2 behavior, unchanged.
            verify_against_pinned(commit, pinned)

          :error ->
            # (b) not pinned: if the commit carries a capability proof,
            # walk the cert chain; else (c) fall to the existing logic.
            case Map.get(commit.metadata, :capability_proof) do
              nil ->
                if cfg.accept_unsigned,
                  do: :ok,
                  else: {:error, {:untrusted_signer, identity_uuid}}

              leaf_cid ->
                capability_path(commit, verb, scope, leaf_cid, cfg, store)
            end
        end

      {:error, :invalid_signer_id} ->
        if cfg.accept_unsigned, do: :ok, else: {:error, :invalid_signer_id}
    end
  end

  @doc """
  CX-gjpi — the COMMITLESS mirror of `authorized?/5` for the safe-verb
  object-owner-authority ELEVATION pre-check (`Commonplace.MUD.World.Facade`,
  option (2) "elevate only when the invoker lacks authority"): would a
  `:write` to `target_uuid` by `identity_uuid` (public key `pub`, holding
  `cert_cids`) be authorized under `cfg`, using the SAME predicate the
  write-gate applies to the resulting signed commit — minus the
  signature-validity check, which holds by construction when that identity
  actually signs?

  Mirrors `authorized?/5`'s object-write branches exactly:
    * `accept_unsigned` (permissive) → `true` (any write lands; no elevation).
    * identity pinned in `trusted_identities` → `true` (root authority).
    * else `true` iff a held cert is (i) addressed to THIS identity's key
      (the `author_binding/2` mirror — a cert for another audience can't
      authorize this writer) and (ii) its verified chain grants `:write`
      over `target_uuid` in a `{:docs, _}` scope. A `{:presence, _}` cert
      never authorizes an object-STATE write (its content-gate refuses
      anything but the signer's own presence entry), so it's correctly
      ignored here.
  """
  @spec writer_authorized?(
          String.t() | nil,
          binary() | nil,
          [binary()],
          String.t(),
          config(),
          GenServer.server()
        ) :: boolean()
  def writer_authorized?(identity_uuid, pub, cert_cids, target_uuid, cfg, store) do
    cond do
      cfg.accept_unsigned -> true
      not is_binary(identity_uuid) -> false
      Map.has_key?(cfg.trusted_identities, identity_uuid) -> true
      true -> Enum.any?(cert_cids, &cert_grants_write?(&1, pub, target_uuid, cfg, store))
    end
  end

  defp cert_grants_write?(cid, pub, target_uuid, cfg, store) do
    with {:ok, leaf} <- fetch_cap(store, cid),
         {_uuid, audience_pub} <- leaf.audience,
         true <- pub != nil and audience_pub == pub,
         {:ok, %{verbs: verbs, scope: scope}} <-
           Commonplace.Trust.VerifyChain.verify_chain(cid, anchor_keys(cfg), store) do
      :write in verbs and write_scope_covers?(scope, target_uuid, store)
    else
      _ -> false
    end
  end

  @doc """
  CX-cj3t / CX-fogy — the COMMITLESS mirror of "may this caller AUTHOR a
  SANDBOXED safe-verb at `target_uuid`?", for an UPFRONT UX gate: the `@verb`
  editor uses it to open in EDIT vs read-only PREVIEW mode, instead of offering a
  full editor and only denying the save afterward.

  The `@verb` editor writes ONLY sandboxed safe-verbs (`save_safe_verb`: lint +
  AST-allowlist + facade-bound), whose commit-time gate is `DefineVerbGate`
  (`:define_verb` over the verb's section) — NOT the raw-code `:execute` / Gate-B
  lane. `:execute` is delegable by explicit cert, though no cert carrying it had
  been minted before CX-b38c; the editor never reaches that lane. So this pre-check
  mirrors THAT gate: authorized iff a trusted identity (the node), or a
  verified cert granting `:define_verb` over the target's zone — exactly the
  citizenship `{:subtree,home}[:define_verb]` grant (CX-fogy). This is the
  sandboxed-authoring lane; raw executable engine code requires node authority or
  an explicit `:execute` cert (Gate-B, `authorized_to_execute?`) and is untouched
  by this `:define_verb` cert. Under
  `accept_unsigned` (the permissive dev gate) the save would land, so this returns
  `true` (editor stays fully functional). Fail-closed on any error.

  (Historically this checked `:execute` — the write⊥execute belt for RAW code —
  which is the wrong lane for a sandboxed safe-verb and is why a `:write`-only
  citizen was wrongly shown read-only PREVIEW on their own home. CX-fogy points it
  at the real safe-verb gate, `:define_verb`.)
  """
  @spec safe_verb_author_authorized?(
          String.t() | nil,
          binary() | nil,
          [String.t()],
          String.t(),
          config(),
          GenServer.server()
        ) ::
          boolean()
  def safe_verb_author_authorized?(identity_uuid, pub, cert_cids, target_uuid, cfg, store) do
    cond do
      cfg.accept_unsigned -> true
      not is_binary(identity_uuid) -> false
      Map.has_key?(cfg.trusted_identities, identity_uuid) -> true
      true -> Enum.any?(cert_cids, &cert_grants_define_verb?(&1, pub, target_uuid, cfg, store))
    end
  end

  defp cert_grants_define_verb?(cid, pub, target_uuid, cfg, store) do
    with {:ok, leaf} <- fetch_cap(store, cid),
         {_uuid, audience_pub} <- leaf.audience,
         true <- pub != nil and audience_pub == pub,
         {:ok, %{verbs: verbs, scope: scope}} <-
           Commonplace.Trust.VerifyChain.verify_chain(cid, anchor_keys(cfg), store) do
      :define_verb in verbs and write_scope_covers?(scope, target_uuid, store)
    else
      _ -> false
    end
  end

  @doc """
  CX-fogy — the LOCAL-write commit gate's authorization WITH the safe-verb CODE
  fork (plan ruling #7537). The commit gate for a code-content write must FORK the
  required capability by RE-RUNNING the safe-verb AST-allowlist validator on the
  target's AFTER-STATE content:

    * non-code (data)                              -> `:write`
    * a valid SANDBOXED safe-verb (allowlist-clean, wrapper-shaped) -> `:define_verb`
    * raw / unparseable / unsafe code              -> `:execute`
      (Gate-B; node or explicit cert)

  The classifier IS the safety validator (the SAME `check_wrapped` `SafeVerb.compile`
  runs — no skew), so "classified safe" == "sandboxed by construction": a raw RCE
  payload cannot pass the facade-bound allowlist, so it is forced to `:execute` ->
  denied unless the signer has node authority or an explicit `:execute` cert. No
  cert carrying `:execute` had been minted before CX-b38c. FAIL-CLOSED: any
  error/uncertainty resolves to `:execute` (the highest bar). The four load-bearing
  conditions (plan #7537):
  (i) classify the AFTER-state, (ii) one shared validator commit+compile,
  (iii) fail-closed to :execute, (iv) Gate-B untouched for raw.

  LAYERING (plan #7548 — the (c)-refined core-move, DONE). The classifier runs the
  CORE, domain-agnostic `Commonplace.Code.Allowlist` (which owns the structural
  RCE-bans — kernel/stdlib tables, dynamic-dispatch/macro-surface/atom-construction
  rejections, closed-by-default) with a DATA profile (the MUD facade action-set +
  wrapper shape) injected at the composition root (`Commonplace.Application` →
  `:safe_verb_profile`). So Trust no longer references the MUD domain, and a MUD
  change can only ADD-within-safety (a facade allow-set), never weaken the core
  wall. FAIL-CLOSED: an absent/invalid profile → the write classifies `:execute`
  (node authority or explicit cert), never `:define_verb`. The classifier is
  isolated to `safe_verb_code?/1`.
  """
  @spec authorized_to_write?(Commit.t(), {:doc, String.t()}, config(), GenServer.server()) ::
          :ok | {:error, term()}
  def authorized_to_write?(%Commit{} = commit, {:doc, uuid} = scope, cfg, store) do
    case required_write_verb(commit, uuid, store) do
      # CX-fogy L3 (OPTION 2): a sandboxed safe-verb's :define_verb coverage is
      # anchored on its HOST (the room/object it's authored under, carried in
      # `metadata.verb_section`), NOT the verb doc's own fresh uuid — a bare-source
      # verb doc has no leaf zone-stamp (`own_zone` reads JSON `zone`; verb content
      # is Elixir source), so a self-scoped carve would never match. The host IS
      # zoned (rooms are M2-zoned), so the citizen's {:subtree,home}[:define_verb]
      # covers it. This CANNOT reuse `authorized?(commit, :define_verb, {:doc, host})`:
      # `subtree_carve_ok?` would apply THIS commit's update (which targets the verb
      # doc) to the HOST doc — the wrong doc. So `define_verb_authorized?` is a
      # COMMITLESS MEMBERSHIP check (mirrors the signer/cert resolution, but the
      # final test is cert-grants-:define_verb-over-host, no commit-carve). The
      # verb-doc↔host binding is cross-verified separately: the entry-add that links
      # the verb under the host's (now-zoned) `verbs/` dir is itself :write-carve-
      # gated on the host's zone, so a verb only ever DISPATCHES from a host the
      # author could legitimately write.
      :define_verb ->
        define_verb_authorized?(commit, Map.get(commit.metadata, :verb_section), cfg, store)

      verb ->
        authorized?(commit, verb, scope, cfg, store)
    end
  end

  # CX-fogy L3 — the COMMITLESS host-membership predicate for a safe-verb CODE
  # write (see `authorized_to_write?`). Mirrors `authorized?/5`'s signer/cert
  # resolution EXACTLY, but the terminal check is host-zone membership of the
  # verified cert's scope rather than a commit-applying carve (the commit targets
  # the verb doc, not the host). Fail-CLOSED: an un-signed/untrusted write with no
  # host, or a cert that does not grant :define_verb over the host's zone, is
  # DENIED — there is NO fall-through to `:write` (plan verify iii).
  defp define_verb_authorized?(%Commit{signature: nil}, _host, cfg, _store) do
    if cfg.accept_unsigned, do: :ok, else: {:error, :unsigned}
  end

  defp define_verb_authorized?(%Commit{} = commit, host_uuid, cfg, store) do
    case Signing.parse_signer_id(commit.signer_id || "") do
      {:ok, identity_uuid, _fingerprint} ->
        case Map.fetch(cfg.trusted_identities, identity_uuid) do
          # NODE / pinned root: authorized regardless of host (host may be nil for
          # a node-authored verb) — the node holds unattenuated authority, exactly
          # as in `authorized?/5`.
          {:ok, pinned} ->
            verify_against_pinned(commit, pinned)

          :error ->
            case Map.get(commit.metadata, :capability_proof) do
              nil ->
                if cfg.accept_unsigned,
                  do: :ok,
                  else: {:error, {:untrusted_signer, identity_uuid}}

              leaf_cid ->
                define_verb_capability_path(commit, host_uuid, leaf_cid, cfg, store)
            end
        end

      {:error, :invalid_signer_id} ->
        if cfg.accept_unsigned, do: :ok, else: {:error, :invalid_signer_id}
    end
  end

  # A citizen's cert grants this safe-verb write IFF (1) a host is actually
  # carried (fail-closed: no host → deny, never fall to :write), (2) the leaf cert
  # is addressed to the commit's signer key (the `author_binding` anti-theft
  # bind), (3) its chain verifies against the local anchors, and (4) the effective
  # cap grants :define_verb with a scope covering the HOST's own zone
  # (`write_scope_covers?` → `doc_zone(host) == root` for a {:subtree,root} cert).
  defp define_verb_capability_path(_commit, host_uuid, _leaf_cid, _cfg, _store)
       when not is_binary(host_uuid),
       do: {:error, :capability_insufficient}

  defp define_verb_capability_path(commit, host_uuid, leaf_cid, cfg, store) do
    with {:ok, leaf} <- fetch_cap(store, leaf_cid),
         :ok <- author_binding(commit, leaf),
         {:ok, %{verbs: verbs, scope: scope}} <-
           Commonplace.Trust.VerifyChain.verify_chain(leaf_cid, anchor_keys(cfg), store),
         true <- :define_verb in verbs and write_scope_covers?(scope, host_uuid, store) do
      :ok
    else
      {:error, _} = err -> err
      _ -> {:error, :capability_insufficient}
    end
  end

  defp required_write_verb(commit, uuid, store) do
    after_content = write_after_content(commit, uuid, store)

    cond do
      not is_binary(after_content) -> :write
      not Commonplace.Trust.CodeDocHeuristic.code_content?(after_content) -> :write
      safe_verb_code?(after_content) -> :define_verb
      true -> :execute
    end
  rescue
    _ -> :execute
  catch
    _, _ -> :execute
  end

  # Reconstruct the target's content AFTER applying this commit — plan condition (i)
  # (classify the RESULT, so a mutate-data-into-code write is re-checked). Mirrors
  # `subtree_carve_ok?`'s before+apply. `nil` on any non-content/unreadable target.
  defp write_after_content(commit, uuid, store) do
    before_d = before_doc(reconstruct_before(store, uuid))

    case Encoding.apply_update(before_d, commit.update) do
      {:ok, after_d} -> ContentType.get_content(after_d)
      _ -> nil
    end
  end

  # THE classifier == THE safety validator (plan #7537 crux). Returns true IFF the
  # content parses, is the substrate safe-verb wrapper shape, AND is allowlist-
  # clean — the same bar `SafeVerb.compile` runs. Anything else (raw code,
  # unparseable) is NOT safe.
  #
  # CX-fogy (c) — the RCE-ban wall now lives in the CORE, domain-agnostic
  # `Commonplace.Code.Allowlist`; Trust runs it with a DATA profile (the MUD's
  # facade action-set + wrapper shape) injected at the composition root
  # (`Commonplace.Application`) into `:safe_verb_profile`. So Trust no longer
  # references the MUD domain — the pre-(c) interim direct-ref is gone. FAIL-
  # CLOSED: an absent/invalid profile → `false` → the write classifies `:execute`
  # (node-only), never silently `:define_verb`.
  defp safe_verb_code?(content) do
    case Application.get_env(:commonplace, :safe_verb_profile) do
      %Commonplace.Code.Allowlist.Profile{} = profile ->
        Commonplace.Code.Allowlist.check_wrapped(content, profile) == :ok

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # The COMMITLESS membership predicate for the elevation pre-check
  # (`writer_authorized?`): does this verified scope cover a :write to
  # `target_uuid`? A {:docs} scope covers it iff the uuid is in the frozen
  # list (byte-identical to the prior behavior). A {:subtree, R} scope covers
  # it iff the target's carried zone-stamp == R (the walk-free membership read;
  # CX-4u03 / A1). Note this is the AUTHORITY question only (the A2 elevation
  # oracle) — the field-protection + code-doc invariants live in the
  # commit-path carve `subtree_carve_ok?`, which has the actual write to
  # inspect; there is no commit here to check. A {:presence} scope never
  # authorizes an object-state elevation (its own content-gate refuses
  # anything but the signer's presence entry), so it falls to `false`.
  defp write_scope_covers?({:docs, docs}, target_uuid, _store), do: target_uuid in docs

  defp write_scope_covers?({:subtree, root}, target_uuid, store),
    do: doc_zone(target_uuid, store) == root

  defp write_scope_covers?(_other, _target_uuid, _store), do: false

  # CX-4u03 / A1 — THE subtree write-carve (the security core, mirroring the
  # presence carve `presence_carve_ok?/4`). Authorizes a {:subtree, R} write to
  # `target_uuid` IFF all three hold, and fails CLOSED on any error (a security
  # gate must never fault-open — hence the rescue/catch wrapping the whole body):
  #
  #   (1) MEMBERSHIP (nod #1, self-containment): the target's carried, frozen,
  #       node-signed zone-stamp == R, read from the target's OWN governing meta
  #       — ONE deterministic DOWNWARD lookup (a dir reads its meta child's
  #       `zone`; a leaf/meta doc reads its own `zone`), never an ascent/walk, so
  #       it is a carried-attestation read (like a cert's carried scope), not a
  #       re-derivation from mutable tree structure. Absent/unreadable → DENY
  #       (nod #2b, fail-closed): an un-stamped doc is un-writable by a subtree
  #       cert (the node still owns it via the trusted-identity path).
  #   (2) STAMP PROTECTION (nod #2a): the write must not modify the `zone` field.
  #       Only the tree-mutation chokepoint (node-signed) sets/clears the stamp;
  #       a subtree cert authorizes the doc's game content, never its stamp (like
  #       the presence carve refuses a `bound_identity` MODIFY).
  #   (3) WRITE⊥EXECUTE (the #7228/#7233 belt): a :write-WITHOUT-:execute subtree
  #       cert may not author a CODE doc. Classify the POST-WRITE (after)
  #       reconstruction with the SHARED `CodeDocHeuristic` (so a data→code
  #       content-flip is caught, and the classifier can't skew from the mint
  #       scan / Gate-B); any uncertainty resolves to DENY via the fail-closed
  #       wrapper. Gate-B's node-signed=execute check is the STRUCTURAL suspenders
  #       behind this heuristic belt.
  defp subtree_carve_ok?(commit, root, target_uuid, verbs, store)
       when is_binary(root) and is_binary(target_uuid) do
    before = reconstruct_before(store, target_uuid)
    before_d = before_doc(before)

    with {:ok, after_d} <- Encoding.apply_update(before_d, commit.update),
         true <- governing_zone_of(before_d, store) == root,
         true <- zone_unchanged?(before_d, after_d),
         true <- not authoring_code?(verbs, after_d) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp subtree_carve_ok?(_commit, _root, _target_uuid, _verbs, _store), do: false

  @doc """
  CX-4u03 / A1 — the target doc's carried, node-signed zone-stamp (its subtree
  membership), or `nil` if absent/unreadable. THE single shared zone read: the
  commit-path carve, the elevation mirror, AND `Commonplace.MUD.SignedWrite`'s
  subtree-cert selection all derive membership from this one predicate (no
  classifier skew). ONE deterministic downward lookup (a dir reads its meta
  child's `zone`; a leaf/meta doc reads its own `zone`) — never an ascent/walk.
  Fails to `nil` on any error (fail-closed at every call site).
  """
  @spec doc_zone(String.t(), GenServer.server()) :: String.t() | nil
  def doc_zone(uuid, store \\ Commonplace.Store.CommitStoreClient) do
    case reconstruct_before(store, uuid) do
      {:ok, doc} -> governing_zone_of(doc, store)
      :none -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # The ONE deterministic downward stamp read (nod #1). A dir/schema doc keeps
  # its `entries` YMap clean, so its stamp lives in its meta CHILD; a leaf/meta
  # doc carries its own `zone`. Discriminate on the SAME `entries`-type tell the
  # presence carve uses. Never ascends to a parent.
  defp governing_zone_of(doc, store) do
    if Doc.has_type?(doc, "entries") do
      meta_child_zone(doc, store)
    else
      own_zone(doc)
    end
  end

  # Scan the dir's OWN entries for a `__*.json` meta child and read its `zone`.
  # Bounded to this dir's entries (a zoned dir has exactly one meta) — not a walk.
  defp meta_child_zone(schema_doc, store) do
    schema_doc
    |> Schema.list_entries()
    |> Enum.filter(fn %Schema.Entry{name: n} -> meta_file?(n) end)
    |> Enum.find_value(fn %Schema.Entry{node_id: id} ->
      case DocBuilder.reconstruct_doc(store, id) do
        {:ok, meta_doc} -> own_zone(meta_doc)
        _ -> nil
      end
    end)
  end

  defp meta_file?(name), do: Regex.match?(~r/^__.*\.json$/, name)

  # Read the `zone` field from a meta/leaf doc's own JSON content (nil if the
  # doc has no readable JSON content or no `zone` key — e.g. a bare schema doc,
  # or an un-stamped meta).
  defp own_zone(doc) do
    with content when is_binary(content) <- ContentType.get_content(doc),
         {:ok, map} when is_map(map) <- Jason.decode(content) do
      Map.get(map, "zone")
    else
      _ -> nil
    end
  end

  # nod #2a: the protected `zone` field must be byte-identical before/after. For
  # a dir target the zone lives in a different doc (the meta child), so both read
  # nil here and this trivially holds — the dir write can't touch the stamp.
  defp zone_unchanged?(before_d, after_d), do: own_zone(before_d) == own_zone(after_d)

  # The write⊥execute belt: a :write-without-:execute cert authoring code-doc
  # content (post-write) is refused. Shares `CodeDocHeuristic.code_content?/1`
  # with the mint scan and Gate-B (no classifier skew).
  defp authoring_code?(verbs, after_d) do
    :write in verbs and :execute not in verbs and
      Commonplace.Trust.CodeDocHeuristic.code_content?(ContentType.get_content(after_d))
  end

  @doc """
  CX-sqb6 (read-scoping P1): the COMMITLESS reader-authorization predicate —
  the `:read` mirror of `writer_authorized?/6`. Would a `:read` of
  `target_uuid` by the live principal `identity_uuid` (authenticated public
  key `pub`, presenting `cert_cids`) be authorized under `cfg`?

  A read has NO commit to sign, so — unlike the commit path's `author_binding`
  (which binds the leaf cert's audience to the COMMIT SIGNER) — the audience
  is bound to the **reader's own authenticated key** (`pub`): `cert_grants_read?`
  accepts a cert ONLY when its audience pubkey `== pub`. This is the
  anti-capability-theft guarantee: presenting a cert issued to SOMEONE ELSE's
  key (audience ≠ pub) never authorizes THIS reader.

  🔒 LOAD-BEARING CALL-SITE CONTRACT: `pub` MUST be the reader's
  SERVER-RESOLVED authenticated key (their `SigningContext`/session identity —
  the same unspoofable identity SessionLimit / possession-tokens use), NEVER a
  client-claimed value. If a caller passes an attacker-controlled `pub`, the
  audience binding is meaningless. Callers pass the session-resolved identity.

  Mirrors the write path's short-circuits exactly: `accept_unsigned`
  (permissive) → true; a `trusted_identities`-pinned identity → true;
  otherwise a held, chain-verified, unrevoked `:read` cap over `target_uuid`.
  Revocation (CX-bepn) is enforced inside `verify_chain`, verify-time.
  """
  @spec reader_authorized?(
          String.t() | nil,
          binary() | nil,
          [binary()],
          String.t(),
          config(),
          GenServer.server()
        ) :: boolean()
  def reader_authorized?(identity_uuid, pub, cert_cids, target_uuid, cfg, store) do
    cond do
      cfg.accept_unsigned -> true
      not is_binary(identity_uuid) -> false
      Map.has_key?(cfg.trusted_identities, identity_uuid) -> true
      true -> Enum.any?(cert_cids, &cert_grants_read?(&1, pub, target_uuid, cfg, store))
    end
  end

  # The `:read` mirror of `cert_grants_write?/5`. The audience-binding
  # (`audience_pub == pub`) binds the cap to the READER's key — a cert for
  # another audience can't authorize this reader (no capability theft).
  defp cert_grants_read?(cid, pub, target_uuid, cfg, store) do
    with {:ok, leaf} <- fetch_cap(store, cid),
         {_uuid, audience_pub} <- leaf.audience,
         true <- pub != nil and audience_pub == pub,
         {:ok, %{verbs: verbs, scope: scope}} <-
           Commonplace.Trust.VerifyChain.verify_chain(cid, anchor_keys(cfg), store) do
      :read in verbs and
        case scope do
          {:docs, docs} -> target_uuid in docs
          {:subtree, root} -> doc_zone(target_uuid, store) == root
          _other -> false
        end
    else
      _ -> false
    end
  end

  # Phase-3 capability path (CX-tdkq.22d). The chain authorizes the
  # commit only if (1) the commit was signed by the LEAF cert's audience
  # key — the ⭐ commit-author binding that prevents attaching someone
  # else's public chain (capability theft) — (2) the chain verifies
  # against the locally-anchored root keys, and (3) the effective
  # capability grants the requested {verb, scope}.
  defp capability_path(commit, verb, scope, leaf_cid, cfg, store) do
    with {:ok, leaf} <- fetch_cap(store, leaf_cid),
         :ok <- author_binding(commit, leaf),
         {:ok, effective} <-
           Commonplace.Trust.VerifyChain.verify_chain(leaf_cid, anchor_keys(cfg), store),
         :ok <- grants?(effective, verb, scope, commit, store) do
      :ok
    end
  end

  defp fetch_cap(store, cid) do
    case Commonplace.Store.CommitStoreClient.get_capability(store, cid) do
      {:ok, cap} -> {:ok, cap}
      :none -> {:error, :awaiting_capability}
    end
  end

  defp author_binding(commit, %{audience: {_uuid, audience_pub}}) do
    case Signing.verify_commit(commit, audience_pub) do
      :ok -> :ok
      {:error, _} -> {:error, :capability_author_mismatch}
    end
  end

  defp grants?(%{verbs: verbs, scope: {:docs, docs}}, verb, {:doc, uuid}, _commit, _store) do
    if verb in verbs and uuid in docs, do: :ok, else: {:error, :capability_insufficient}
  end

  # CX-4u03 / A1 (subtree-scope): a {:subtree, R} capability grants `verb` at a
  # target doc ONLY if the content-aware carve `subtree_carve_ok?/5` confirms
  # (i) the target's carried, node-signed zone-stamp == R (membership, read from
  # the target's own governing meta — never a live tree-walk), (ii) the write
  # does NOT tamper the protected `zone` field, and (iii) a write-without-execute
  # subtree cert isn't authoring a code doc (the write⊥execute belt). `commit`
  # and `store` are threaded so the carve can reconstruct/inspect the target.
  defp grants?(%{verbs: verbs, scope: {:subtree, root}}, verb, {:doc, uuid}, commit, store) do
    if verb in verbs and subtree_carve_ok?(commit, root, uuid, verbs, store),
      do: :ok,
      else: {:error, :capability_insufficient}
  end

  # CX-0a9a (presence-carve, W3 plumbing): a {:presence, identity_uuid}
  # capability grants `verb` at a target doc ONLY if the content-check
  # `presence_carve_ok?/4` (the untrusted-@verb-style live gate,
  # implemented separately — see its stub below) confirms the write is
  # this identity's OWN presence entry. `commit` and `store` are threaded
  # through so that check can reconstruct/inspect the target doc.
  defp grants?(%{verbs: verbs, scope: {:presence, id}}, verb, {:doc, uuid}, commit, store) do
    if verb in verbs and presence_carve_ok?(commit, id, uuid, store),
      do: :ok,
      else: {:error, :capability_insufficient}
  end

  # W3 (CX-0a9a) — the presence-carve CONTENT-CHECK. THE SECURITY CORE.
  #
  # Authorizes this :write to `target_uuid` IFF it touches ONLY the
  # writer's OWN presence, where "own" = the presence doc's
  # `bound_identity` field == `identity_uuid` (the {:presence, id} cert's
  # subject; `author_binding/2` already proved the commit was signed by
  # that identity's key). Complete via a VALUE set-diff over the
  # reconstructed before/after state — the nothing-else firewall, never
  # sampled. Fails CLOSED on any error (a security gate must never
  # fault-open), which is why the whole body is wrapped rescue/catch.
  defp presence_carve_ok?(commit, identity_uuid, target_uuid, store)
       when is_binary(identity_uuid) and is_binary(target_uuid) do
    before = reconstruct_before(store, target_uuid)

    with {:ok, after_doc} <- Encoding.apply_update(before_doc(before), commit.update) do
      case carve_branch(before) do
        :schema ->
          schema_carve_ok?(before_doc(before), after_doc, identity_uuid, store)

        :presence ->
          presence_doc_carve_ok?(before_doc(before), after_doc, identity_uuid)

        # Fresh doc (no prior commits) — a create. Gated by the same
        # presence-doc check, which requires the new doc to be
        # EXCLUSIVELY a valid own-presence (bound == signer AND no
        # bundled "entries" type), so a create can't shape-confuse by
        # bundling presence content + a fake schema type in one write.
        :none ->
          presence_doc_carve_ok?(Doc.new(), after_doc, identity_uuid)
      end
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp presence_carve_ok?(_commit, _identity_uuid, _target_uuid, _store), do: false

  defp reconstruct_before(store, uuid) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} -> {:ok, doc}
      _ -> :none
    end
  end

  defp before_doc({:ok, doc}), do: doc
  defp before_doc(:none), do: Doc.new()

  # Discriminate on the ESTABLISHED (before) type, never the after-doc: a
  # presence-cert write to an existing presence doc stays a presence write
  # even if the update smuggles in an "entries" type (which would
  # otherwise flip it to the schema branch and skip the bound_identity
  # check — a real bypass, closed here). A fresh doc has no established
  # type → :none.
  defp carve_branch(:none), do: :none

  defp carve_branch({:ok, doc}),
    do: if(Doc.has_type?(doc, "entries"), do: :schema, else: :presence)

  # --- schema branch: target is a room-dir schema (add/remove of a presence entry) ---
  # VALUE-diff entries; EVERY changed key must be a pure add XOR remove of
  # a presence-honorific entry whose presence doc is bound to
  # identity_uuid. A modify (re-point / type-change of an existing entry)
  # is never a valid presence op → refuse the whole write. A paired move
  # is two separate commits (source-remove, dest-add), each touching one
  # dir's own presence entry only — each passes individually.
  defp schema_carve_ok?(before_doc, after_doc, identity_uuid, store) do
    b = entry_map(before_doc)
    a = entry_map(after_doc)

    b
    |> Map.keys()
    |> Enum.concat(Map.keys(a))
    |> Enum.uniq()
    |> Enum.all?(fn name ->
      case {Map.get(b, name), Map.get(a, name)} do
        {same, same} -> true
        {nil, {_type, node_id}} -> presence_entry_owned?(name, node_id, identity_uuid, store)
        {{_type, node_id}, nil} -> presence_entry_owned?(name, node_id, identity_uuid, store)
        {_from, _to} -> false
      end
    end)
  end

  defp entry_map(doc) do
    doc
    |> Schema.list_entries()
    |> Map.new(fn %Schema.Entry{name: n, type: t, node_id: id} -> {n, {t, id}} end)
  end

  # The changed schema key must be a presence file (honorific extension —
  # so a room/object entry can't slip in) AND the doc it points to must be
  # bound to identity_uuid. bound_identity is THE cryptographic anchor;
  # the honorific check is belt-and-braces defense-in-depth.
  defp presence_entry_owned?(name, node_id, identity_uuid, store) do
    presence_honorific?(name) and doc_bound_to?(node_id, identity_uuid, store)
  end

  defp presence_honorific?(name) do
    match?({:ok, _root, _type}, Commonplace.Presence.parse_honorific(name))
  end

  defp doc_bound_to?(node_id, identity_uuid, store) do
    case DocBuilder.reconstruct_doc(store, node_id) do
      {:ok, doc} -> presence_field(doc, "bound_identity") == identity_uuid
      _ -> false
    end
  end

  # --- presence branch: target is the presence doc itself ---
  # A presence doc must NEVER gain an "entries" (schema) type — that would
  # flip its established before-type on a LATER write and reroute it to the
  # schema branch (deferred shape-confusion). Enforcing it here keeps a
  # presence doc's classification stable forever. Then: after.bound_identity
  # == signer AND before.bound_identity ∈ {nil, signer} — blocks both
  # binding-to-another-identity (create) and rebinding an existing presence
  # doc to hijack it (Sharpening 2's immutability). Other fields
  # (name/status/heartbeat/…) are advisory (D2) and unrestricted.
  defp presence_doc_carve_ok?(before_doc, after_doc, identity_uuid) do
    after_bid = presence_field(after_doc, "bound_identity")
    before_bid = presence_field(before_doc, "bound_identity")

    not Doc.has_type?(after_doc, "entries") and
      after_bid == identity_uuid and
      before_bid in [nil, identity_uuid]
  end

  defp presence_field(doc, key) do
    case ContentType.get_content(doc) do
      %{} = content -> Map.get(content, key)
      _ -> nil
    end
  end

  @doc """
  Build the locally-pinned cert-chain root anchors for a resolved trust config.

  An absent node public-key artifact contributes no node keys, preserving the
  configured-anchor fallback. A present artifact that cannot be read or decoded
  is operationally distinct: verification still degrades to the configured
  anchors, but the loss is logged so a resulting denial cannot look like an
  ordinary policy decision.
  """
  @spec anchor_keys(config()) :: MapSet.t(binary())
  def anchor_keys(cfg) do
    configured_keys =
      cfg.trusted_identities
      |> Map.values()
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.flat_map(fn encoded ->
        case Signing.decode_key(encoded) do
          {:ok, key} -> [key]
          {:error, _} -> []
        end
      end)

    public_node_keys =
      case Commonplace.Crypto.NodeIdentity.public_keys() do
        {:ok, keys} ->
          keys

        :absent ->
          []

        {:error, reason} ->
          Logger.error(
            "node signing public-key artifact is present but unreadable " <>
              "(#{inspect(reason)}) — DEGRADING to configured trust anchors"
          )

          []
      end

    MapSet.new(configured_keys ++ public_node_keys)
  end

  # A trusted identity's signature must verify against one of its pinned
  # keys — in BOTH modes (see moduledoc decision table).
  defp verify_against_pinned(commit, pinned) do
    keys = List.wrap(pinned)

    verified =
      Enum.any?(keys, fn encoded ->
        case Signing.decode_key(encoded) do
          {:ok, key} -> Signing.verify_commit(commit, key) == :ok
          {:error, _} -> false
        end
      end)

    if verified, do: :ok, else: {:error, :invalid_signature}
  end

  @doc """
  Is every commit contributing to this doc's state authorized for
  `:execute`? The Gate B check (CX-tdkq.2 / R2, hardened in CX-tdkq.27).

  Walks the doc's commit chain newest-first and checks each commit with
  `authorized?(commit, :execute, {:doc, uuid})`. Checking only the head
  would be unsound — write-time laundering: the edit flow re-encodes FULL
  doc state, so a trusted editor's head commit physically contains every
  earlier contributor's surviving bytes (design doc §2 Gate B). Every
  contributor since the baseline must hold `:execute`.

  ## Snapshots: continue-default + local watermark cache (CX-tdkq.27)

  A node-signed snapshot is a *contributor* whose signer holds `:execute`
  (the node, via verb-agnostic auto-trust) — but that does NOT mean the
  history it collapsed was execute-clean. A naive "halt at the first
  authorized snapshot" therefore launders un-`:execute`-authorized
  contributions into an execute-terminal baseline. The store is
  **append-only** (pre-snapshot history is never GC'd), so the sound fix is
  to **continue** past a snapshot whose cleanliness we don't already know
  and re-check the still-present absorbed history — which catches the
  laundered contributor without bricking legacy snapshots (their pre-fix
  history is execute-clean).

  The continue-default is correct on its own; a **node-local watermark
  cache** (`CommitStore.get/put_execute_clean`, keyed by a fingerprint of
  the trust config) is layered on top purely as an optimization: a snapshot
  cached `true` halts the walk early (and bounds the `commit_log` 10k-limit
  risk). The verdict is **node-subjective** (config-relative), so it is
  *never* placed in the synced commit — that would dent the phase-2.5
  deterministic-snapshot / CAS-dedup property. Keying on the config
  fingerprint means a trust-config change (e.g. a revocation) self-
  invalidates stale verdicts: the next walk recomputes under the new config.

  The walk backfills as a side effect: every snapshot it *continued past*
  is cached `true` if the walk ended `:ok` (all-below clean) or `false` if
  it ended `:error`. Writes are fire-and-forget casts, so the compile hot
  path never blocks on cache I/O.

  ## Genesis and merges

  The **genesis** commit is exempt and terminal (synthetic, empty update).
  The walk follows `parent_id` only — a **merge** commit's `merge_parents`
  side (the absorbed bytes of whatever it folded in) is never visited.

  That omission is closed for code docs by CX-obfb's
  no-delta-merge-on-code-docs enforcement rather than by teaching this
  walk to traverse `merge_parents`: a delta-merge (non-empty
  `merge_parents`, or a MergeSnapshotter two-parent
  `metadata.snapshot_parents`) is refused at every seam that could land
  one on a code doc — `CommitStore.import_commit/3`
  (`Commonplace.Trust.CodeDocHeuristic.code_doc?/2` gate),
  `Commonplace.SiblingMerger.maybe_merge_siblings/3` (skips instead of
  auto-merging), and `Commonplace.Store.Merger.merge/4` (refuses both
  `:translate` and `:merge_snapshot`). A code doc therefore never
  acquires a merge_parents side-line in the first place, so its
  `parent_id`-only chain is exactly its full contributor history and this
  walk is sound for it. Convergence for a code doc instead happens by
  re-authorship: an `:execute`-authorized signer mints a regular
  full-state commit with the merged content.

  Non-code docs are unaffected — Gate B does not apply to them, so they
  continue to merge freely via any strategy.

  The classifier is still best-effort content-sniffing and a doc that
  can't be reconstructed locally (or doesn't content-sniff as code)
  classifies `false` — a residual miss on that classifier is covered by
  the mint-time guard (CX-tdkq.28) for the write-without-`:execute`
  input path; broadening the classifier's reach is tracked separately
  (CX-6g0j).

  An empty chain returns `:ok` — there is nothing to execute, and the
  caller's read fails with `:not_found` on its own.

  ## Paging (CX-klpi held half)

  The walk no longer fetches a single capped page — it PAGES through the
  full commit chain via `CommitStoreClient.commit_log/3` +
  `commit_log_from/3`, `page_size` at a time (default
  `CommitStore.max_commit_log_limit/0`, overridable via `opts[:page_size]`
  for tests). A clean full walk backfills the execute-clean snapshot
  cache (see above), so SUBSEQUENT walks against the same doc halt near
  head on the cached snapshot — paging past the cap is the exceptional
  first-walk/cold-cache cost, not a steady-state one. `opts[:page_size]`
  aside, this changes nothing about the verdict logic itself, only how
  much of the chain a single walk is willing to fetch. The walk is also
  bounded by a TOTAL ceiling across all pages
  (`Application.get_env(:commonplace, :max_authorization_walk_commits,
  200_000)`) — a guard against a runaway/adversarial chain, not an
  expected cost; see `{:authorization_chain_too_long, n}` below.

  Two new failure modes fall out of paging:

    * `{:error, {:authorization_chain_incomplete, commit_id}}` — a page
      came back short of `page_size` but the last commit in it is
      neither `kind: :genesis` nor parent-less: the chain visibly
      continues (a non-nil `parent_id`) but the store doesn't have the
      next commit. That's a genuinely broken/incomplete chain, not mere
      length, and it fails closed.
    * `{:error, {:authorization_chain_too_long, n}}` — the total ceiling
      above was exceeded before the walk halted.

  Neither replaces the CX-klpi mechanical half's truncation warning,
  which is REMOVED here: paging makes silent truncation impossible (a
  long-but-intact chain now costs extra page fetches instead of being
  quietly cut short), so there is nothing left to warn about.
  """
  @spec authorized_to_execute?(GenServer.server(), String.t(), config() | nil, keyword()) ::
          :ok | {:error, term()}
  def authorized_to_execute?(store, doc_uuid, cfg \\ nil, opts \\ []) do
    cfg = cfg || config()

    if cfg.accept_unsigned and cfg.trusted_identities == %{} do
      # Fully-permissive config: no commit can fail (unsigned passes,
      # unknown signers pass, and with no pinned keys there is no
      # forgery case) — skip the chain walk (and any cache I/O) so the
      # default config keeps compile O(cache-hit) on hot paths.
      :ok
    else
      page_size =
        Keyword.get(opts, :page_size, Commonplace.Store.CommitStore.max_commit_log_limit())

      total_ceiling = Application.get_env(:commonplace, :max_authorization_walk_commits, 200_000)
      fp = cfg_fingerprint(cfg, store)

      first_page =
        Commonplace.Store.CommitStoreClient.commit_log(store, doc_uuid, limit: page_size)

      walk_pages(store, doc_uuid, cfg, fp, first_page, nil, page_size, total_ceiling, 0, 1, [])
    end
  end

  # Cache key namespace: the verdict is only valid for the trust config AND
  # the revocation state that produced it, so either changing invalidates
  # it for free.
  #
  # CX-bepn (design §4, "the watermark catch"): folding in
  # `revocation_set_hash(store)` is REQUIRED, not decorative — without it
  # a revocation changes effective authority (VerifyChain now denies a
  # revoked cert's chain) WITHOUT touching `trusted_identities`, so a
  # verdict cached BEFORE the revocation would keep honoring the revoked
  # cert at Gate B indefinitely. The hash is read PER-STORE (through the
  # threaded `store`, never a bare default read — same store-threading
  # rule as everywhere else revocation state is touched) so a revocation
  # written to store A never invalidates store B's cache and vice versa.
  # One extra get per walk, amortized over every cached verdict it
  # protects.
  defp cfg_fingerprint(cfg, store) do
    :erlang.phash2(
      {cfg.trusted_identities, Commonplace.Store.CommitStoreClient.revocation_set_hash(store)}
    )
  end

  # CX-klpi held half: the paged contributor walk. `page` is the current
  # page's commits (newest-first); `prev_last` is the last commit of the
  # PREVIOUS page (nil on the first page) — needed so an empty page can
  # tell "genuinely no more chain" (prev_last was parent-less, impossible
  # to reach here — see below) apart from "the chain visibly continues
  # but the next commit is missing" (prev_last had a non-nil parent_id
  # yet the store had nothing at that id).
  defp walk_pages(
         store,
         doc_uuid,
         cfg,
         fp,
         page,
         prev_last,
         page_size,
         total_ceiling,
         examined,
         page_number,
         passed
       ) do
    examined_after = examined + length(page)

    cond do
      examined_after > total_ceiling ->
        Logger.error(
          "Trust.authorized_to_execute?: authorization walk for doc #{doc_uuid} exceeded the " <>
            "#{total_ceiling}-commit total ceiling (CX-klpi) after #{page_number} page(s) — " <>
            "treating as a runaway/adversarial chain"
        )

        {:error, {:authorization_chain_too_long, examined_after}}

      page == [] and prev_last == nil ->
        # No commits at all — the pre-existing "empty chain -> :ok"
        # convention (nothing to execute; caller's read fails with
        # :not_found on its own).
        finish_walk(store, fp, :ok, passed)

      page == [] ->
        # prev_last's chain visibly continued (non-nil parent_id, not
        # genesis — both would have halted the previous page's process)
        # but this page fetch came back with nothing: the store is
        # missing prev_last's parent commit.
        Logger.error(
          "Trust.authorized_to_execute?: incomplete commit chain for doc #{doc_uuid} — " <>
            "commit #{prev_last.id} names parent #{prev_last.parent_id}, which the " <>
            "store does not have (CX-klpi)"
        )

        {:error, {:authorization_chain_incomplete, prev_last.id}}

      true ->
        case process_execute_page(page, doc_uuid, cfg, store, fp, passed) do
          list when is_list(list) ->
            last_commit = List.last(page)

            cond do
              last_commit.parent_id == nil ->
                # Sound chain end: legacy pre-umbrella nil-parent doc
                # (genesis-kind commits already halt inside
                # process_execute_page and never reach here).
                finish_walk(store, fp, :ok, list)

              length(page) < page_size ->
                # Short page, but the last commit's chain visibly
                # continues — the store is missing its parent.
                Logger.error(
                  "Trust.authorized_to_execute?: incomplete commit chain for doc #{doc_uuid} — " <>
                    "commit #{last_commit.id} names parent #{last_commit.parent_id}, which the " <>
                    "store does not have (CX-klpi)"
                )

                {:error, {:authorization_chain_incomplete, last_commit.id}}

              true ->
                :telemetry.execute(
                  [:commonplace, :trust, :authorization_walk_paged],
                  %{page: page_number + 1, examined: examined_after},
                  %{uuid: doc_uuid, commit_id: last_commit.parent_id}
                )

                next_page =
                  Commonplace.Store.CommitStoreClient.commit_log_from(
                    store,
                    last_commit.parent_id,
                    limit: page_size
                  )

                walk_pages(
                  store,
                  doc_uuid,
                  cfg,
                  fp,
                  next_page,
                  last_commit,
                  page_size,
                  total_ceiling,
                  examined_after,
                  page_number + 1,
                  list
                )
            end

          {verdict, passed_final} ->
            finish_walk(store, fp, verdict, passed_final)
        end
    end
  end

  # Processes one page of the Gate B contributor walk. Returns the
  # updated `passed` list (plain list) if the page was consumed without
  # reaching a verdict, or `{verdict, passed}` if it halted.
  defp process_execute_page(page, doc_uuid, cfg, store, fp, passed) do
    Enum.reduce_while(page, passed, fn commit, passed ->
      cond do
        match?(%{metadata: %{kind: :genesis}}, commit) ->
          {:halt, {:ok, passed}}

        true ->
          case authorized?(commit, :execute, {:doc, doc_uuid}, cfg, store) do
            {:error, reason} ->
              {:halt, {{:error, {:untrusted_contributor, commit.id, reason}}, passed}}

            :ok ->
              if match?(%{metadata: %{kind: :snapshot}}, commit) do
                case Commonplace.Store.CommitStoreClient.get_execute_clean(store, fp, commit.id) do
                  {:ok, true} -> {:halt, {:ok, passed}}
                  _ -> {:cont, [commit.id | passed]}
                end
              else
                {:cont, passed}
              end
          end
      end
    end)
  end

  defp finish_walk(store, fp, verdict, passed) do
    clean? = verdict == :ok

    Enum.each(
      passed,
      &Commonplace.Store.CommitStoreClient.put_execute_clean(store, fp, &1, clean?)
    )

    verdict
  end

  @doc """
  Resolve the workspace trust config: application env `:commonplace,
  :trust` → `<data_dir>/trust.json` → `default_config/0`.
  """
  @spec config() :: config()
  def config do
    base =
      case Application.get_env(:commonplace, :trust) do
        %{} = cfg ->
          normalize(cfg)

        nil ->
          # CX-tdkq.12 Task 0 (O6): fail CLOSED, never open. An ABSENT
          # trust.json is the intended zero-config permissive default.
          # A PRESENT-but-unreadable/unparseable one means the operator
          # configured trust and we can no longer tell what it said —
          # the safe reading is "trust nothing" (reject-all), loudly.
          # Silently degrading a strict workspace to permissive would
          # turn a corrupt file into auto-RCE under an on-boot
          # orchestrator.
          case config_from_file() do
            {:ok, cfg} ->
              cfg

            :absent ->
              default_config()

            {:error, reason} ->
              Logger.error(
                "trust.json is present but unreadable/unparseable (#{inspect(reason)}) — " <>
                  "FAILING CLOSED: rejecting all non-node-signed commits until the file is fixed or removed"
              )

              %{accept_unsigned: false, trusted_identities: %{}}
          end
      end

    with_local_node_trust(base)
  end

  # Phase 2.5 (CX-tdkq.24): the local node always trusts its OWN
  # system-minted commits — its signing key is local-only and a peer
  # cannot forge it, so this is anchored in local config (the node
  # keypair file), exactly the §4 anchor model. Folding the node
  # identity→pubkey into the trusted set means a single-node strict
  # workspace accepts node-signed snapshots/merges with zero pinning.
  # Best-effort: if the node identity or public keys can't be sourced,
  # log the specific degradation and leave the set unchanged. The node's
  # commits will then fail strict checks, but startup remains available.
  defp with_local_node_trust(cfg) do
    with {:identity, {:ok, identity}} <-
           {:identity, Commonplace.Crypto.NodeIdentity.identity()},
         {:public_keys, {:ok, [_ | _] = public_keys}} <-
           {:public_keys, Commonplace.Crypto.NodeIdentity.public_keys()} do
      encoded_keys = Enum.map(public_keys, &Signing.encode_key/1)
      trusted = Map.put_new(cfg.trusted_identities, identity, encoded_keys)
      %{cfg | trusted_identities: trusted}
    else
      {:identity, {:error, reason}} ->
        Logger.error(
          "local node self-trust was not added: node identity could not be sourced " <>
            "(#{inspect(reason)}) — continuing with configured trusted identities"
        )

        cfg

      {:public_keys, :absent} ->
        Logger.error(
          "local node self-trust was not added: node signing public-key artifact is absent — " <>
            "continuing with configured trusted identities"
        )

        cfg

      {:public_keys, {:error, reason}} ->
        Logger.error(
          "local node self-trust was not added: node signing public-key artifact is present " <>
            "but unreadable (#{inspect(reason)}) — continuing with configured trusted identities"
        )

        cfg

      {:public_keys, {:ok, []}} ->
        Logger.error(
          "local node self-trust was not added: node signing public-key artifact declares zero " <>
            "keys — continuing with configured trusted identities"
        )

        cfg

      {source, result} ->
        Logger.error(
          "local node self-trust was not added: #{source} returned an unexpected result " <>
            "(#{inspect(result)}) — continuing with configured trusted identities"
        )

        cfg
    end
  end

  @doc "The default (permissive, empty allowlist) trust config."
  @spec default_config() :: config()
  def default_config do
    %{accept_unsigned: true, trusted_identities: %{}}
  end

  @local_write_gate_values [:off, :dry_run, :enforce]

  @doc """
  Resolve the local-write gate at its single policy site.

  Absence is the observe posture (`:dry_run`). Runtime configuration keeps
  OS-environment input as a string so this function can map only the three
  declared values without minting atoms. Any other explicit value is a boot
  configuration error and raises the named refusal.
  """
  @spec local_write_gate() :: :off | :dry_run | :enforce
  def local_write_gate, do: local_write_gate_resolution().value

  @doc false
  @spec local_write_gate_resolution() :: %{
          value: :off | :dry_run | :enforce,
          source: :absent_defaulted | :env_set
        }
  def local_write_gate_resolution do
    case Application.get_env(:commonplace, :local_write_gate) do
      nil ->
        %{value: :dry_run, source: :absent_defaulted}

      value when value in @local_write_gate_values ->
        %{value: value, source: :env_set}

      "off" ->
        %{value: :off, source: :env_set}

      "dry_run" ->
        %{value: :dry_run, source: :env_set}

      "enforce" ->
        %{value: :enforce, source: :env_set}

      invalid ->
        raise ArgumentError,
              "Commonplace.Trust local_write_gate refusal: invalid value " <>
                "#{inspect(invalid)}; valid values: off | dry_run | enforce"
    end
  end

  @capture_count_fields [
    :emitted,
    :offered,
    :recorded,
    :shed,
    :failed,
    :guarded,
    :queued,
    :in_flight,
    :upstream_loss,
    :pre_dispatcher_emitted
  ]

  @doc """
  Report denial-audit capture for this BEAM boot.

  `emitted` is incremented synchronously by the local-write denial decision
  site. `offered` and the remaining buckets come from the dispatcher, making
  `upstream_loss = emitted - offered` the count lost before dispatch. Every
  returned figure shares the returned `boot_id`; a dispatcher from a different
  boot is rejected rather than compared.

  Pass `dispatcher: server` for an injected dispatcher. Pass a prior result as
  `since: snapshot` to obtain a boot-scoped interval while retaining the same
  identity and enclosure.
  """
  @spec capture_rate(keyword()) :: map()
  def capture_rate(opts \\ []) when is_list(opts) do
    dispatcher = Keyword.get(opts, :dispatcher, Commonplace.Trust.AuditDispatcher)
    # Injectable module so a test can present a status/0 of the shape an OLDER
    # build returns — which is the case the refusal above exists for.
    dispatcher_mod = Keyword.get(opts, :dispatcher_mod, Commonplace.Trust.AuditDispatcher)

    case dispatcher_mod.status(dispatcher) do
      %{error: _} = error ->
        Map.put(error, :boot_id, Commonplace.Trust.DenialCounter.boot_id())

      %{boot_id: dispatcher_boot_id} = status ->
        %{boot_id: counter_boot_id, emitted: emitted} =
          Commonplace.Trust.DenialCounter.snapshot()

        if dispatcher_boot_id == counter_boot_id do
          # CX-m0qw review: `emitted` is per-BEAM-boot (:persistent_term) while
          # the dispatcher's buckets reset when IT restarts. Charging the
          # difference to upstream_loss would report every pre-restart denial
          # as fresh loss — a false alarm that BALANCES, and so is
          # indistinguishable from the real thing. Split the two.
          # ⛔ REFUSE, DO NOT DEFAULT. `Map.get(status, :emitted_at_start, 0)`
          # would silently treat a dispatcher that does not REPORT the field as
          # one that started with ZERO prior denials — and the identity
          # `emitted == pre + offered + upstream_loss` STILL BALANCES, so the
          # inflated `upstream_loss` is indistinguishable from a real one.
          #
          # That is the same defect this function was written to remove (a
          # false alarm that satisfies its own consistency check), reintroduced
          # by its own fix through a defaulting read. A 0 that cannot
          # distinguish "no prior denials" from "no such field" is a `nil` that
          # cannot distinguish "dropped" from "never asked".
          #
          # ⚠️ It is reachable: the RUNNING serve predates this instrument, so
          # its `status/0` has no `:emitted_at_start` (CX-y4bq — the live build
          # is 35 tickets behind main). An answer of 0 there would read as "no
          # upstream loss" when the truth is "no instrument".
          # ⛔ THE POPULATIONS DO NOT MATCH, SO WE DO NOT DIVIDE THEM.
          #
          # `emitted` is incremented at the local-write denial DECISION site
          # (commit_store.ex:2348,2366) — two call sites, one event type.
          # `offered` is incremented by the dispatcher for EVERY audited event
          # — AuditLog's @events lists NINE. So `emitted - offered` subtracts a
          # SUPERSET from a SUBSET and goes negative the moment any non-
          # local_write denial occurs. Observed live within a minute of deploy:
          # emitted 3, offered 4, upstream_loss -1, capture_rate 1.33.
          #
          # ⚠️ Every test passed because the fixtures only ever drove
          # local_write denials, so the two populations were IDENTICAL BY
          # CONSTRUCTION in every test. A same-population assumption is
          # invisible when the fixtures produce only one population.
          #
          # ⭐ Until the counter is widened to cover all nine event types
          # (the real fix — it must stay at the DECISION sites, because that
          # is what makes it survive handler detachment), this function
          # REFUSES rather than reporting a number whose two halves count
          # different things. Same discipline as the pre-instrument refusal
          # below: a figure that cannot be computed honestly is not reported.
          case Map.fetch(status, :emitted_at_start) do
            :error ->
              %{
                error: :dispatcher_predates_instrument,
                boot_id: counter_boot_id,
                emitted: emitted
              }

            {:ok, pre_dispatcher_emitted} ->
              report =
                build_capture_report(
                  status,
                  counter_boot_id,
                  emitted,
                  pre_dispatcher_emitted,
                  opts
                )

              # Cross-population guard: a negative loss or a rate above 1 is
              # arithmetically impossible for a real capture rate, so its
              # appearance means the two counters are drawn from different
              # populations. Report the raw counts and refuse the ratio.
              if is_integer(report[:upstream_loss]) and report[:upstream_loss] < 0 do
                report
                |> Map.drop([:upstream_loss, :capture_rate])
                |> Map.put(:error, :cross_population_counters)
                |> Map.put(
                  :note,
                  "emitted counts local_write denials only; offered counts all audited events"
                )
              else
                report
              end
          end
        else
          %{
            error: :boot_id_mismatch,
            boot_id: counter_boot_id,
            dispatcher_boot_id: dispatcher_boot_id
          }
        end
    end
  end

  defp build_capture_report(status, counter_boot_id, emitted, pre_dispatcher_emitted, opts) do
    status
    |> Map.take([:offered, :recorded, :shed, :failed, :guarded, :queued, :in_flight])
    |> Map.merge(%{
      boot_id: counter_boot_id,
      emitted: emitted,
      pre_dispatcher_emitted: pre_dispatcher_emitted,
      upstream_loss: emitted - pre_dispatcher_emitted - status.offered
    })
    |> capture_interval(Keyword.get(opts, :since))
    |> put_capture_rate()
  end

  defp capture_interval(current, nil), do: current

  defp capture_interval(%{boot_id: boot_id} = current, %{boot_id: boot_id} = baseline) do
    Enum.reduce(@capture_count_fields, %{boot_id: boot_id}, fn field, acc ->
      Map.put(acc, field, Map.fetch!(current, field) - Map.fetch!(baseline, field))
    end)
  end

  defp capture_interval(%{boot_id: boot_id}, %{boot_id: baseline_boot_id}) do
    %{error: :baseline_boot_id_mismatch, boot_id: boot_id, baseline_boot_id: baseline_boot_id}
  end

  # CX-m0qw review: 0/0 is neither 100% nor 0%. Reporting 1.0 for a window
  # with no denials is the same lie CX-1n8y removed from the mixed-plane
  # scanner (`coverage_percent(_scanned, 0, false) -> :not_applicable`), and
  # it is worse here: "capture_rate: 1.0" on an idle boot is exactly the
  # reassuring green this ticket exists because someone believed.
  # ...AND THE DENOMINATOR IS THIS DISPATCHER'S WINDOW, NOT THE BOOT'S.
  # `recorded / emitted` would score a freshly restarted dispatcher 0.0
  # because the boot's earlier denials predate it — the same false alarm as
  # the upstream_loss one, one field over, introduced by the fix for it.
  # (Fourth instance this week of a remedy carrying the defect it removes.)
  defp put_capture_rate(%{emitted: emitted, recorded: recorded} = report) do
    window = emitted - Map.get(report, :pre_dispatcher_emitted, 0)

    if window > 0 do
      Map.put(report, :capture_rate, recorded / window)
    else
      Map.put(report, :capture_rate, :not_applicable)
    end
  end

  defp put_capture_rate(error), do: error

  @doc """
  CX-vyrs — the RESOLVED effective-enforcement posture, in one place. Three
  independent knobs each gate a different lane (trust-anchor strictness,
  local-write, local-read/P3), and each has its own defaulting/resolution
  path — so "is this node actually enforcing anything" cannot be read off
  any single config value. This reads each knob EXACTLY the way its real
  consumer does (no separate/parallel defaulting that could drift):

    * `accept_unsigned` / `trusted_identities_count` — via `config/0`, the
      same resolution `authorized?/3` and the gates use (app env → trust.json
      → permissive default; folds in local-node trust).
    * `local_write_gate` — via `local_write_gate/0`, the single resolver used
      by every local-write reader. It defaults absence to `:dry_run` and
      refuses values outside `:off | :dry_run | :enforce`.
    * `local_read_gate` — `Application.get_env(:commonplace, :local_read_gate,
      :permissive)`, the same default `Trust.Read.gate/3` applies.

  `strict` is a derived summary, true only when ALL THREE lanes are at
  their strictest setting (`accept_unsigned: false`, both gates `:enforce`)
  — a single true/false an operator or a boot-time log line can assert on
  without re-deriving the three-knob conjunction each time.
  """
  @spec posture() :: %{
          accept_unsigned: boolean(),
          trusted_identities_count: non_neg_integer(),
          local_write_gate: atom(),
          local_read_gate: atom(),
          strict: boolean(),
          audit: map()
        }
  def posture do
    cfg = config()
    local_write_gate = local_write_gate()
    local_read_gate = Application.get_env(:commonplace, :local_read_gate, :permissive)

    %{
      accept_unsigned: cfg.accept_unsigned,
      trusted_identities_count: map_size(cfg.trusted_identities),
      local_write_gate: local_write_gate,
      local_read_gate: local_read_gate,
      strict:
        cfg.accept_unsigned == false and local_write_gate == :enforce and
          local_read_gate == :enforce,
      # CX-t3xv: the AUDIT lane, in the same one call as the enforcement
      # lanes. An operator asking "is this node enforcing?" is almost
      # always also asking "and will I be able to see what it refused?" —
      # and for the whole life of the previous audit build the honest
      # answer to the second question was no, with nothing anywhere that
      # said so. Reading it here makes dormancy visible at the same
      # moment posture is.
      audit: audit_posture()
    }
  end

  defp audit_posture do
    dispatcher =
      case Commonplace.Trust.AuditDispatcher.status() do
        %{error: reason} ->
          %{running: false, error: reason}

        s ->
          Map.put(
            Map.take(s, [:enabled, :offered, :recorded, :shed, :failed, :guarded]),
            :running,
            true
          )
      end

    canary =
      case Process.whereis(Commonplace.Trust.AuditCanary) do
        nil ->
          %{running: false}

        _pid ->
          Commonplace.Trust.AuditCanary.status()
          |> Map.take([:enabled, :ticks, :passes, :alarms, :skips, :last_at])
          |> Map.put(:running, true)
      end

    %{
      handler_attached: Commonplace.Trust.AuditLog.attached?(),
      dispatcher: dispatcher,
      canary: canary
    }
  rescue
    # Posture is a diagnostic. It must answer even when the thing it is
    # diagnosing is broken.
    e -> %{error: Exception.message(e)}
  catch
    kind, value -> %{error: {kind, value}}
  end

  # `:absent` (no file — permissive default applies) is distinct from
  # `{:error, reason}` (file exists but can't be trusted — fail closed).
  defp config_from_file do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")

    case File.read(Path.join(data_dir, "trust.json")) do
      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        {:error, {:unreadable, reason}}

      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, json} when is_map(json) ->
            {:ok, normalize(json)}

          {:ok, _not_a_map} ->
            {:error, :not_a_map}

          {:error, %Jason.DecodeError{} = err} ->
            {:error, {:invalid_json, Exception.message(err)}}
        end
    end
  end

  # Accept atom- or string-keyed maps (app env vs JSON) and fill defaults.
  defp normalize(cfg) do
    %{
      accept_unsigned: fetch(cfg, :accept_unsigned, true),
      trusted_identities: fetch(cfg, :trusted_identities, %{})
    }
  end

  defp fetch(cfg, key, default) do
    Map.get(cfg, key, Map.get(cfg, Atom.to_string(key), default))
  end
end
