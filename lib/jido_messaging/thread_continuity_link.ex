defmodule Jido.Messaging.ThreadContinuityLink do
  @moduledoc """
  Durable link from a messaging thread to Jidoka-owned continuity state.

  The link is a correlation record. It does not own the Jidoka session,
  snapshot, memory, resume rules, or handoff state.
  """

  alias Jido.Messaging.{ContinuityData, JidokaContinuityRef}

  @statuses [:active, :unavailable, :expired, :deleted, :cleared]
  @terminal_statuses [:expired, :deleted, :cleared]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              room_id: Zoi.string(),
              thread_id: Zoi.string(),
              principal_id: Zoi.string(),
              continuity_ref: Zoi.struct(JidokaContinuityRef),
              status: Zoi.enum(@statuses),
              reason_code: Zoi.string() |> Zoi.nullish(),
              transition_ref: Zoi.string() |> Zoi.nullish(),
              source_revision: Zoi.integer(),
              source_updated_at: Zoi.struct(DateTime),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type status :: :active | :unavailable | :expired | :deleted | :cleared
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [
    :room_id,
    :thread_id,
    :principal_id,
    :continuity_ref,
    :status,
    :reason_code,
    :transition_ref,
    :source_revision,
    :source_updated_at
  ]

  @doc "Returns the Zoi schema for ThreadContinuityLink."
  def schema, do: @schema

  @doc "Builds a strict thread continuity link from Jidoka adapter input."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    :ok = ContinuityData.strict_keys!(attrs, @allowed_keys, "thread continuity link")
    now = DateTime.utc_now()
    room_id = attrs |> ContinuityData.value(:room_id) |> ContinuityData.required_ref!(:room_id)
    thread_id = attrs |> ContinuityData.value(:thread_id) |> ContinuityData.required_ref!(:thread_id)
    status = attrs |> ContinuityData.value(:status, :active) |> ContinuityData.enum!(@statuses, :continuity_status)
    reason_code = attrs |> ContinuityData.value(:reason_code) |> ContinuityData.optional_code!(:reason_code)
    continuity_ref = attrs |> ContinuityData.value(:continuity_ref) |> JidokaContinuityRef.new()
    :ok = validate_status!(status, reason_code, continuity_ref)

    Jido.Chat.Schema.parse!(__MODULE__, @schema, %{
      id: link_id(room_id, thread_id),
      room_id: room_id,
      thread_id: thread_id,
      principal_id: attrs |> ContinuityData.value(:principal_id) |> ContinuityData.required_ref!(:principal_id),
      continuity_ref: continuity_ref,
      status: status,
      reason_code: reason_code,
      transition_ref: attrs |> ContinuityData.value(:transition_ref) |> ContinuityData.optional_ref!(:transition_ref),
      source_revision: attrs |> ContinuityData.value(:source_revision) |> ContinuityData.positive_revision!(),
      source_updated_at: attrs |> ContinuityData.value(:source_updated_at) |> ContinuityData.source_time!(now),
      inserted_at: now,
      updated_at: now
    })
  end

  def new(_attrs), do: raise(ArgumentError, "thread continuity link must be a plain map")

  @doc "Tests whether two links contain the same source revision data."
  @spec equivalent?(t(), t()) :: boolean()
  def equivalent?(%__MODULE__{} = left, %__MODULE__{} = right) do
    semantic_fields(left) == semantic_fields(right)
  end

  @doc "Tests whether an update keeps the same messaging thread identity."
  @spec same_thread?(t(), t()) :: boolean()
  def same_thread?(%__MODULE__{} = left, %__MODULE__{} = right) do
    {left.id, left.room_id, left.thread_id} == {right.id, right.room_id, right.thread_id}
  end

  @doc "Tests whether an update changes its principal, Jidoka agent, or session."
  @spec replacement?(t(), t()) :: boolean()
  def replacement?(%__MODULE__{} = stored, %__MODULE__{} = incoming) do
    stored.principal_id != incoming.principal_id or
      stored.continuity_ref.jidoka_agent_ref != incoming.continuity_ref.jidoka_agent_ref or
      JidokaContinuityRef.session_key(stored.continuity_ref) !=
        JidokaContinuityRef.session_key(incoming.continuity_ref)
  end

  @doc "Validates owner replacement and terminal reactivation rules."
  @spec validate_transition(t(), t()) :: :ok | {:error, term()}
  def validate_transition(%__MODULE__{} = stored, %__MODULE__{} = incoming) do
    replacement? = replacement?(stored, incoming)

    cond do
      replacement? and is_nil(incoming.transition_ref) ->
        {:error, :continuity_transition_ref_required}

      stored.status in @terminal_statuses and incoming.status not in @terminal_statuses and not replacement? ->
        {:error, :continuity_terminal}

      true ->
        :ok
    end
  end

  @doc false
  @spec preserve_insertion(t(), t()) :: t()
  def preserve_insertion(%__MODULE__{} = incoming, %__MODULE__{} = stored) do
    %{incoming | inserted_at: stored.inserted_at}
  end

  @doc "Returns the status after reference expiry is applied."
  @spec effective_status(t(), DateTime.t()) :: status()
  def effective_status(link, at \\ DateTime.utc_now())

  def effective_status(%__MODULE__{status: status}, _at) when status in @terminal_statuses, do: status

  def effective_status(%__MODULE__{} = link, at) do
    case link.continuity_ref.expires_at do
      %DateTime{} = expires_at -> if DateTime.compare(at, expires_at) == :lt, do: link.status, else: :expired
      nil -> link.status
    end
  end

  @doc "Builds the next status revision and clears short refs for terminal states."
  @spec change_status(t(), status(), pos_integer(), DateTime.t(), String.t() | nil) :: t()
  def change_status(%__MODULE__{} = link, status, expected_revision, source_updated_at, reason_code)
      when status in @statuses and is_integer(expected_revision) and expected_revision > 0 and
             is_struct(source_updated_at, DateTime) do
    if link.source_revision != expected_revision do
      raise ArgumentError, "continuity revision does not match"
    end

    reason_code = ContinuityData.optional_code!(reason_code, :reason_code)

    continuity_ref =
      if status in @terminal_statuses,
        do: JidokaContinuityRef.clear_short_refs(link.continuity_ref),
        else: link.continuity_ref

    :ok = validate_status!(status, reason_code, continuity_ref)

    %{
      link
      | status: status,
        reason_code: reason_code,
        continuity_ref: continuity_ref,
        source_revision: link.source_revision + 1,
        source_updated_at: ContinuityData.source_time!(source_updated_at, DateTime.utc_now()),
        updated_at: DateTime.utc_now()
    }
  end

  def change_status(_link, _status, _expected_revision, _source_updated_at, _reason_code),
    do: raise(ArgumentError, "invalid continuity status change")

  @doc "Checks a source revision and prepares a continuity link for storage."
  @spec prepare_save(t() | nil, t()) ::
          {:ok, t(), :created | :updated | :unchanged} | {:error, term()}
  def prepare_save(nil, %__MODULE__{source_revision: 1} = incoming),
    do: {:ok, incoming, :created}

  def prepare_save(nil, %__MODULE__{}), do: {:error, :continuity_initial_revision_invalid}

  def prepare_save(%__MODULE__{} = stored, %__MODULE__{} = incoming) do
    cond do
      equivalent?(stored, incoming) ->
        {:ok, stored, :unchanged}

      not same_thread?(stored, incoming) ->
        {:error, :continuity_thread_identity_conflict}

      incoming.source_revision == stored.source_revision ->
        {:error, :continuity_revision_conflict}

      incoming.source_revision < stored.source_revision ->
        {:error, :continuity_stale_revision}

      incoming.source_revision > stored.source_revision + 1 ->
        {:error, :continuity_revision_gap}

      true ->
        with :ok <- validate_transition(stored, incoming) do
          {:ok, preserve_insertion(incoming, stored), :updated}
        end
    end
  end

  @doc "Tests whether a live link claims a Jidoka session."
  @spec claims_session?(t()) :: boolean()
  def claims_session?(%__MODULE__{status: status}), do: status in [:active, :unavailable]

  defp validate_status!(:active, nil, _reference), do: :ok

  defp validate_status!(:active, _reason_code, _reference),
    do: raise(ArgumentError, "active continuity cannot have a reason")

  defp validate_status!(status, nil, _reference) when status != :active,
    do: raise(ArgumentError, "inactive continuity requires a reason code")

  defp validate_status!(status, _reason_code, reference) when status in @terminal_statuses do
    if Enum.all?([reference.request_id, reference.turn_id, reference.snapshot_id], &is_nil/1) do
      :ok
    else
      raise ArgumentError, "terminal continuity cannot keep request, turn, or snapshot references"
    end
  end

  defp validate_status!(:unavailable, _reason_code, _reference), do: :ok

  defp semantic_fields(link) do
    link
    |> Map.from_struct()
    |> Map.drop([:inserted_at, :updated_at])
  end

  defp link_id(room_id, thread_id) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({1, room_id, thread_id}))
      |> Base.url_encode64(padding: false)

    "jcl_#{digest}"
  end
end
