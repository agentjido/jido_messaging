defmodule Jido.Messaging.ChatActions do
  @moduledoc """
  Capability-scoped `Jido.Action` sets for normalized chat operations.

  The action input schemas contain only canonical targets and operation data.
  Adapter modules, credentials, and provider clients stay in trusted runtime
  context and bridge configuration.
  """

  alias Jido.Messaging.ChatActions.Executor
  alias Jido.Messaging.ChatActions.Messenger
  alias Jido.Messaging.ChatActions.Moderator
  alias Jido.Messaging.ChatActions.Policy
  alias Jido.Messaging.ChatActions.Reader
  alias Jido.Messaging.ChatActions.Resolver
  alias Jido.Messaging.ChatActions.Scope

  @reader [
    Reader.FetchMessage,
    Reader.FetchChannelMessages,
    Reader.FetchThread,
    Reader.FetchThreadMessages,
    Reader.ListThreads,
    Reader.LookupParticipant,
    Reader.LookupUser,
    Reader.FetchChannelMetadata
  ]

  @messenger [
    Messenger.PostMessage,
    Messenger.PostChannelMessage,
    Messenger.SendDirectMessage,
    Messenger.StartTyping
  ]

  @moderator [
    Moderator.EditMessage,
    Moderator.DeleteMessage,
    Moderator.AddReaction,
    Moderator.RemoveReaction,
    Moderator.EnsureSubscription,
    Moderator.ListSubscriptions,
    Moderator.DeleteSubscription
  ]

  @all @reader ++ @messenger ++ @moderator

  @type preset :: :reader | :messenger | :moderator | :all

  @doc "Returns all modules in a named preset without adapter filtering."
  @spec preset(preset()) :: [module()]
  def preset(:reader), do: @reader
  def preset(:messenger), do: @messenger
  def preset(:moderator), do: @moderator
  def preset(:all), do: @all

  @doc "Builds an action list from a preset or custom list and adapter capabilities."
  @spec actions_for(module(), Jido.Chat.MessagingTarget.t() | map(), preset() | [module()]) ::
          {:ok, [module()]} | {:error, atom() | {atom(), term()}}
  def actions_for(instance_module, target, selection \\ :all) when is_atom(instance_module) do
    with {:ok, actions} <- select(selection),
         {:ok, resolved} <- Resolver.resolve(%{target: target}, %{instance_module: instance_module}) do
      {:ok, Executor.supported_actions(actions, resolved.adapter_module)}
    else
      {:error, code, details} -> {:error, {code, details}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Builds trusted Jido Action context with an explicit scope and policy."
  @spec context(module(), map() | struct(), keyword() | map()) :: map()
  def context(instance_module, active_context, opts \\ %{}) when is_atom(instance_module) and is_map(active_context) do
    opts = normalize_opts(opts)
    supplied_scope = get(opts, :scope) || get(active_context, :scope)
    actor_id = trusted_actor_id(opts, active_context)

    scope =
      cond do
        match?(%Scope{}, supplied_scope) -> supplied_scope
        is_map(supplied_scope) -> Scope.from_map(supplied_scope)
        true -> Scope.inherit(active_context, actor_id: actor_id)
      end

    scope = if scope, do: Scope.bind_actor(scope, actor_id)
    actor_id = if scope, do: scope.actor_id, else: stringify(actor_id)

    policy =
      case get(opts, :policy) || get(active_context, :policy) do
        %Policy{} = value -> value
        value when is_map(value) -> Policy.from_map(value)
        _ -> Policy.default()
      end

    %{
      chat_action: %{
        instance_module: instance_module,
        active_context: active_context,
        scope: scope,
        policy: policy,
        actor_id: actor_id,
        target: get(opts, :target)
      }
    }
  end

  defp select(selection) when selection in [:reader, :messenger, :moderator, :all],
    do: {:ok, preset(selection)}

  defp select(actions) when is_list(actions) do
    if Enum.all?(actions, &(&1 in @all)), do: {:ok, actions}, else: {:error, :unknown_action}
  end

  defp select(_selection), do: {:error, :unknown_preset}

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts

  defp trusted_actor_id(opts, active_context) do
    get(opts, :actor_id) ||
      get(active_context, :actor_id) ||
      get(active_context, :participant_id) ||
      get(active_context, :external_user_id)
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
