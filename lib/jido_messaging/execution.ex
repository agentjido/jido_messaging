defmodule Jido.Messaging.Execution do
  @moduledoc false
  alias Jido.Chat.Content.Text
  alias Jido.Chat.Signal.Policy
  alias Jido.Messaging.{AuthorizationScope, Authorizer, Dispatch, Events, Message, RoomServer, RoomSupervisor, Runtime}
  alias Jido.Messaging.Signal.{Context, Identity, OperationCompleted, OperationFailed}
  alias Jido.Signal.Catalog

  @provider_actions %{
    send_message: :post_message,
    send_file: :post_message,
    post_message: :post_message,
    edit_message: :edit_message,
    delete_message: :delete_message,
    start_typing: :start_typing,
    fetch_metadata: :fetch_channel_metadata,
    fetch_thread: :fetch_thread,
    fetch_message: :fetch_message,
    get_user: :lookup_user,
    fetch_subject: :fetch_thread,
    get_thread_participants: :lookup_participant,
    mark_as_read: :receive_message,
    fetch_media: :fetch_message,
    add_reaction: :add_reaction,
    remove_reaction: :remove_reaction,
    post_ephemeral: :post_message,
    post_channel_message: :post_channel_message,
    stream: :post_message,
    open_modal: :post_message,
    load_options: :fetch_message,
    fetch_messages: :fetch_thread_messages,
    fetch_channel_messages: :fetch_channel_messages,
    list_threads: :list_threads,
    open_thread: :post_message,
    open_dm: :send_direct_message
  }
  @runtime_operations %{
    Jido.Messaging.Signal.PostMessage => {:post_message, :post_message},
    Jido.Messaging.Signal.CreateRoom => {:create_room, :post_message},
    Jido.Messaging.Signal.ParticipantJoinedRequest => {:participant_joined, :receive_message},
    Jido.Messaging.Signal.ParticipantLeftRequest => {:participant_left, :receive_message},
    Jido.Messaging.Signal.SetPresence => {:set_presence, :receive_message},
    Jido.Messaging.Signal.SetTyping => {:set_typing, :receive_message},
    Jido.Messaging.Signal.AddRoomReaction => {:add_room_reaction, :add_reaction},
    Jido.Messaging.Signal.RemoveRoomReaction => {:remove_room_reaction, :remove_reaction},
    Jido.Messaging.Signal.MarkDelivered => {:mark_delivered, :receive_message},
    Jido.Messaging.Signal.MarkRead => {:mark_read, :receive_message}
  }

  @doc false
  @spec execute(module(), Jido.Signal.t(), keyword()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def execute(instance, %Jido.Signal{} = request, opts) when is_list(opts) do
    runtime = instance.__jido_messaging__(:runtime)

    with {:ok, catalog} <- Runtime.catalog(runtime),
         {:ok, ^request} <- request |> Jido.Signal.to_map() |> Jido.Signal.from_map(),
         {:ok, ^request} <- Catalog.validate(catalog, request),
         {:ok, ^request} <- Policy.validate(request),
         {:ok, definition, operation, action} <- definition(request),
         :ok <- context(request),
         {:ok, decision} <- authorize(runtime, request, operation, action, opts) do
      admitted(instance, runtime, request, definition, operation, decision, opts)
    else
      {:denied, operation, code} -> failure(instance, request, operation, code)
      {:error, _} = error -> error
      _ -> Policy.error(:invalid_request)
    end
  rescue
    _ -> Policy.error(:invalid_request)
  catch
    _, _ -> Policy.error(:invalid_request)
  end

  def execute(_instance, _request, _opts), do: Policy.error(:invalid_request)

  defp definition(request) do
    module = Enum.find(Jido.Messaging.signal_definitions(), &(&1.type() == request.type))

    cond do
      is_nil(module) or module.__signal_kind__() not in [:command, :query] ->
        Policy.error(:invalid_request)

      module == Jido.Messaging.Signal.SendMessage and is_nil(request.data["bridge_id"]) ->
        {:ok, module, "route_outbound", :post_message}

      Map.has_key?(@runtime_operations, module) ->
        {operation, action} = @runtime_operations[module]
        {:ok, module, Atom.to_string(operation), action}

      true ->
        name = module |> Module.split() |> List.last()

        provider =
          Enum.find(Jido.Chat.Operations.Definitions.all(), fn {_type, {definition, _op, _fields, _shape, _schema}} ->
            Module.split(definition) |> List.last() == if(name == "PostProviderMessage", do: "PostMessage", else: name)
          end)

        case provider do
          {_type, {_definition, operation, _fields, _shape, _schema}} ->
            {:ok, module, "provider." <> Atom.to_string(operation), @provider_actions[operation]}

          _ ->
            Policy.error(:invalid_request)
        end
    end
  end

  defp context(request) do
    expected = Identity.room_subject(request.data["room_id"])

    if byte_size(request.id) in 1..128 and (is_nil(request.subject) or request.subject == expected),
      do: :ok,
      else: Policy.error(:invalid_context)
  end

  defp authorize(runtime, request, operation, action, opts) do
    with principal when is_binary(principal) and principal != "" <- opts[:principal_id],
         {:ok, scope} <- trusted_scope(opts[:authorization_scope]),
         :ok <- requested_scope(runtime, request.data, operation, scope),
         {:ok, decision} <- authorization_decision(runtime, principal, action, scope, request, operation, opts) do
      {:ok, decision}
    else
      {:error, {:authorization_denied, _reason, _decision}} -> {:denied, operation, "authorization_denied"}
      {:error, :scope_mismatch} -> {:denied, operation, "authorization_denied"}
      {:error, :invalid_actor_scope} -> {:denied, operation, "authorization_denied"}
      {:error, _} -> {:denied, operation, "authorization_store_failed"}
      _ -> {:denied, operation, "authorization_denied"}
    end
  rescue
    _ -> {:denied, operation, "authorization_store_failed"}
  catch
    _, _ -> {:denied, operation, "authorization_store_failed"}
  end

  defp authorization_decision(runtime, principal, action, scope, request, "route_outbound", opts) do
    instance = Runtime.get_state(runtime).instance_module

    with {:ok, policy, available} <- Jido.Messaging.OutboundRouter.plan(instance, request.data["room_id"]) do
      routes = if scope.bridge_id, do: Enum.filter(available, &(&1.bridge_id == scope.bridge_id)), else: available
      targets = if routes == [], do: [nil], else: routes

      result =
        Enum.reduce_while(targets, {:ok, []}, fn route, {:ok, decisions} ->
          target = if route, do: %{scope | bridge_id: route.bridge_id}, else: scope

          with {:ok, decision} <- Authorizer.check(runtime, principal, action, target),
               :ok <- private_policy(opts[:policy], decision, request, action, route || %{}) do
            {:cont, {:ok, [decision | decisions]}}
          else
            error -> {:halt, error}
          end
        end)

      with {:ok, decisions} <- result do
        [first | _] = decisions
        {:ok, Map.put(first, :route_plan, {policy, routes, Enum.reverse(decisions)})}
      end
    end
  end

  defp authorization_decision(runtime, principal, action, scope, request, _operation, opts) do
    with {:ok, decision} <- Authorizer.check(runtime, principal, action, scope),
         :ok <- private_policy(opts[:policy], decision, request, action),
         do: {:ok, decision}
  end

  defp private_policy(value, decision, request, action, route \\ %{})
  defp private_policy(nil, _decision, _request, _action, _route), do: :ok

  defp private_policy(value, decision, request, action, route) do
    policy = Jido.Messaging.ChatActions.Policy.new(value)

    audit = %{
      action: action,
      adapter: route[:channel],
      bridge_id: route[:bridge_id] || request.data["bridge_id"],
      channel_id: request.data["room_id"],
      thread_id: request.data["thread_id"],
      actor_id: decision.principal_id
    }

    if Jido.Messaging.ChatActions.Policy.evaluate(policy, audit) == :allow, do: :ok, else: {:error, :scope_mismatch}
  rescue
    _ -> {:error, :scope_mismatch}
  end

  defp trusted_scope(scope) do
    {:ok, AuthorizationScope.new(scope)}
  rescue
    _ -> {:error, :invalid_actor_scope}
  end

  defp requested_scope(_runtime, data, "create_room", %AuthorizationScope{kind: :bridge}) do
    if is_nil(data["room_id"]), do: :ok, else: {:error, :scope_mismatch}
  end

  defp requested_scope(_runtime, data, "create_room", %AuthorizationScope{kind: :room, room_id: room}) do
    if data["room_id"] == room, do: :ok, else: {:error, :scope_mismatch}
  end

  defp requested_scope(_runtime, _data, "create_room", _scope), do: {:error, :scope_mismatch}

  defp requested_scope(runtime, data, operation, scope) do
    matches =
      (is_nil(data["bridge_id"]) or data["bridge_id"] == scope.bridge_id) and
        (is_nil(data["room_id"]) or data["room_id"] == scope.room_id) and
        (is_nil(scope.thread_id) or data["thread_id"] == scope.thread_id)

    if matches do
      with :ok <- requested_thread_scope(runtime, data, scope),
           :ok <- requested_local_message_scope(runtime, data, operation, scope) do
        if is_nil(scope.message_id) do
          :ok
        else
          with {:ok, message} <- Jido.Messaging.get_message(runtime, scope.message_id),
               true <- message.room_id == scope.room_id and data["message_id"] in [message.id, message.external_id] do
            :ok
          else
            _ -> {:error, :scope_mismatch}
          end
        end
      end
    else
      {:error, :scope_mismatch}
    end
  end

  defp requested_local_message_scope(runtime, data, operation, scope)
       when operation in [
              "add_room_reaction",
              "remove_room_reaction",
              "mark_read",
              "mark_delivered",
              "provider.mark_as_read"
            ] do
    case Jido.Messaging.get_message(runtime, data["message_id"]) do
      {:ok, %Message{room_id: room}} when room == scope.room_id -> :ok
      {:ok, _} -> {:error, :scope_mismatch}
      {:error, :not_found} -> {:error, :scope_mismatch}
      {:error, _} = error -> error
    end
  end

  defp requested_local_message_scope(_runtime, _data, _operation, _scope), do: :ok

  defp requested_thread_scope(_runtime, %{"thread_id" => nil}, _scope), do: :ok
  defp requested_thread_scope(_runtime, data, _scope) when not is_map_key(data, "thread_id"), do: :ok

  defp requested_thread_scope(runtime, data, scope) do
    with {:ok, thread} <- Jido.Messaging.get_thread(runtime, data["thread_id"]),
         true <- thread.room_id == scope.room_id do
      :ok
    else
      false -> {:error, :scope_mismatch}
      {:error, :not_found} -> {:error, :scope_mismatch}
      {:error, _} = error -> error
    end
  end

  defp admitted(instance, runtime, request, definition, operation, decision, opts) do
    table = Runtime.request_table(runtime)
    key = {decision.principal_id, request.data["request_id"]}
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({request.type, request.data}, [:deterministic]))

    authority = request_authority(decision)

    if :ets.insert_new(table, {key, digest, authority, {:running, self()}}) do
      result = run(instance, runtime, request, definition, operation, decision, opts)
      :ets.insert(table, {key, digest, authority, {:done, result}})
      result
    else
      case :ets.lookup(table, key) do
        [{^key, ^digest, ^authority, {:done, result}}] ->
          result

        [{^key, ^digest, ^authority, {:running, owner}}] ->
          Policy.error(if(Process.alive?(owner), do: :request_in_progress, else: :request_outcome_unknown))

        _ ->
          Policy.error(:request_conflict)
      end
    end
  end

  defp request_authority(%{route_plan: {policy, routes, decisions}}) do
    {policy.revision, Enum.map(routes, &Map.take(&1, [:binding_id, :bridge_id, :external_room_id])),
     Enum.map(decisions, &request_authority/1)}
  end

  defp request_authority(decision),
    do:
      {decision.grant_id, decision.grant_revision, decision.invocation_policy_id, decision.invocation_policy_revision,
       decision.constraints}

  defp run(instance, runtime, request, definition, operation, decision, opts) do
    result =
      if String.starts_with?(operation, "provider."),
        do: provider(instance, runtime, request, operation, decision, opts),
        else: local(instance, runtime, request, definition, operation, decision)

    case result do
      {:ok, signal} ->
        case Dispatch.emit(instance, signal) do
          {:ok, _} -> {:ok, signal}
          {:error, _} -> failure(instance, request, operation, "observation_failed")
        end

      error ->
        error
    end
  rescue
    _ -> failure(instance, request, operation, "persistence_failed")
  catch
    _, _ -> failure(instance, request, operation, "persistence_failed")
  end

  defp provider(instance, runtime, request, operation, decision, _opts) do
    name = String.replace_prefix(operation, "provider.", "")

    {_type, {definition, _op, _fields, _shape, _schema}} =
      Enum.find(Jido.Chat.Operations.Definitions.all(), fn {_type, {_module, op, _fields, _shape, _schema}} ->
        Atom.to_string(op) == name
      end)

    with {:ok, binding} <- Runtime.binding(runtime, request.data["bridge_id"]),
         {:ok, receipt} <- receipt_plan(runtime, request, name, decision) do
      if receipt && receipt.already_read do
        completed(instance, request, operation, %{"acknowledged" => true})
      else
        invoke_provider(instance, runtime, binding, request, operation, decision, name, definition, receipt)
      end
    else
      {:error, %Jido.Chat.Errors.Contract{}} = error -> error
      {:error, :receipt_scope_mismatch} -> failure(instance, request, operation, "authorization_denied")
      {:error, _} -> failure(instance, request, operation, "persistence_failed")
    end
  end

  defp receipt_plan(runtime, request, "mark_as_read", decision),
    do: Jido.Messaging.ReadReceipt.prepare(runtime, request.data, decision.principal_id)

  defp receipt_plan(_runtime, _request, _name, _decision), do: {:ok, nil}

  defp invoke_provider(instance, runtime, binding, request, operation, decision, name, definition, receipt) do
    with {:ok, data} <- provider_data(runtime, binding, request.data, decision, name),
         data <- receipt_data(data, receipt),
         {:ok, command} <- definition.new(data),
         {:ok, command} <- Context.attach(command, parent_signal: request),
         {:ok, result} <- Jido.Chat.execute(binding, command) do
      case result.type do
        "jido.chat.operation.completed" ->
          with :ok <- commit_receipt(instance, runtime, request, receipt) do
            provider_completed(instance, binding, request, operation, result.data["result"])
          else
            {:error, :observation_failed} -> failure(instance, request, operation, "observation_failed")
            {:error, _} -> failure(instance, request, operation, "persistence_failed")
          end

        "jido.chat.operation.failed" ->
          failure(instance, request, operation, result.data["code"], result.data["retryable"])
      end
    else
      {:error, %Jido.Chat.Errors.Contract{}} = error -> error
      {:error, _} -> failure(instance, request, operation, "persistence_failed")
    end
  end

  defp receipt_data(data, nil), do: data

  defp receipt_data(data, receipt) do
    data = data |> Map.delete("read_at") |> Map.put("message_id", receipt.external_message_id)

    if receipt.message.delivery_external_room_id,
      do: Map.put(data, "room_id", receipt.message.delivery_external_room_id),
      else: data
  end

  defp commit_receipt(_instance, _runtime, _request, nil), do: :ok

  defp commit_receipt(instance, runtime, request, receipt) do
    with {:ok, _message, change} <- Jido.Messaging.ReadReceipt.commit(runtime, receipt) do
      if change == :updated do
        with {:ok, fact} <-
               Events.room_event(
                 instance,
                 :message_read,
                 receipt.message.room_id,
                 %{message_id: receipt.message.id, participant_id: receipt.participant_id, timestamp: receipt.read_at},
                 parent_signal: request
               ),
             {:ok, _} <- Dispatch.emit(instance, fact),
             do: :ok,
             else: (_ -> {:error, :observation_failed})
      else
        :ok
      end
    end
  end

  defp provider_completed(instance, binding, request, operation, result) do
    case completed(instance, request, operation, result) do
      {:error, %Jido.Chat.Errors.Contract{code: :signal_too_large}} ->
        with {:ok, ref} <- Jido.Chat.Resources.put(binding, "result", result, []) do
          completed(instance, request, operation, %{"resource_ref" => ref})
        end

      other ->
        other
    end
  end

  defp provider_data(runtime, binding, data, decision, operation) do
    data = Map.delete(data, "bridge_id")

    with {:ok, data} <- external_thread(runtime, data),
         {:ok, data} <- external_room(runtime, binding, data) do
      maximum = decision.constraints["max_results"]

      data =
        if is_integer(maximum) and maximum > 0 and
             operation in ~w(fetch_messages fetch_channel_messages list_threads load_options) do
          Map.put(data, "limit", min(Map.get(data, "limit", maximum), maximum))
        else
          data
        end

      {:ok, data}
    end
  end

  defp external_room(_runtime, _binding, data) when not is_map_key(data, "room_id"), do: {:ok, data}

  defp external_room(runtime, binding, data) do
    with {:ok, room} <- Jido.Messaging.get_room(runtime, data["room_id"]),
         channel <- binding.adapter.channel_type(),
         bindings <-
           Map.get(room.external_bindings, channel, Map.get(room.external_bindings, Atom.to_string(channel), %{})),
         external when is_binary(external) <- Map.get(bindings, binding.id) do
      {:ok, Map.put(data, "room_id", external)}
    else
      _ -> {:error, :room_binding_not_found}
    end
  end

  defp external_thread(_runtime, data) when not is_map_key(data, "thread_id"), do: {:ok, data}
  defp external_thread(_runtime, %{"thread_id" => nil} = data), do: {:ok, Map.delete(data, "thread_id")}

  defp external_thread(runtime, data) do
    with {:ok, thread} <- Jido.Messaging.get_thread(runtime, data["thread_id"]),
         external when is_binary(external) <- thread.external_thread_id do
      {:ok, Map.put(data, "thread_id", external)}
    else
      _ -> {:error, :thread_binding_not_found}
    end
  end

  defp local(instance, runtime, request, _definition, "route_outbound", %{route_plan: {policy, routes, _decisions}}) do
    with {:ok, data} <- external_thread(runtime, request.data) do
      opts = [parent_signal: request]

      opts =
        Enum.reduce(["thread_id", "reply_to_id", "format"], opts, fn key, opts ->
          if data[key], do: Keyword.put(opts, String.to_existing_atom(key), data[key]), else: opts
        end)

      result =
        Jido.Messaging.OutboundRouter.execute_plan(
          instance,
          request.data["room_id"],
          request.data["text"],
          {policy, routes},
          opts
        )

      case result do
        {:ok, summary} -> route_result(instance, runtime, request, routes, summary, false)
        {:error, {:delivery_failed, summary}} -> route_result(instance, runtime, request, routes, summary, true)
      end
    end
  end

  defp local(instance, runtime, request, _definition, "create_room", _decision) do
    kind = Enum.find([:direct, :group, :channel, :thread], &(Atom.to_string(&1) == request.data["kind"]))
    room_id = request.data["room_id"] || Jido.Chat.ID.generate!()
    attrs = %{id: room_id, name: request.data["name"], type: kind}

    with {:error, :not_found} <- Jido.Messaging.get_room(runtime, room_id),
         {:ok, room} <- Jido.Messaging.create_room(runtime, attrs) do
      _ =
        Events.room_event(instance, :room_created, room.id, %{name: room.name, kind: Atom.to_string(room.type)},
          parent_signal: request
        )
        |> publish(instance)

      completed(instance, request, "create_room", %{
        "id" => room.id,
        "name" => room.name,
        "kind" => Atom.to_string(room.type)
      })
    else
      {:ok, _existing} -> Policy.error(:request_conflict)
      _ -> failure(instance, request, "create_room", "persistence_failed")
    end
  end

  defp local(instance, runtime, request, _definition, "post_message", decision) do
    with {:ok, principal} <- Jido.Messaging.get_principal(runtime, decision.principal_id),
         true <- principal.participant_id == request.data["sender_id"],
         {:ok, _room} <- Jido.Messaging.get_room(runtime, request.data["room_id"]),
         message <-
           Message.new(%{
             room_id: request.data["room_id"],
             sender_id: principal.participant_id,
             role: known_role(request.data["role"]),
             content: [Text.new(request.data["text"])],
             thread_id: request.data["thread_id"]
           }),
         {:ok, fact, result} <- prepare_local_message(instance, runtime, request, message) do
      case Jido.Messaging.save_message_struct(runtime, message) do
        {:ok, _saved} ->
          case Dispatch.emit(instance, fact) do
            {:ok, _} -> {:ok, result}
            _ -> failure(instance, request, "post_message", "observation_failed")
          end

        _ ->
          cancel_message_resources(instance, fact, result)
          failure(instance, request, "post_message", "persistence_failed")
      end
    else
      false -> failure(instance, request, "post_message", "authorization_denied")
      {:error, %Jido.Chat.Errors.Contract{}} = error -> error
      _ -> failure(instance, request, "post_message", "persistence_failed")
    end
  end

  defp local(instance, runtime, request, _definition, operation, decision) do
    data = request.data

    with :ok <- participant_scope(runtime, data, decision),
         {:ok, room} <- Jido.Messaging.get_room(runtime, data["room_id"]),
         {:ok, server} <- RoomSupervisor.get_or_start_room(instance, room),
         result <- RoomServer.execute_change(server, operation, data, request),
         :ok <- accepted_change(result) do
      completed(instance, request, operation, %{"acknowledged" => true})
    else
      {:error, :participant_scope_mismatch} -> failure(instance, request, operation, "authorization_denied")
      _ -> failure(instance, request, operation, "persistence_failed")
    end
  end

  defp prepare_local_message(instance, runtime, request, message) do
    with {:ok, fact} <- Events.message_added(instance, message, parent_signal: request) do
      case local_message_completed(instance, runtime, request, message) do
        {:ok, result} ->
          {:ok, fact, result}

        error ->
          if fact.data["resource_ref"], do: Jido.Messaging.cancel_resource(instance, fact.data["resource_ref"])
          error
      end
    end
  end

  defp local_message_completed(instance, runtime, request, message) do
    summary = Events.message_summary(message)

    case completed(instance, request, "post_message", summary) do
      {:error, %Jido.Chat.Errors.Contract{code: :signal_too_large}} ->
        owner = Runtime.resource_owner(runtime)

        with {:ok, ref} <- Jido.Chat.Resources.put(owner, "result", summary, []) do
          case completed(instance, request, "post_message", %{"resource_ref" => ref}) do
            {:ok, _} = result ->
              result

            error ->
              _ = Jido.Chat.Resources.cancel(owner, ref)
              error
          end
        end

      result ->
        result
    end
  end

  defp cancel_message_resources(instance, fact, result) do
    for ref <- [fact.data["resource_ref"], result.data["result"]["resource_ref"]], is_map(ref) do
      _ = Jido.Messaging.cancel_resource(instance, ref)
    end

    :ok
  end

  defp participant_scope(runtime, data, decision) do
    with {:ok, principal} <- Jido.Messaging.get_principal(runtime, decision.principal_id),
         true <- is_nil(data["participant_id"]) or data["participant_id"] == principal.participant_id do
      :ok
    else
      _ -> {:error, :participant_scope_mismatch}
    end
  end

  defp accepted_change(:ok), do: :ok
  defp accepted_change({:ok, %Message{}}), do: :ok

  defp accepted_change({:ok, unchanged})
       when unchanged in [:not_found, :already_exists, :already_delivered, :already_read], do: :ok

  defp accepted_change({:error, _} = error), do: error

  defp route_result(instance, runtime, request, routes, summary, failed?) do
    result = %{
      "attempted" => summary.attempted,
      "delivery_mode" => Atom.to_string(summary.policy.delivery_mode),
      "delivered" =>
        Enum.map(summary.delivered, fn item ->
          %{
            "bridge_id" => item.route.bridge_id,
            "message_id" => to_string(item.result.message_id),
            "attempts" => item.result.attempts
          }
        end),
      "failed" =>
        Enum.map(summary.failed, fn item ->
          %{
            "bridge_id" => item.route.bridge_id,
            "code" => route_failure_code(item.reason),
            "retryable" => item.error.retryable,
            "attempts" => item.error.attempt
          }
        end)
    }

    route_envelope(instance, runtime, request, routes, result, failed?)
  end

  defp route_envelope(instance, runtime, request, routes, result, failed?, details \\ nil) do
    details =
      details ||
        %{
          code: if(result["attempted"] == 0, do: "unsupported", else: "provider_failure"),
          retryable: result["failed"] != [] and Enum.all?(result["failed"], & &1["retryable"])
        }

    signal =
      if failed? do
        data = %{
          "operation" => "route_outbound",
          "request_id" => request.data["request_id"],
          "code" => details.code,
          "retryable" => details.retryable,
          "result" => result
        }

        with {:ok, signal} <-
               OperationFailed.new(data,
                 source: Events.source(instance),
                 subject: Identity.room_subject(request.data["room_id"])
               ),
             {:ok, signal} <- Context.attach(signal, parent_signal: request),
             do: {:ok, signal}
      else
        completed(instance, request, "route_outbound", result)
      end

    case signal do
      {:error, %Jido.Chat.Errors.Contract{code: :signal_too_large}} ->
        with route when not is_nil(route) <- List.first(routes),
             {:ok, binding} <- Runtime.binding(runtime, route.bridge_id),
             {:ok, ref} <- Jido.Chat.Resources.put(binding, "result", result, []) do
          route_envelope(instance, runtime, request, [], %{"resource_ref" => ref}, failed?, details)
        end

      other ->
        other
    end
  end

  defp route_failure_code(:unsupported), do: "unsupported"
  defp route_failure_code(_), do: "provider_failure"

  defp completed(instance, request, operation, result) do
    data = %{"operation" => operation, "request_id" => request.data["request_id"], "result" => result}
    data = if request.data["bridge_id"], do: Map.put(data, "bridge_id", request.data["bridge_id"]), else: data

    with {:ok, signal} <-
           OperationCompleted.new(data, source: Events.source(instance), subject: result_subject(request, result)),
         {:ok, signal} <- Context.attach(signal, parent_signal: request),
         do: {:ok, signal}
  end

  defp failure(instance, request, operation, code, retryable \\ false) do
    data = %{
      "operation" => operation,
      "request_id" => request.data["request_id"],
      "code" => code,
      "retryable" => retryable
    }

    with {:ok, signal} <-
           OperationFailed.new(data,
             source: Events.source(instance),
             subject: Identity.room_subject(request.data["room_id"])
           ),
         {:ok, signal} <- Context.attach(signal, parent_signal: request),
         do: {:ok, signal}
  end

  defp result_subject(request, result),
    do:
      Identity.room_subject(
        request.data["room_id"] ||
          if(is_map(result),
            do: result["room_id"] || if(request.type == Jido.Messaging.Signal.CreateRoom.type(), do: result["id"])
          )
      )

  defp known_role(nil), do: :user
  defp known_role(role), do: Enum.find([:user, :assistant, :system, :tool], &(Atom.to_string(&1) == role))
  defp publish({:ok, signal}, instance), do: Dispatch.emit(instance, signal)
  defp publish(error, _instance), do: error
end
