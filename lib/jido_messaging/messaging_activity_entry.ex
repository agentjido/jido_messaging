defmodule Jido.Messaging.MessagingActivityEntry do
  @moduledoc """
  Safe messaging projection of one Jidoka-owned runtime activity.

  The entry stores messaging correlation and a bounded summary. Jidoka events
  and traces remain the source of truth for execution detail.
  """

  alias Jido.Messaging.{
    ActivityData,
    JidokaExecutionRef,
    MessagingActivitySummary
  }

  @kinds [:request, :turn, :approval, :handoff, :outcome]
  @statuses [
    :pending,
    :running,
    :waiting,
    :approved,
    :denied,
    :completed,
    :failed,
    :cancelled,
    :unavailable
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              principal_id: Zoi.string(),
              room_id: Zoi.string(),
              thread_id: Zoi.string() |> Zoi.nullish(),
              message_id: Zoi.string() |> Zoi.nullish(),
              kind: Zoi.enum(@kinds),
              status: Zoi.enum(@statuses),
              summary: Zoi.struct(MessagingActivitySummary),
              execution_ref: Zoi.struct(JidokaExecutionRef),
              source_event_id: Zoi.string(),
              source_event_type: Zoi.string(),
              source_revision: Zoi.integer(),
              source_recorded_at: Zoi.struct(DateTime),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type kind :: :request | :turn | :approval | :handoff | :outcome

  @type status ::
          :pending
          | :running
          | :waiting
          | :approved
          | :denied
          | :completed
          | :failed
          | :cancelled
          | :unavailable

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [
    :principal_id,
    :room_id,
    :thread_id,
    :message_id,
    :kind,
    :status,
    :summary,
    :execution_ref,
    :source_event_id,
    :source_event_type,
    :source_revision,
    :source_recorded_at
  ]

  @doc "Returns the Zoi schema for MessagingActivityEntry."
  def schema, do: @schema

  @doc "Builds a strict activity projection from redacted Jidoka adapter input."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    :ok = ActivityData.strict_keys!(attrs, @allowed_keys)
    now = DateTime.utc_now()
    execution_ref = attrs |> ActivityData.value(:execution_ref) |> JidokaExecutionRef.new()
    source_event_id = attrs |> ActivityData.value(:source_event_id) |> ActivityData.required_ref!(:source_event_id)
    source_recorded_at = ActivityData.value(attrs, :source_recorded_at)

    if not match?(%DateTime{}, source_recorded_at) do
      raise ArgumentError, "source_recorded_at must be a DateTime"
    end

    source_recorded_at =
      source_recorded_at
      |> DateTime.to_unix(:microsecond)
      |> DateTime.from_unix!(:microsecond)

    status = attrs |> ActivityData.value(:status) |> normalize_status!()
    summary = attrs |> ActivityData.value(:summary) |> MessagingActivitySummary.new()
    :ok = validate_summary_status!(status, summary.outcome)

    normalized = %{
      id: activity_id(execution_ref.integration_id, source_event_id),
      principal_id: attrs |> ActivityData.value(:principal_id) |> ActivityData.required_ref!(:principal_id),
      room_id: attrs |> ActivityData.value(:room_id) |> ActivityData.required_ref!(:room_id),
      thread_id: attrs |> ActivityData.value(:thread_id) |> ActivityData.optional_ref!(:thread_id),
      message_id: attrs |> ActivityData.value(:message_id) |> ActivityData.optional_ref!(:message_id),
      kind: attrs |> ActivityData.value(:kind) |> normalize_kind!(),
      status: status,
      summary: summary,
      execution_ref: execution_ref,
      source_event_id: source_event_id,
      source_event_type:
        attrs |> ActivityData.value(:source_event_type) |> ActivityData.required_code!(:source_event_type),
      source_revision: attrs |> ActivityData.value(:source_revision) |> ActivityData.positive_revision!(),
      source_recorded_at: source_recorded_at,
      inserted_at: now,
      updated_at: now
    }

    Jido.Chat.Schema.parse!(__MODULE__, @schema, normalized)
  end

  def new(_attrs), do: raise(ArgumentError, "activity projection must be a map")

  @doc "Tests whether two entries contain the same projected source revision."
  @spec equivalent?(t(), t()) :: boolean()
  def equivalent?(%__MODULE__{} = left, %__MODULE__{} = right) do
    semantic_fields(left) == semantic_fields(right)
  end

  @doc "Tests whether an update keeps stable messaging and Jidoka correlation."
  @spec same_correlation?(t(), t()) :: boolean()
  def same_correlation?(%__MODULE__{} = left, %__MODULE__{} = right) do
    {
      left.id,
      left.principal_id,
      left.room_id,
      left.thread_id,
      left.message_id,
      left.kind,
      left.source_event_id,
      left.source_event_type,
      left.source_recorded_at,
      JidokaExecutionRef.correlation_key(left.execution_ref)
    } ==
      {
        right.id,
        right.principal_id,
        right.room_id,
        right.thread_id,
        right.message_id,
        right.kind,
        right.source_event_id,
        right.source_event_type,
        right.source_recorded_at,
        JidokaExecutionRef.correlation_key(right.execution_ref)
      }
  end

  @doc false
  @spec preserve_insertion(t(), t()) :: t()
  def preserve_insertion(%__MODULE__{} = incoming, %__MODULE__{} = stored) do
    %{incoming | inserted_at: stored.inserted_at}
  end

  @doc "Returns an entry with time-effective Jidoka detail availability."
  @spec with_effective_detail(t(), DateTime.t()) :: t()
  def with_effective_detail(%__MODULE__{} = entry, at \\ DateTime.utc_now()) do
    %{entry | execution_ref: JidokaExecutionRef.effective(entry.execution_ref, at)}
  end

  defp semantic_fields(entry) do
    entry
    |> Map.from_struct()
    |> Map.drop([:inserted_at, :updated_at])
  end

  defp activity_id(integration_id, source_event_id) do
    digest =
      :crypto.hash(:sha256, "v1:#{integration_id}:#{source_event_id}")
      |> Base.url_encode64(padding: false)

    "jma_#{digest}"
  end

  defp normalize_kind!(kind) when kind in @kinds, do: kind
  defp normalize_kind!(kind) when is_binary(kind), do: normalize_string_enum!(kind, @kinds, :kind)
  defp normalize_kind!(_kind), do: raise(ArgumentError, "invalid activity kind")

  defp normalize_status!(status) when status in @statuses, do: status
  defp normalize_status!(status) when is_binary(status), do: normalize_string_enum!(status, @statuses, :status)
  defp normalize_status!(_status), do: raise(ArgumentError, "invalid activity status")

  defp normalize_string_enum!(value, allowed, field) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> raise ArgumentError, "invalid activity #{field}"
      result -> result
    end
  end

  defp validate_summary_status!(_status, :unknown), do: :ok
  defp validate_summary_status!(status, :none) when status in [:pending, :running, :waiting, :approved], do: :ok
  defp validate_summary_status!(:completed, :succeeded), do: :ok
  defp validate_summary_status!(:failed, :failed), do: :ok
  defp validate_summary_status!(:denied, :denied), do: :ok
  defp validate_summary_status!(:cancelled, :cancelled), do: :ok

  defp validate_summary_status!(_status, _outcome),
    do: raise(ArgumentError, "activity status and summary outcome conflict")
end
