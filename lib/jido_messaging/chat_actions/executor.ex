defmodule Jido.Messaging.ChatActions.Executor do
  @moduledoc false

  alias Jido.Chat.{Adapter, Message, PostPayload}

  alias Jido.Messaging.{
    AuthorizationDecision,
    AuthorizationScope,
    Authorizer,
    Directory,
    IngressSubscriptions
  }

  alias Jido.Messaging.ChatActions.{Policy, Resolver, Result, Scope}

  @visible_writes [
    :post_message,
    :post_channel_message,
    :send_direct_message,
    :edit_message,
    :delete_message,
    :add_reaction,
    :remove_reaction,
    :ensure_subscription,
    :delete_subscription
  ]

  @workspace_operations [
    :lookup_user,
    :send_direct_message,
    :ensure_subscription,
    :list_subscriptions,
    :delete_subscription
  ]

  @channel_only_operations [
    :fetch_channel_messages,
    :list_threads,
    :fetch_channel_metadata,
    :post_channel_message
  ]

  @message_operations [
    :fetch_message,
    :edit_message,
    :delete_message,
    :add_reaction,
    :remove_reaction
  ]

  @spec execute(atom(), map(), map()) :: {:ok, map()}
  def execute(action, params, context) when is_atom(action) and is_map(params) and is_map(context) do
    with {:ok, target} <- Resolver.resolve(params, context),
         :ok <- ensure_supported(action, target),
         {:ok, scope} <- resolve_scope(context),
         :ok <- ensure_workspace_scope(action, scope),
         :ok <- authorize_scope(scope, target),
         :ok <- ensure_execution_scope(action, scope, target),
         audit = audit(action, target, scope),
         {:ok, authorization_audit} <- authorize_principal(action, target, context),
         audit = Map.merge(audit, authorization_audit),
         {:ok, authorized_params} <- apply_authorization_constraints(action, params, authorization_audit),
         :ok <- authorize_write(action, audit, context),
         {:ok, target} <- verify_message_scope(action, authorized_params, target, scope),
         {:ok, data} <- invoke(action, authorized_params, target) do
      {:ok, Result.ok(action, target, data, audit)}
    else
      {:policy, :deny, audit} ->
        {:ok, Result.denied(action, :policy_denied, audit)}

      {:policy, :needs_approval, audit} ->
        {:ok, Result.approval_required(action, audit)}

      {:scope, code, audit} ->
        {:ok, Result.denied(action, code, audit)}

      {:authorization, reason, audit} ->
        {:ok, Result.denied(action, :authorization_denied, Map.put(audit, :reason, reason))}

      {:error, code, details} ->
        {:ok, Result.error(action, code, details)}

      {:provider_error, reason, target, audit} ->
        {:ok,
         Result.error(action, provider_error_code(reason), %{reason: safe_reason(reason)}, audit_for(target, audit))}
    end
  end

  @doc false
  @spec supported_actions([module()], module()) :: [module()]
  def supported_actions(actions, adapter_module) when is_list(actions) and is_atom(adapter_module) do
    matrix = Adapter.capabilities(adapter_module)

    Enum.filter(actions, fn action ->
      supported_with_matrix?(action.chat_action_operation(), adapter_module, matrix)
    end)
  end

  @doc false
  @spec supported?(atom(), module()) :: boolean()
  def supported?(action, adapter_module) do
    matrix = Adapter.capabilities(adapter_module)

    supported_with_matrix?(action, adapter_module, matrix)
  end

  defp supported_with_matrix?(:post_message, _adapter_module, matrix) do
    supported_capability?(matrix, :post_message) or supported_capability?(matrix, :send_message)
  end

  defp supported_with_matrix?(action, adapter_module, matrix) do
    case capability(action) do
      {:adapter, capability} -> supported_capability?(matrix, capability)
      {:callback, callback, arity} -> function_exported?(adapter_module, callback, arity)
      :directory -> true
      :none -> false
    end
  end

  defp supported_capability?(matrix, capability) do
    Map.get(matrix, capability, :unsupported) in [:native, :fallback]
  end

  defp ensure_supported(action, target) do
    if supported?(action, target.adapter_module) do
      :ok
    else
      {:error, :unsupported_operation, %{adapter: target.adapter, action: action}}
    end
  end

  defp resolve_scope(context) do
    runtime_context = Resolver.runtime_context(context)
    raw_scope = get(runtime_context, :scope)

    scope =
      cond do
        match?(%Scope{}, raw_scope) -> raw_scope
        is_map(raw_scope) -> Scope.from_map(raw_scope)
        true -> Scope.inherit(get(runtime_context, :active_context) || get(runtime_context, :msg_context) || %{})
      end

    case scope do
      %Scope{} -> {:ok, Scope.bind_actor(scope, get(runtime_context, :actor_id))}
      nil -> {:error, :missing_scope, %{field: :scope}}
    end
  rescue
    ArgumentError -> {:error, :invalid_scope, %{field: :scope}}
  end

  defp ensure_workspace_scope(action, %Scope{kind: :workspace, explicit: true})
       when action in @workspace_operations,
       do: :ok

  defp ensure_workspace_scope(action, scope) when action in @workspace_operations do
    {:scope, :workspace_scope_required, scope_audit(scope)}
  end

  defp ensure_workspace_scope(_action, _scope), do: :ok

  defp authorize_scope(scope, target) do
    case Scope.authorize(scope, target) do
      :ok -> :ok
      {:error, code} -> {:scope, code, Map.merge(scope_audit(scope), target_audit(target))}
    end
  end

  defp ensure_execution_scope(action, %Scope{kind: :strict_thread} = scope, target)
       when action in @channel_only_operations do
    {:scope, :out_of_scope, Map.merge(scope_audit(scope), target_audit(target))}
  end

  defp ensure_execution_scope(_action, _scope, _target), do: :ok

  defp authorize_write(action, audit, context) when action in @visible_writes do
    runtime_context = Resolver.runtime_context(context)

    policy =
      case get(runtime_context, :policy) do
        %Policy{} = value -> value
        value when is_map(value) -> Policy.from_map(value)
        _ -> Policy.default()
      end

    case Policy.evaluate(policy, audit) do
      :allow -> :ok
      :deny -> {:policy, :deny, Map.put(audit, :policy_metadata, policy.metadata)}
      :needs_approval -> {:policy, :needs_approval, Map.put(audit, :policy_metadata, policy.metadata)}
    end
  rescue
    ArgumentError -> {:error, :invalid_policy, %{field: :policy}}
  end

  defp authorize_write(_action, _audit, _context), do: :ok

  defp authorize_principal(action, target, context) do
    runtime_context = Resolver.runtime_context(context)

    case get(runtime_context, :authorization_mode) || :legacy do
      :legacy ->
        {:ok, %{authorization_mode: :legacy}}

      :enforce ->
        authorize_enforced(action, target, runtime_context)

      _mode ->
        {:authorization, :invalid_authorization_mode, target_audit(target)}
    end
  end

  defp authorize_enforced(action, target, runtime_context) do
    principal_id = get(runtime_context, :principal_id)
    resource = normalize_authorization_scope(get(runtime_context, :authorization_scope))

    cond do
      not is_binary(principal_id) or principal_id == "" ->
        {:authorization, :verified_principal_required, target_audit(target)}

      not match?(%AuthorizationScope{}, resource) ->
        {:authorization, :authorization_scope_required, target_audit(target)}

      is_binary(resource.bridge_id) and resource.bridge_id != target.bridge_id ->
        {:authorization, :authorization_scope_mismatch, target_audit(target)}

      true ->
        runtime = target.instance_module.__jido_messaging__(:runtime)

        case Authorizer.check(runtime, principal_id, action, resource) do
          {:ok, %AuthorizationDecision{} = decision} ->
            {:ok,
             %{
               authorization_mode: :enforce,
               authorization: AuthorizationDecision.to_map(decision)
             }}

          {:error, {:authorization_denied, reason, %AuthorizationDecision{} = decision}} ->
            {:authorization, reason, %{authorization: AuthorizationDecision.to_map(decision)}}

          {:error, reason} ->
            {:authorization, reason, target_audit(target)}
        end
    end
  end

  defp normalize_authorization_scope(%AuthorizationScope{} = scope), do: scope

  defp normalize_authorization_scope(scope) when is_map(scope) do
    AuthorizationScope.new(scope)
  rescue
    ArgumentError -> nil
  end

  defp normalize_authorization_scope(_scope), do: nil

  defp apply_authorization_constraints(
         action,
         params,
         %{authorization: %{constraints: %{"max_results" => maximum}}}
       )
       when action in [:fetch_channel_messages, :fetch_thread_messages, :list_threads, :list_subscriptions] and
              is_integer(maximum) and maximum > 0 do
    requested = get(params, :limit)
    effective = if is_integer(requested) and requested > 0, do: min(requested, maximum), else: maximum
    {:ok, Map.put(params, :limit, effective)}
  end

  defp apply_authorization_constraints(_action, params, _authorization_audit), do: {:ok, params}

  defp invoke(:fetch_message, _params, %{verified_message: %Message{} = message}), do: {:ok, message}

  defp invoke(:fetch_message, params, target) do
    call(target, fn ->
      Adapter.fetch_message(
        target.adapter_module,
        target.channel_id,
        fetch!(params, :message_id),
        target.adapter_opts
      )
    end)
  end

  defp invoke(:fetch_channel_messages, params, target) do
    call(target, fn ->
      Adapter.fetch_channel_messages(target.adapter_module, target.channel_id, page_opts(params, target))
    end)
  end

  defp invoke(:fetch_thread, _params, target) do
    call(target, fn -> Adapter.fetch_thread(target.adapter_module, target.channel_id, target.adapter_opts) end)
  end

  defp invoke(:fetch_thread_messages, params, target) do
    call(target, fn -> Adapter.fetch_messages(target.adapter_module, target.channel_id, page_opts(params, target)) end)
  end

  defp invoke(:list_threads, params, target) do
    call(target, fn -> Adapter.list_threads(target.adapter_module, target.channel_id, page_opts(params, target)) end)
  end

  defp invoke(:fetch_channel_metadata, _params, target) do
    call(target, fn -> Adapter.fetch_metadata(target.adapter_module, target.channel_id, target.adapter_opts) end)
  end

  defp invoke(:lookup_participant, params, target) do
    query = scoped_directory_query(fetch!(params, :query), target)

    call(target, fn -> Directory.lookup(target.instance_module, :participant, query, target.adapter_opts) end)
  end

  defp invoke(:lookup_user, params, target) do
    query = fetch!(params, :query)

    if function_exported?(target.adapter_module, :lookup_user, 2) do
      call(target, fn -> target.adapter_module.lookup_user(query, target.adapter_opts) end)
    else
      call(target, fn ->
        Directory.lookup(
          target.instance_module,
          :participant,
          scoped_directory_query(query, target),
          target.adapter_opts
        )
      end)
    end
  end

  defp invoke(:post_message, params, target) do
    opts = Keyword.put(target.adapter_opts, :scope, if(target.thread_id, do: :thread, else: :channel))

    call(target, fn ->
      Adapter.post_message(target.adapter_module, target.channel_id, PostPayload.text(fetch!(params, :text)), opts)
    end)
  end

  defp invoke(:post_channel_message, params, target) do
    call(target, fn ->
      Adapter.post_channel_message(target.adapter_module, target.channel_id, fetch!(params, :text), target.adapter_opts)
    end)
  end

  defp invoke(:send_direct_message, params, target) do
    with {:ok, room_id} <- target.adapter_module.open_dm(fetch!(params, :user_id), target.adapter_opts) do
      call(%{target | channel_id: to_string(room_id), thread_id: nil}, fn ->
        Adapter.post_message(
          target.adapter_module,
          room_id,
          PostPayload.text(fetch!(params, :text)),
          Keyword.put(target.adapter_opts, :scope, :channel)
        )
      end)
    else
      {:error, reason} -> provider_error(reason, target)
      other -> provider_error({:invalid_open_dm_result, other}, target)
    end
  end

  defp invoke(:edit_message, params, target) do
    call(target, fn ->
      Adapter.edit_message(
        target.adapter_module,
        target.channel_id,
        fetch!(params, :message_id),
        fetch!(params, :text),
        target.adapter_opts
      )
    end)
  end

  defp invoke(:delete_message, params, target) do
    call(target, fn ->
      Adapter.delete_message(
        target.adapter_module,
        target.channel_id,
        fetch!(params, :message_id),
        target.adapter_opts
      )
    end)
  end

  defp invoke(:add_reaction, params, target) do
    call(target, fn ->
      Adapter.add_reaction(
        target.adapter_module,
        target.channel_id,
        fetch!(params, :message_id),
        fetch!(params, :emoji),
        target.adapter_opts
      )
    end)
  end

  defp invoke(:remove_reaction, params, target) do
    call(target, fn ->
      Adapter.remove_reaction(
        target.adapter_module,
        target.channel_id,
        fetch!(params, :message_id),
        fetch!(params, :emoji),
        target.adapter_opts
      )
    end)
  end

  defp invoke(:start_typing, _params, target) do
    call(target, fn -> Adapter.start_typing(target.adapter_module, target.channel_id, target.adapter_opts) end)
  end

  defp invoke(:ensure_subscription, _params, target) do
    call(target, fn ->
      IngressSubscriptions.ensure(target.instance_module, target.bridge_id, target.adapter_opts)
    end)
  end

  defp invoke(:list_subscriptions, _params, target) do
    call(target, fn -> IngressSubscriptions.list(target.instance_module, target.bridge_id, target.adapter_opts) end)
  end

  defp invoke(:delete_subscription, params, target) do
    call(target, fn ->
      IngressSubscriptions.delete(
        target.instance_module,
        target.bridge_id,
        fetch!(params, :subscription_id),
        target.adapter_opts
      )
    end)
  end

  defp call(target, function) do
    case function.() do
      {:ok, data} -> {:ok, data}
      :ok -> {:ok, %{completed: true}}
      {:error, reason} -> provider_error(reason, target)
      other -> provider_error({:invalid_adapter_result, other}, target)
    end
  rescue
    exception -> provider_error({:exception, Exception.message(exception)}, target)
  catch
    kind, reason -> provider_error({kind, reason}, target)
  end

  defp verify_message_scope(action, params, target, %Scope{kind: kind} = scope)
       when action in @message_operations and kind in [:thread, :strict_thread] and
              is_binary(target.thread_id) do
    message_id = fetch!(params, :message_id)
    verification_opts = Keyword.drop(target.adapter_opts, [:thread_id, :external_thread_id])

    case call(target, fn ->
           Adapter.fetch_message(
             target.adapter_module,
             target.channel_id,
             message_id,
             verification_opts
           )
         end) do
      {:ok, %Message{} = message} ->
        if message_in_target?(message, target) do
          {:ok, Map.put(target, :verified_message, message)}
        else
          {:scope, :out_of_scope, Map.merge(scope_audit(scope), target_audit(target))}
        end

      {:provider_error, _reason, _target, _audit} = error ->
        error
    end
  end

  defp verify_message_scope(_action, _params, target, _scope), do: {:ok, target}

  defp message_in_target?(%Message{} = message, target) do
    message_channel_id = message.external_room_id || message.channel_id
    canonical_thread_id = "#{target.adapter}:#{target.channel_id}:#{target.thread_id}"

    to_string(message_channel_id) == target.channel_id and
      message.thread_id in [target.thread_id, canonical_thread_id]
  end

  defp provider_error(reason, target), do: {:provider_error, reason, target, %{}}

  defp page_opts(params, target) do
    target.adapter_opts
    |> maybe_put(:cursor, get(params, :cursor))
    |> maybe_put(:limit, get(params, :limit))
    |> maybe_put(:direction, normalize_direction(get(params, :direction)))
  end

  defp scoped_directory_query(query, target) do
    query
    |> normalize_map()
    |> Map.put(:channel, target.adapter)
  end

  defp audit(action, target, scope) do
    target_audit(target)
    |> Map.put(:action, action)
    |> Map.put(:actor_id, scope.actor_id)
    |> Map.put(:scope_kind, scope.kind)
    |> Map.put(:scope_metadata, scope.metadata)
  end

  defp target_audit(target) do
    %{
      adapter: target.adapter,
      bridge_id: target.bridge_id,
      channel_id: target.channel_id,
      thread_id: target.thread_id,
      workspace_id: target.workspace_id
    }
  end

  defp audit_for(target, extra), do: Map.merge(target_audit(target), extra)

  defp scope_audit(scope) do
    %{
      actor_id: scope.actor_id,
      scope_kind: scope.kind,
      bridge_id: scope.bridge_id,
      adapter: scope.adapter,
      channel_id: scope.channel_id,
      thread_id: scope.thread_id,
      workspace_id: scope.workspace_id,
      scope_metadata: scope.metadata
    }
  end

  defp capability(:fetch_message), do: {:adapter, :fetch_message}
  defp capability(:fetch_channel_messages), do: {:adapter, :fetch_channel_messages}
  defp capability(:fetch_thread), do: {:adapter, :fetch_thread}
  defp capability(:fetch_thread_messages), do: {:adapter, :fetch_messages}
  defp capability(:list_threads), do: {:adapter, :list_threads}
  defp capability(:fetch_channel_metadata), do: {:adapter, :fetch_metadata}
  defp capability(:lookup_participant), do: :directory
  defp capability(:lookup_user), do: :directory
  defp capability(:post_channel_message), do: {:adapter, :post_channel_message}
  defp capability(:send_direct_message), do: {:adapter, :open_dm}
  defp capability(:edit_message), do: {:adapter, :edit_message}
  defp capability(:delete_message), do: {:adapter, :delete_message}
  defp capability(:add_reaction), do: {:adapter, :add_reaction}
  defp capability(:remove_reaction), do: {:adapter, :remove_reaction}
  defp capability(:start_typing), do: {:adapter, :start_typing}
  defp capability(:ensure_subscription), do: {:callback, :ensure_ingress_subscription, 2}
  defp capability(:list_subscriptions), do: {:callback, :list_ingress_subscriptions, 2}
  defp capability(:delete_subscription), do: {:callback, :delete_ingress_subscription, 3}
  defp capability(_action), do: :none

  defp provider_error_code(:unsupported), do: :unsupported_operation
  defp provider_error_code({:unsupported, _reason}), do: :unsupported_operation
  defp provider_error_code(:not_found), do: :not_found
  defp provider_error_code({:ambiguous, _matches}), do: :ambiguous
  defp provider_error_code(_reason), do: :provider_error

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({type, _detail}) when is_atom(type), do: %{type: type}
  defp safe_reason(%{type: type}) when is_atom(type), do: %{type: type}
  defp safe_reason(_reason), do: %{type: :provider_error}

  defp fetch!(map, key), do: Map.get(map, key) || Map.fetch!(map, Atom.to_string(key))
  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {safe_existing_atom(key), value}
      pair -> pair
    end)
  end

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_direction(value) when value in [:forward, :backward], do: value
  defp normalize_direction("forward"), do: :forward
  defp normalize_direction("backward"), do: :backward
  defp normalize_direction(_value), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
