defmodule Jido.Messaging.Operations.Definitions do
  @moduledoc false

  alias Jido.Chat.Signal, as: ChatSignal
  alias Jido.Messaging.Signal
  alias Jido.Messaging.Signal.Schemas

  # Request definition, provider definition, operation, required action, result shape.
  @providers [
    {Signal.SendMessage, ChatSignal.SendMessage, :send_message, :post_message, :message},
    {Signal.SendFile, ChatSignal.SendFile, :send_file, :post_message, :message},
    {Signal.PostProviderMessage, ChatSignal.PostMessage, :post_message, :post_message, :message},
    {Signal.EditMessage, ChatSignal.EditMessage, :edit_message, :edit_message, :message},
    {Signal.DeleteMessage, ChatSignal.DeleteMessage, :delete_message, :delete_message, :acknowledgement},
    {Signal.StartTyping, ChatSignal.StartTyping, :start_typing, :start_typing, :acknowledgement},
    {Signal.FetchMetadata, ChatSignal.FetchMetadata, :fetch_metadata, :fetch_channel_metadata, :conversation},
    {Signal.FetchThread, ChatSignal.FetchThread, :fetch_thread, :fetch_thread, :thread},
    {Signal.FetchMessage, ChatSignal.FetchMessage, :fetch_message, :fetch_message, :message},
    {Signal.GetUser, ChatSignal.GetUser, :get_user, :lookup_user, :user},
    {Signal.FetchSubject, ChatSignal.FetchSubject, :fetch_subject, :fetch_thread, :subject},
    {Signal.GetThreadParticipants, ChatSignal.GetThreadParticipants, :get_thread_participants, :lookup_participant,
     :participants},
    {Signal.MarkAsRead, ChatSignal.MarkAsRead, :mark_as_read, :receive_message, :acknowledgement},
    {Signal.FetchMedia, ChatSignal.FetchMedia, :fetch_media, :fetch_message, :resource},
    {Signal.AddReaction, ChatSignal.AddReaction, :add_reaction, :add_reaction, :acknowledgement},
    {Signal.RemoveReaction, ChatSignal.RemoveReaction, :remove_reaction, :remove_reaction, :acknowledgement},
    {Signal.PostEphemeral, ChatSignal.PostEphemeral, :post_ephemeral, :post_message, :message},
    {Signal.PostChannelMessage, ChatSignal.PostChannelMessage, :post_channel_message, :post_channel_message, :message},
    {Signal.Stream, ChatSignal.Stream, :stream, :post_message, :message},
    {Signal.OpenModal, ChatSignal.OpenModal, :open_modal, :post_message, :modal},
    {Signal.LoadOptions, ChatSignal.LoadOptions, :load_options, :fetch_message, :options},
    {Signal.FetchMessages, ChatSignal.FetchMessages, :fetch_messages, :fetch_thread_messages, :message_page},
    {Signal.FetchChannelMessages, ChatSignal.FetchChannelMessages, :fetch_channel_messages, :fetch_channel_messages,
     :message_page},
    {Signal.ListThreads, ChatSignal.ListThreads, :list_threads, :list_threads, :thread_page},
    {Signal.OpenThread, ChatSignal.OpenThread, :open_thread, :post_message, :thread},
    {Signal.OpenDm, ChatSignal.OpenDm, :open_dm, :send_direct_message, :conversation}
  ]

  # Request definition, operation, required action, result shape.
  @runtime [
    {Signal.PostMessage, :post_message, :post_message, :message},
    {Signal.CreateRoom, :create_room, :post_message, :conversation},
    {Signal.ParticipantJoinedRequest, :participant_joined, :receive_message, :acknowledgement},
    {Signal.ParticipantLeftRequest, :participant_left, :receive_message, :acknowledgement},
    {Signal.SetPresence, :set_presence, :receive_message, :acknowledgement},
    {Signal.SetTyping, :set_typing, :receive_message, :acknowledgement},
    {Signal.AddRoomReaction, :add_room_reaction, :add_reaction, :acknowledgement},
    {Signal.RemoveRoomReaction, :remove_room_reaction, :remove_reaction, :acknowledgement},
    {Signal.MarkDelivered, :mark_delivered, :receive_message, :acknowledgement},
    {Signal.MarkRead, :mark_read, :receive_message, :acknowledgement}
  ]

  @tools [
    {:fetch_message, :message},
    {:fetch_channel_messages, :message_page},
    {:fetch_thread, :thread},
    {:fetch_thread_messages, :message_page},
    {:list_threads, :thread_page},
    {:lookup_participant, :user},
    {:lookup_user, :user},
    {:fetch_channel_metadata, :conversation},
    {:post_message, :message},
    {:post_channel_message, :message},
    {:send_direct_message, :message},
    {:start_typing, :acknowledgement},
    {:edit_message, :message},
    {:delete_message, :acknowledgement},
    {:add_reaction, :acknowledgement},
    {:remove_reaction, :acknowledgement},
    {:ensure_subscription, :subscription},
    {:list_subscriptions, :subscription},
    {:delete_subscription, :subscription}
  ]

  @route_operation "route_outbound"

  @requests Map.new(
              Enum.map(@providers, fn {request, provider, operation, action, shape} ->
                {request.type(),
                 %{
                   definition: request,
                   provider: provider,
                   operation: "provider." <> Atom.to_string(operation),
                   action: action,
                   shape: shape
                 }}
              end) ++
                Enum.map(@runtime, fn {request, operation, action, shape} ->
                  {request.type(),
                   %{
                     definition: request,
                     provider: nil,
                     operation: Atom.to_string(operation),
                     action: action,
                     shape: shape
                   }}
                end)
            )

  @provider_definitions Map.new(@providers, fn {_request, provider, operation, _action, _shape} ->
                          {"provider." <> Atom.to_string(operation), provider}
                        end)
  @tool_shapes @tools |> Enum.reject(fn {_action, shape} -> shape == :subscription end) |> Map.new()

  @completed Enum.map(@providers, fn {_request, _provider, operation, _action, shape} ->
               {"provider." <> Atom.to_string(operation), shape, :provider}
             end) ++
               Enum.map(@runtime, fn {_request, operation, _action, shape} ->
                 {Atom.to_string(operation), shape, :runtime}
               end) ++
               [{@route_operation, :route, :runtime}] ++
               Enum.map(@tools, fn {operation, shape} -> {"tool." <> Atom.to_string(operation), shape, :tool} end)

  @runtime_codes [
    "unsupported",
    "provider_failure",
    "invalid_provider_result",
    "resource_expired",
    "resource_cancelled",
    "resource_failure",
    "authorization_denied",
    "authorization_store_failed",
    "persistence_failed",
    "observation_failed"
  ]
  @tool_codes [
    "policy_denied",
    "approval_required",
    "out_of_scope",
    "authorization_denied",
    "authorization_store_failed",
    "unsupported_operation",
    "provider_error",
    "not_found",
    "ambiguous",
    "missing_runtime_context",
    "missing_target",
    "missing_bridge_id",
    "missing_channel_id",
    "bridge_not_found",
    "bridge_disabled",
    "target_mismatch",
    "missing_scope",
    "invalid_scope",
    "workspace_scope_required",
    "invalid_policy",
    "invalid_provider_result",
    "resource_expired",
    "observation_failed",
    "workspace_scope_not_explicit"
  ]

  @doc false
  @spec all() :: map()
  def all, do: @requests

  @doc false
  @spec lookup(String.t()) :: map() | nil
  def lookup(type), do: Map.get(@requests, type)

  @doc false
  @spec provider_definition(String.t()) :: module() | nil
  def provider_definition(operation), do: Map.get(@provider_definitions, operation)

  @doc false
  @spec tool_shapes() :: map()
  def tool_shapes, do: @tool_shapes

  @doc false
  @spec route_operation() :: String.t()
  def route_operation, do: @route_operation

  @doc false
  @spec completed_schema() :: Zoi.schema()
  def completed_schema do
    @completed
    |> Enum.map(fn {operation, shape, domain} -> Schemas.completed_envelope(operation, shape, domain) end)
    |> Zoi.union()
  end

  @doc false
  @spec failed_schema() :: Zoi.schema()
  def failed_schema do
    runtime_operations =
      for {operation, _shape, domain} <- @completed, domain != :tool and operation != @route_operation, do: operation

    tool_operations = for {operation, _shape, :tool} <- @completed, do: operation

    Zoi.union([
      Schemas.failed_envelope(runtime_operations, @runtime_codes),
      Schemas.failed_envelope([@route_operation], @runtime_codes, %{
        "result" => Schemas.routed_result() |> Zoi.optional()
      }),
      Schemas.failed_envelope(tool_operations, @tool_codes)
    ])
  end
end
