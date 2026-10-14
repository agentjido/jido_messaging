defmodule Jido.Messaging.Signal.Schemas do
  @moduledoc false

  @messaging_statuses ["sending", "sent", "delivered", "read", "failed", "received", "pending", "updated", "deleted"]
  @tool_statuses ["sent", "received", "updated", "deleted", "pending", "failed"]

  @doc false
  @spec id() :: Zoi.schema()
  def id, do: Zoi.string() |> Zoi.min(1)

  @doc false
  @spec nullable_id() :: Zoi.schema()
  def nullable_id, do: Zoi.union([id(), Zoi.null()])

  @doc false
  @spec object(map()) :: Zoi.schema()
  def object(fields), do: Zoi.map(fields, unrecognized_keys: :error)

  @doc false
  @spec resource_ref() :: Zoi.schema()
  def resource_ref, do: resource_ref(["file", "media", "stream", "card", "modal", "result"])

  defp resource_ref(kinds) do
    object(%{
      "id" => id(),
      "scope" => Zoi.enum(["call"]),
      "binding_id" => id(),
      "kind" => Zoi.enum(kinds)
    })
  end

  @doc false
  @spec resource_result() :: Zoi.schema()
  def resource_result, do: object(%{"resource_ref" => resource_ref()})

  @doc false
  @spec sender() :: Zoi.schema()
  def sender do
    object(%{
      "id" => id(),
      "username" => Zoi.string() |> Zoi.optional(),
      "display_name" => Zoi.string() |> Zoi.optional(),
      "is_bot" => Zoi.boolean() |> Zoi.optional(),
      "is_self" => Zoi.boolean() |> Zoi.optional()
    })
  end

  @doc false
  @spec message(:provider | :runtime | :tool) :: Zoi.schema()
  def message(domain) do
    statuses = if domain == :tool, do: @tool_statuses, else: @messaging_statuses

    object(%{
      "id" => id(),
      "room_id" => id(),
      "text" => Zoi.string() |> Zoi.optional(),
      "sender" => sender() |> Zoi.optional(),
      "thread_id" => nullable_id() |> Zoi.optional(),
      "reply_to_id" => nullable_id() |> Zoi.optional(),
      "media" => Zoi.array(media()) |> Zoi.optional(),
      "timestamp" => Zoi.string() |> Zoi.optional(),
      "status" => Zoi.enum(statuses) |> Zoi.optional(),
      "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional()
    })
  end

  defp media do
    object(%{
      "kind" => Zoi.enum(["image", "audio", "video", "file"]),
      "resource_ref" => resource_ref(),
      "name" => Zoi.string() |> Zoi.optional(),
      "media_type" => Zoi.string() |> Zoi.optional(),
      "caption" => Zoi.string() |> Zoi.optional()
    })
  end

  defp conversation do
    object(%{
      "id" => id(),
      "name" => Zoi.string() |> Zoi.optional(),
      "kind" => Zoi.enum(["direct", "group", "channel", "thread", "unknown"]) |> Zoi.optional(),
      "topic" => Zoi.string() |> Zoi.optional()
    })
  end

  defp thread do
    object(%{
      "id" => id(),
      "room_id" => id(),
      "parent_message_id" => nullable_id() |> Zoi.optional(),
      "name" => Zoi.string() |> Zoi.optional(),
      "delivery_room_ref" => nullable_id() |> Zoi.optional()
    })
  end

  defp subject do
    object(%{
      "id" => id(),
      "room_id" => id(),
      "kind" => Zoi.enum(["conversation", "thread", "message"]),
      "title" => Zoi.string() |> Zoi.optional()
    })
  end

  defp acknowledgement, do: object(%{"acknowledged" => Zoi.boolean()})

  defp page(key, item) do
    object(%{
      key => Zoi.array(item),
      "next_cursor" => nullable_id(),
      "complete" => Zoi.boolean()
    })
  end

  defp participant_page do
    object(%{
      "participants" => Zoi.array(sender()),
      "complete" => Zoi.boolean(),
      "scope" => Zoi.enum(["conversation", "thread", "observed"]),
      "next_cursor" => nullable_id()
    })
  end

  defp modal, do: object(%{"opened" => Zoi.boolean(), "id" => id() |> Zoi.optional()})

  defp option do
    object(%{
      "label" => Zoi.string(),
      "value" => Zoi.string(),
      "description" => Zoi.string() |> Zoi.optional(),
      "url" => Zoi.string() |> Zoi.optional()
    })
  end

  defp options do
    object(%{
      "options" => Zoi.array(option()),
      "option_groups" =>
        Zoi.array(object(%{"label" => Zoi.string(), "options" => Zoi.array(option())})) |> Zoi.optional(),
      "complete" => Zoi.boolean()
    })
  end

  defp subscription do
    object(%{
      "id" => id() |> Zoi.optional(),
      "active" => Zoi.boolean() |> Zoi.optional(),
      "items" => Zoi.array(object(%{"id" => id(), "active" => Zoi.boolean() |> Zoi.optional()})) |> Zoi.optional(),
      "acknowledged" => Zoi.boolean() |> Zoi.optional()
    })
  end

  @doc false
  @spec routed_result() :: Zoi.schema()
  def routed_result do
    object(%{
      "attempted" => Zoi.integer() |> Zoi.gte(0),
      "delivery_mode" => Zoi.enum(["best_effort", "primary", "broadcast"]),
      "delivered" =>
        Zoi.array(object(%{"bridge_id" => id(), "message_id" => id(), "attempts" => Zoi.integer() |> Zoi.gte(1)})),
      "failed" =>
        Zoi.array(
          object(%{
            "bridge_id" => id(),
            "code" => Zoi.enum(["provider_failure", "unsupported", "authorization_denied", "persistence_failed"]),
            "retryable" => Zoi.boolean(),
            "attempts" => Zoi.integer() |> Zoi.gte(1)
          })
        )
    })
    |> with_resource()
  end

  @doc false
  @spec result(atom(), :provider | :runtime | :tool) :: Zoi.schema()
  # Runtime posting has a narrower resource contract than provider and tool posting.
  def result(:message, :runtime) do
    Zoi.union([message(:runtime), object(%{"resource_ref" => resource_ref(["result"])})])
  end

  def result(:message, domain), do: with_resource(message(domain))
  def result(:conversation, :runtime), do: conversation()
  def result(:acknowledgement, :runtime), do: acknowledgement()
  def result(:resource, _domain), do: resource_result()
  def result(:route, _domain), do: routed_result()
  def result(shape, domain), do: with_resource(result_shape(shape, domain))

  defp result_shape(:conversation, _domain), do: conversation()
  defp result_shape(:acknowledgement, _domain), do: acknowledgement()
  defp result_shape(:thread, _domain), do: thread()
  defp result_shape(:user, _domain), do: sender()
  defp result_shape(:subject, _domain), do: subject()
  defp result_shape(:participants, _domain), do: participant_page()
  defp result_shape(:modal, _domain), do: modal()
  defp result_shape(:options, _domain), do: options()
  defp result_shape(:message_page, domain), do: page("messages", message(domain))
  defp result_shape(:thread_page, _domain), do: page("threads", thread())
  defp result_shape(:subscription, _domain), do: subscription()

  defp with_resource(schema), do: Zoi.union([schema, resource_result()])

  @doc false
  @spec completed_envelope(String.t(), atom(), :provider | :runtime | :tool) :: Zoi.schema()
  def completed_envelope(operation, shape, domain) do
    fields = %{"operation" => Zoi.enum([operation]), "request_id" => id(), "result" => result(shape, domain)}
    fields = if domain in [:provider, :tool], do: Map.put(fields, "bridge_id", id()), else: fields
    object(fields)
  end

  @doc false
  @spec failed_envelope([String.t()], [String.t()], map()) :: Zoi.schema()
  def failed_envelope(operations, codes, extra \\ %{}) do
    object(
      Map.merge(
        %{
          "operation" => Zoi.enum(operations),
          "request_id" => id(),
          "code" => Zoi.enum(codes),
          "retryable" => Zoi.boolean()
        },
        extra
      )
    )
  end
end
