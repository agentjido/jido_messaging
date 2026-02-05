defmodule JidoMessaging.Gating do
  @moduledoc """
  Gating hook for authorization decisions.

  Provides a generic hook for applications to decide "should we respond?" without
  imposing opinionated policy logic. The policy decisions themselves are app-specific.

  ## Usage

  Implement the `JidoMessaging.Gating` behaviour in your application:

      defmodule MyApp.RequireMentionGater do
        @behaviour JidoMessaging.Gating

        @impl true
        def check(%MsgContext{was_mentioned: true}, _opts), do: :allow
        def check(%MsgContext{chat_type: :direct}, _opts), do: :allow
        def check(_ctx, _opts), do: {:deny, :not_mentioned, "Bot was not mentioned"}
      end

  Then pass gaters to the ingest pipeline:

      Ingest.ingest_incoming(messaging, channel, instance_id, incoming,
        gaters: [MyApp.RequireMentionGater, MyApp.RateLimitGater]
      )

  ## Result Types

    * `:allow` - Message should be processed
    * `{:deny, reason, description}` - Message should be rejected with reason atom and human-readable description

  ## What stays OUT of core

  This module provides only the gating hook mechanism. The following belong in the
  application layer or a separate `jido_messaging_policy` package:

    * Policy schemas (dm_policy, allow_from, require_mention, etc.)
    * Per-room policy overrides
    * Default policy implementations
  """

  alias JidoMessaging.MsgContext

  @type reason :: atom()
  @type description :: String.t()
  @type result :: :allow | {:deny, reason(), description()}

  @doc """
  Check if a message should be allowed through the gating pipeline.

  ## Parameters

    * `ctx` - The MsgContext for the incoming message
    * `opts` - Keyword options passed to the gater (application-specific)

  ## Returns

    * `:allow` - Message should be processed
    * `{:deny, reason, description}` - Message should be rejected
  """
  @callback check(ctx :: MsgContext.t(), opts :: keyword()) :: result()

  @doc """
  Run gating checks against a MsgContext.

  Evaluates each gater in order. Returns `:allow` if all gaters pass,
  or the first denial result if any gater denies the message.

  ## Parameters

    * `ctx` - The MsgContext for the incoming message
    * `gaters` - List of modules implementing the Gating behaviour
    * `opts` - Keyword options passed to each gater

  ## Examples

      case Gating.run_checks(ctx, [RateLimitGater, RequireMentionGater]) do
        :allow -> process_message(ctx)
        {:deny, reason, _} -> Logger.debug("Message denied: \#{reason}")
      end
  """
  @spec run_checks(MsgContext.t(), [module()], keyword()) :: result()
  def run_checks(%MsgContext{} = ctx, gaters, opts \\ []) when is_list(gaters) do
    Enum.reduce_while(gaters, :allow, fn gater, _acc ->
      case gater.check(ctx, opts) do
        :allow -> {:cont, :allow}
        {:deny, _, _} = denial -> {:halt, denial}
      end
    end)
  end

  @doc """
  Checks if a module implements the Gating behaviour.
  """
  @spec implements?(module()) :: boolean()
  def implements?(module) do
    function_exported?(module, :check, 2)
  end
end
