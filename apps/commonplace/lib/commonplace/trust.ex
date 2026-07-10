defmodule Commonplace.Trust do
  @moduledoc """
  The trust boundary: `authorized?(commit, verb, scope)`.

  Both enforcement gates — import (`CommitStore.import_commit`, Gate A)
  and execute (`SourceDoc.compile`, Gate B) — call **only** this function,
  never an allowlist or capability store directly. The phase-1 body below
  is a flat allowlist; phase-3 swaps in a capability-chain walk without
  the gates changing. See docs/trust-and-attenuation.md (commonplace-plan)
  §2/§4/§7.

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
                if cfg.accept_unsigned, do: :ok, else: {:error, {:untrusted_signer, identity_uuid}}

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
  CX-cj3t — the COMMITLESS mirror of "may this caller AUTHOR a verb (write an
  EXECUTABLE code doc) at `target_uuid`?", for an UPFRONT UX gate: the `@verb`
  editor uses it to open in EDIT vs read-only PREVIEW mode, instead of offering a
  full editor and only denying the save afterward.

  Authoring an executable code doc requires EXECUTE authority — a trusted
  identity (the node), or a verified cert granting `:execute` over the target. A
  `:write`-only cert (the citizenship `{:subtree,home}`/`{:presence}` grants a
  player holds) is refused at commit time by the write⊥execute belt (see
  `subtree_carve_ok?` (3)); this predicate lets the editor SAY so before opening.
  Under `accept_unsigned` (the permissive dev gate) the save would land, so this
  returns `true` (editor stays fully functional). Fail-closed on any error.
  """
  @spec code_author_authorized?(String.t() | nil, binary() | nil, [String.t()], String.t(), config(), GenServer.server()) ::
          boolean()
  def code_author_authorized?(identity_uuid, pub, cert_cids, target_uuid, cfg, store) do
    cond do
      cfg.accept_unsigned -> true
      not is_binary(identity_uuid) -> false
      Map.has_key?(cfg.trusted_identities, identity_uuid) -> true
      true -> Enum.any?(cert_cids, &cert_grants_execute?(&1, pub, target_uuid, cfg, store))
    end
  end

  defp cert_grants_execute?(cid, pub, target_uuid, cfg, store) do
    with {:ok, leaf} <- fetch_cap(store, cid),
         {_uuid, audience_pub} <- leaf.audience,
         true <- pub != nil and audience_pub == pub,
         {:ok, %{verbs: verbs, scope: scope}} <-
           Commonplace.Trust.VerifyChain.verify_chain(cid, anchor_keys(cfg), store) do
      :execute in verbs and write_scope_covers?(scope, target_uuid, store)
    else
      _ -> false
    end
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
         {:ok, %{verbs: verbs, scope: {:docs, docs}}} <-
           Commonplace.Trust.VerifyChain.verify_chain(cid, anchor_keys(cfg), store) do
      :read in verbs and target_uuid in docs
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
  defp carve_branch({:ok, doc}), do: if(Doc.has_type?(doc, "entries"), do: :schema, else: :presence)

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

  # The locally-pinned trusted-identity keys ARE the cert-chain root
  # anchors (§4: an allowlist entry = an unattenuated root). Decode every
  # pinned pubkey into the anchor set.
  #
  # NOTE: `Commonplace.MUD.Verbs.local_anchor_keys/0` is a hand-kept copy
  # of this derivation (CX-2rbz) — it needs the same anchor set to call
  # `VerifyChain.verify_chain/3` from the MUD dispatch path but can't
  # reach this private function. Any change here MUST update that site
  # until CX-2rbz exposes a public accessor and removes the copy.
  defp anchor_keys(cfg) do
    cfg.trusted_identities
    |> Map.values()
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.flat_map(fn encoded ->
      case Signing.decode_key(encoded) do
        {:ok, key} -> [key]
        {:error, _} -> []
      end
    end)
    |> MapSet.new()
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
  """
  @spec authorized_to_execute?(GenServer.server(), String.t(), config() | nil) ::
          :ok | {:error, term()}
  def authorized_to_execute?(store, doc_uuid, cfg \\ nil) do
    cfg = cfg || config()

    if cfg.accept_unsigned and cfg.trusted_identities == %{} do
      # Fully-permissive config: no commit can fail (unsigned passes,
      # unknown signers pass, and with no pinned keys there is no
      # forgery case) — skip the chain walk (and any cache I/O) so the
      # default config keeps compile O(cache-hit) on hot paths.
      :ok
    else
      log = Commonplace.Store.CommitStoreClient.commit_log(store, doc_uuid, limit: 10_000)
      walk_contributors(store, doc_uuid, log, cfg)
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
    :erlang.phash2({cfg.trusted_identities, Commonplace.Store.CommitStoreClient.revocation_set_hash(store)})
  end

  defp walk_contributors(store, doc_uuid, log, cfg) do
    fp = cfg_fingerprint(cfg, store)

    {verdict, passed} =
      Enum.reduce_while(log, {:ok, []}, fn commit, {:ok, passed} ->
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
                    _ -> {:cont, {:ok, [commit.id | passed]}}
                  end
                else
                  {:cont, {:ok, passed}}
                end
            end
        end
      end)

    clean? = verdict == :ok
    Enum.each(passed, &Commonplace.Store.CommitStoreClient.put_execute_clean(store, fp, &1, clean?))
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
  # Best-effort: if the node key can't be sourced, the set is unchanged
  # (the node's commits will then fail strict checks — visible, not
  # silent).
  defp with_local_node_trust(cfg) do
    with {:ok, identity} <- Commonplace.Crypto.NodeIdentity.identity(),
         {:ok, pub} <- Commonplace.Crypto.NodeIdentity.public_key() do
      trusted = Map.put_new(cfg.trusted_identities, identity, Signing.encode_key(pub))
      %{cfg | trusted_identities: trusted}
    else
      _ -> cfg
    end
  end

  @doc "The default (permissive, empty allowlist) trust config."
  @spec default_config() :: config()
  def default_config do
    %{accept_unsigned: true, trusted_identities: %{}}
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
          {:ok, json} when is_map(json) -> {:ok, normalize(json)}
          {:ok, _not_a_map} -> {:error, :not_a_map}
          {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, Exception.message(err)}}
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
