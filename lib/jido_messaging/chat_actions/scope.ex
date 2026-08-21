defmodule Jido.Messaging.ChatActions.Scope do
  @moduledoc """
  Serializable authorization scope for chat actions.

  A scope is runtime context. It is not an action parameter, so a model cannot
  expand its own authority. Channel and thread identifiers are provider-facing
  canonical identifiers after bridge resolution.
  """

  @kinds [:channel, :thread, :strict_thread, :workspace]

  @enforce_keys [:kind]
  defstruct kind: nil,
            bridge_id: nil,
            adapter: nil,
            channel_id: nil,
            thread_id: nil,
            workspace_id: nil,
            actor_id: nil,
            explicit: false,
            metadata: %{}

  @type kind :: :channel | :thread | :strict_thread | :workspace

  @type t :: %__MODULE__{
          kind: kind(),
          bridge_id: String.t() | nil,
          adapter: atom() | nil,
          channel_id: String.t() | nil,
          thread_id: String.t() | nil,
          workspace_id: String.t() | nil,
          actor_id: String.t() | nil,
          explicit: boolean(),
          metadata: map()
        }

  @doc "Creates a channel scope."
  @spec channel(String.t(), atom(), String.t(), keyword()) :: t()
  def channel(bridge_id, adapter, channel_id, opts \\ []) do
    new(:channel, bridge_id, adapter, channel_id, nil, opts)
  end

  @doc "Creates a thread scope that also permits parent-channel reads."
  @spec thread(String.t(), atom(), String.t(), String.t(), keyword()) :: t()
  def thread(bridge_id, adapter, channel_id, thread_id, opts \\ []) do
    new(:thread, bridge_id, adapter, channel_id, thread_id, opts)
  end

  @doc "Creates a thread scope that permits only the exact thread."
  @spec strict_thread(String.t(), atom(), String.t(), String.t(), keyword()) :: t()
  def strict_thread(bridge_id, adapter, channel_id, thread_id, opts \\ []) do
    new(:strict_thread, bridge_id, adapter, channel_id, thread_id, opts)
  end

  @doc "Creates an explicit workspace scope."
  @spec workspace(String.t(), keyword()) :: t()
  def workspace(workspace_id, opts \\ []) do
    %__MODULE__{
      kind: :workspace,
      workspace_id: to_string(workspace_id),
      actor_id: stringify(Keyword.get(opts, :actor_id)),
      explicit: true,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Builds a scope from plain serialized data."
  @spec from_map(map() | t()) :: t()
  def from_map(%__MODULE__{} = scope), do: scope

  def from_map(map) when is_map(map) do
    kind = map |> get(:kind) |> normalize_kind()

    %__MODULE__{
      kind: kind,
      bridge_id: stringify(get(map, :bridge_id)),
      adapter: normalize_existing_atom(get(map, :adapter)),
      channel_id: stringify(get(map, :channel_id)),
      thread_id: stringify(get(map, :thread_id)),
      workspace_id: stringify(get(map, :workspace_id)),
      actor_id: stringify(get(map, :actor_id)),
      explicit: get(map, :explicit) == true,
      metadata: get(map, :metadata) || %{}
    }
  end

  @doc "Converts a scope to a JSON-safe plain map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = scope) do
    %{
      "kind" => Atom.to_string(scope.kind),
      "bridge_id" => scope.bridge_id,
      "adapter" => stringify(scope.adapter),
      "channel_id" => scope.channel_id,
      "thread_id" => scope.thread_id,
      "workspace_id" => scope.workspace_id,
      "actor_id" => scope.actor_id,
      "explicit" => scope.explicit,
      "metadata" => scope.metadata
    }
  end

  @doc "Infers the narrowest normal scope from a message or event context."
  @spec inherit(map() | struct(), keyword()) :: t() | nil
  def inherit(context, opts \\ []) when is_map(context) do
    bridge_id = get(context, :bridge_id) || get(context, :instance_id)
    adapter = get(context, :channel_type)
    channel_id = get(context, :external_room_id) || get(context, :channel_id)
    thread_id = get(context, :external_thread_id) || get(context, :thread_id)
    actor_id = Keyword.get(opts, :actor_id) || get(context, :participant_id) || get(context, :external_user_id)

    cond do
      blank?(bridge_id) or blank?(adapter) or blank?(channel_id) ->
        nil

      not blank?(thread_id) ->
        thread(to_string(bridge_id), normalize_existing_atom(adapter), to_string(channel_id), to_string(thread_id),
          actor_id: actor_id
        )

      true ->
        channel(to_string(bridge_id), normalize_existing_atom(adapter), to_string(channel_id), actor_id: actor_id)
    end
  end

  @doc false
  @spec bind_actor(t(), term()) :: t()
  def bind_actor(%__MODULE__{} = scope, nil), do: scope
  def bind_actor(%__MODULE__{} = scope, actor_id), do: %{scope | actor_id: stringify(actor_id)}

  @doc false
  @spec authorize(t(), map()) :: :ok | {:error, atom()}
  def authorize(%__MODULE__{kind: :workspace, explicit: false}, _target),
    do: {:error, :workspace_scope_not_explicit}

  def authorize(%__MODULE__{kind: :workspace, workspace_id: nil}, _target),
    do: {:error, :workspace_scope_not_explicit}

  def authorize(%__MODULE__{kind: :workspace} = scope, target) do
    if scope.workspace_id == target.workspace_id do
      :ok
    else
      {:error, :out_of_scope}
    end
  end

  def authorize(%__MODULE__{kind: :channel} = scope, target) do
    authorize_common(scope, target)
  end

  def authorize(%__MODULE__{kind: :thread} = scope, target) do
    with :ok <- authorize_common(scope, target) do
      if is_nil(target.thread_id) or target.thread_id == scope.thread_id,
        do: :ok,
        else: {:error, :out_of_scope}
    end
  end

  def authorize(%__MODULE__{kind: :strict_thread} = scope, target) do
    with :ok <- authorize_common(scope, target) do
      if is_binary(target.thread_id) and target.thread_id == scope.thread_id,
        do: :ok,
        else: {:error, :out_of_scope}
    end
  end

  defp authorize_common(scope, target) do
    if scope.bridge_id == target.bridge_id and scope.adapter == target.adapter and
         scope.channel_id == target.channel_id do
      :ok
    else
      {:error, :out_of_scope}
    end
  end

  defp new(kind, bridge_id, adapter, channel_id, thread_id, opts) do
    %__MODULE__{
      kind: kind,
      bridge_id: to_string(bridge_id),
      adapter: adapter,
      channel_id: to_string(channel_id),
      thread_id: stringify(thread_id),
      workspace_id: stringify(Keyword.get(opts, :workspace_id)),
      actor_id: stringify(Keyword.get(opts, :actor_id)),
      explicit: Keyword.get(opts, :explicit, false),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp normalize_kind(value) when value in @kinds, do: value

  defp normalize_kind(value) when is_binary(value) do
    Enum.find(@kinds, fn kind -> Atom.to_string(kind) == value end) || raise ArgumentError, "invalid scope kind"
  end

  defp normalize_kind(_value), do: raise(ArgumentError, "invalid scope kind")

  defp normalize_existing_atom(value) when is_atom(value), do: value

  defp normalize_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> raise ArgumentError, "unknown adapter identifier"
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
  defp blank?(value), do: value in [nil, ""]
end
