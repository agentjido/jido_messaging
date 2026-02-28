defmodule Jido.Messaging.Security do
  @moduledoc """
  Centralized security boundary for inbound verification and outbound sanitization.

  Security checks are bounded with timeout budgets, failures are classified, and
  explicit policy determines whether failures deny or degrade.
  """

  alias Jido.Messaging.AdapterBridge
  alias Jido.Messaging.Security.DefaultAdapter

  @default_mode :permissive
  @default_verify_timeout_ms 50
  @default_sanitize_timeout_ms 50
  @telemetry_event [:jido_messaging, :security, :decision]

  @typedoc "Security boundary stage."
  @type stage :: :verify | :sanitize

  @typedoc "Security enforcement mode."
  @type mode :: :permissive | :strict

  @typedoc "Security classification for decisions and failures."
  @type classification :: :allow | :deny | :retry | :degrade

  @typedoc "Policy for verify failures."
  @type verify_failure_policy :: :allow | :deny

  @typedoc "Policy for sanitize failures."
  @type sanitize_failure_policy :: :allow_original | :deny

  @typedoc "Typed security denial returned to ingest/outbound callers."
  @type security_denial ::
          {:security_denied, stage(), atom() | tuple(), String.t()}

  @typedoc "Security decision metadata."
  @type decision :: %{
          required(:stage) => stage(),
          required(:classification) => classification(),
          required(:outcome) => atom(),
          required(:action) => atom(),
          required(:policy) => atom(),
          required(:channel) => module(),
          required(:adapter) => module(),
          required(:mode) => mode(),
          required(:elapsed_ms) => non_neg_integer(),
          optional(:reason) => term(),
          optional(:description) => String.t(),
          optional(:changed) => boolean(),
          optional(:fallback) => boolean()
        }

  @typedoc "Successful verify result envelope."
  @type verify_result :: {:ok, %{decision: decision(), metadata: map()}} | {:error, security_denial()}

  @typedoc "Successful sanitize result envelope."
  @type sanitize_result ::
          {:ok, term(), %{decision: decision(), metadata: map()}} | {:error, security_denial()}

  @callback verify_sender(
              channel_module :: module(),
              incoming_message :: map(),
              raw_payload :: map(),
              opts :: keyword()
            ) ::
              :ok | {:ok, map()} | {:deny, atom(), String.t()} | {:error, term()}

  @callback sanitize_outbound(channel_module :: module(), outbound :: term(), opts :: keyword()) ::
              {:ok, term()} | {:ok, term(), map()} | {:error, term()}

  @doc """
  Resolve runtime security config for an instance module.

  Config precedence (lowest to highest):

    1. Defaults
    2. `config :jido_messaging, :security, ...`
    3. `config <instance_module>, :security, ...`
    4. Runtime overrides passed as `security: [...]` in opts
  """
  @spec config(module(), keyword()) :: keyword()
  def config(instance_module, opts \\ []) when is_atom(instance_module) and is_list(opts) do
    default_opts = [
      adapter: DefaultAdapter,
      adapter_opts: [],
      mode: @default_mode,
      verify_timeout_ms: @default_verify_timeout_ms,
      sanitize_timeout_ms: @default_sanitize_timeout_ms,
      verify_failure_policy: nil,
      sanitize_failure_policy: nil
    ]

    global_opts = Application.get_env(:jido_messaging, :security, [])
    module_opts = Application.get_env(instance_module, :security, [])
    runtime_opts = security_overrides(opts)

    default_opts
    |> Keyword.merge(global_opts)
    |> Keyword.merge(module_opts)
    |> Keyword.merge(runtime_opts)
    |> normalize_config()
  end

  @doc """
  Verify an inbound sender through the configured security adapter.
  """
  @spec verify_sender(module(), module(), map(), map(), keyword()) :: verify_result()
  def verify_sender(instance_module, channel_module, incoming_message, raw_payload, opts \\ [])
      when is_atom(instance_module) and is_atom(channel_module) and is_map(incoming_message) and
             is_map(raw_payload) and is_list(opts) do
    config = config(instance_module, opts)
    timeout_ms = Keyword.fetch!(config, :verify_timeout_ms)

    case run_security_hook(
           fn ->
             config[:adapter].verify_sender(
               channel_module,
               incoming_message,
               raw_payload,
               config[:adapter_opts]
             )
           end,
           timeout_ms
         ) do
      {:ok, :ok, elapsed_ms} ->
        decision =
          build_decision(
            :verify,
            config,
            channel_module,
            :allow,
            :allow,
            :allow,
            elapsed_ms
          )

        emit_decision(instance_module, decision, timeout_ms)
        {:ok, %{decision: decision, metadata: %{}}}

      {:ok, {:ok, metadata}, elapsed_ms} when is_map(metadata) ->
        decision =
          build_decision(
            :verify,
            config,
            channel_module,
            :allow,
            :allow,
            :allow,
            elapsed_ms
          )

        emit_decision(instance_module, decision, timeout_ms)
        {:ok, %{decision: decision, metadata: metadata}}

      {:ok, {:deny, reason, description}, elapsed_ms}
      when is_atom(reason) and is_binary(description) ->
        decision =
          build_decision(
            :verify,
            config,
            channel_module,
            :deny,
            :deny,
            :deny,
            elapsed_ms,
            reason,
            description
          )

        emit_decision(instance_module, decision, timeout_ms)
        {:error, {:security_denied, :verify, reason, description}}

      {:ok, {:error, reason}, elapsed_ms} ->
        handle_verify_failure(instance_module, channel_module, config, timeout_ms, reason, elapsed_ms)

      {:ok, other, elapsed_ms} ->
        handle_verify_failure(
          instance_module,
          channel_module,
          config,
          timeout_ms,
          {:invalid_return, other},
          elapsed_ms
        )

      {:timeout, elapsed_ms} ->
        handle_verify_failure(instance_module, channel_module, config, timeout_ms, :timeout, elapsed_ms)

      {:error, reason, elapsed_ms} ->
        handle_verify_failure(
          instance_module,
          channel_module,
          config,
          timeout_ms,
          {:task_exit, reason},
          elapsed_ms
        )
    end
  end

  @doc """
  Sanitize outbound payload through the configured security adapter.
  """
  @spec sanitize_outbound(module(), module(), term(), keyword()) :: sanitize_result()
  def sanitize_outbound(instance_module, channel_module, outbound, opts \\ [])
      when is_atom(instance_module) and is_atom(channel_module) and is_list(opts) do
    config = config(instance_module, opts)
    timeout_ms = Keyword.fetch!(config, :sanitize_timeout_ms)

    case run_security_hook(
           fn ->
             config[:adapter].sanitize_outbound(channel_module, outbound, config[:adapter_opts])
           end,
           timeout_ms
         ) do
      {:ok, {:ok, sanitized}, elapsed_ms} ->
        metadata = %{changed: sanitized != outbound}

        decision =
          build_decision(
            :sanitize,
            config,
            channel_module,
            :allow,
            sanitize_outcome(metadata),
            :allow,
            elapsed_ms,
            nil,
            nil,
            metadata
          )

        emit_decision(instance_module, decision, timeout_ms)
        {:ok, sanitized, %{decision: decision, metadata: metadata}}

      {:ok, {:ok, sanitized, metadata}, elapsed_ms} when is_map(metadata) ->
        metadata = Map.put_new(metadata, :changed, sanitized != outbound)

        decision =
          build_decision(
            :sanitize,
            config,
            channel_module,
            :allow,
            sanitize_outcome(metadata),
            :allow,
            elapsed_ms,
            nil,
            nil,
            metadata
          )

        emit_decision(instance_module, decision, timeout_ms)
        {:ok, sanitized, %{decision: decision, metadata: metadata}}

      {:ok, {:error, reason}, elapsed_ms} ->
        handle_sanitize_failure(
          instance_module,
          channel_module,
          config,
          timeout_ms,
          outbound,
          reason,
          elapsed_ms
        )

      {:ok, other, elapsed_ms} ->
        handle_sanitize_failure(
          instance_module,
          channel_module,
          config,
          timeout_ms,
          outbound,
          {:invalid_return, other},
          elapsed_ms
        )

      {:timeout, elapsed_ms} ->
        handle_sanitize_failure(
          instance_module,
          channel_module,
          config,
          timeout_ms,
          outbound,
          :timeout,
          elapsed_ms
        )

      {:error, reason, elapsed_ms} ->
        handle_sanitize_failure(
          instance_module,
          channel_module,
          config,
          timeout_ms,
          outbound,
          {:task_exit, reason},
          elapsed_ms
        )
    end
  end

  defp handle_verify_failure(instance_module, channel_module, config, timeout_ms, reason, elapsed_ms) do
    classification = classify_failure(reason)
    action = verify_action(config, classification)
    description = failure_description(:verify, reason)

    decision =
      build_decision(
        :verify,
        config,
        channel_module,
        classification,
        verify_outcome(action),
        action,
        elapsed_ms,
        failure_reason(classification),
        description,
        %{fallback: action == :allow}
      )

    emit_decision(instance_module, decision, timeout_ms)

    case action do
      :allow ->
        {:ok, %{decision: decision, metadata: %{fallback: true}}}

      :deny ->
        {:error, {:security_denied, :verify, failure_reason(classification), description}}
    end
  end

  defp handle_sanitize_failure(
         instance_module,
         channel_module,
         config,
         timeout_ms,
         outbound,
         reason,
         elapsed_ms
       ) do
    classification = classify_failure(reason)
    action = sanitize_action(config, classification)
    description = failure_description(:sanitize, reason)

    decision =
      build_decision(
        :sanitize,
        config,
        channel_module,
        classification,
        sanitize_failure_outcome(action),
        action,
        elapsed_ms,
        failure_reason(classification),
        description,
        %{fallback: action == :allow_original}
      )

    emit_decision(instance_module, decision, timeout_ms)

    case action do
      :allow_original ->
        {:ok, outbound, %{decision: decision, metadata: %{fallback: true, changed: false}}}

      :deny ->
        {:error, {:security_denied, :sanitize, failure_reason(classification), description}}
    end
  end

  defp normalize_config(config) do
    mode = normalize_mode(config[:mode])

    verify_failure_policy =
      normalize_verify_failure_policy(config[:verify_failure_policy] || default_verify_failure_policy(mode))

    sanitize_failure_policy =
      normalize_sanitize_failure_policy(config[:sanitize_failure_policy] || default_sanitize_failure_policy(mode))

    adapter = normalize_adapter(config[:adapter])
    adapter_opts = normalize_keyword(config[:adapter_opts], [])

    config
    |> Keyword.put(:adapter, adapter)
    |> Keyword.put(:adapter_opts, adapter_opts)
    |> Keyword.put(:mode, mode)
    |> Keyword.put(:verify_timeout_ms, normalize_timeout(config[:verify_timeout_ms], @default_verify_timeout_ms))
    |> Keyword.put(
      :sanitize_timeout_ms,
      normalize_timeout(config[:sanitize_timeout_ms], @default_sanitize_timeout_ms)
    )
    |> Keyword.put(:verify_failure_policy, verify_failure_policy)
    |> Keyword.put(:sanitize_failure_policy, sanitize_failure_policy)
  end

  defp normalize_mode(:strict), do: :strict
  defp normalize_mode(:permissive), do: :permissive
  defp normalize_mode(_), do: @default_mode

  defp normalize_verify_failure_policy(:allow), do: :allow
  defp normalize_verify_failure_policy(:deny), do: :deny
  defp normalize_verify_failure_policy(_), do: default_verify_failure_policy(@default_mode)

  defp normalize_sanitize_failure_policy(:allow_original), do: :allow_original
  defp normalize_sanitize_failure_policy(:deny), do: :deny
  defp normalize_sanitize_failure_policy(_), do: default_sanitize_failure_policy(@default_mode)

  defp default_verify_failure_policy(:strict), do: :deny
  defp default_verify_failure_policy(:permissive), do: :allow

  defp default_sanitize_failure_policy(:strict), do: :deny
  defp default_sanitize_failure_policy(:permissive), do: :allow_original

  defp normalize_adapter(adapter) when is_atom(adapter) do
    with true <- Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :verify_sender, 4),
         true <- function_exported?(adapter, :sanitize_outbound, 3) do
      adapter
    else
      _ -> DefaultAdapter
    end
  end

  defp normalize_adapter(_), do: DefaultAdapter

  defp normalize_timeout(timeout_ms, _default) when is_integer(timeout_ms) and timeout_ms > 0, do: timeout_ms
  defp normalize_timeout(_timeout_ms, default), do: default

  defp normalize_keyword(value, _default) when is_list(value), do: value
  defp normalize_keyword(_value, default), do: default

  defp security_overrides(opts) do
    case Keyword.get(opts, :security, []) do
      value when is_list(value) -> value
      value when is_map(value) -> Map.to_list(value)
      _ -> []
    end
  end

  defp run_security_hook(fun, timeout_ms) when is_function(fun, 0) do
    started_at = System.monotonic_time(:millisecond)
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        {:ok, result, elapsed_ms(started_at)}

      {:exit, reason} ->
        {:error, reason, elapsed_ms(started_at)}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:timeout, elapsed_ms(started_at)}
    end
  end

  defp classify_failure(:timeout), do: :retry
  defp classify_failure({:task_exit, reason}), do: classify_failure(reason)

  defp classify_failure(reason) do
    root_reason = root_reason(reason)

    cond do
      denied_reason?(root_reason) ->
        :deny

      true ->
        case AdapterBridge.classify_failure(reason) do
          :recoverable -> :retry
          :fatal -> :degrade
          :degraded -> :degrade
        end
    end
  end

  defp verify_action(_config, :deny), do: :deny
  defp verify_action(config, _classification), do: config[:verify_failure_policy]

  defp sanitize_action(_config, :deny), do: :deny
  defp sanitize_action(config, _classification), do: config[:sanitize_failure_policy]

  defp sanitize_outcome(%{changed: true}), do: :sanitized
  defp sanitize_outcome(_metadata), do: :allow

  defp verify_outcome(:allow), do: :allow_fallback
  defp verify_outcome(:deny), do: :deny

  defp sanitize_failure_outcome(:allow_original), do: :allow_original_fallback
  defp sanitize_failure_outcome(:deny), do: :deny

  defp failure_reason(:deny), do: {:security_failure, :deny}
  defp failure_reason(:retry), do: {:security_failure, :retry}
  defp failure_reason(:degrade), do: {:security_failure, :degrade}

  defp build_decision(
         stage,
         config,
         channel_module,
         classification,
         outcome,
         action,
         elapsed_ms,
         reason \\ nil,
         description \\ nil,
         extra \\ %{}
       ) do
    %{
      stage: stage,
      classification: classification,
      outcome: outcome,
      action: action,
      policy: policy_for_stage(stage, config),
      channel: channel_module,
      adapter: config[:adapter],
      mode: config[:mode],
      elapsed_ms: elapsed_ms,
      reason: reason,
      description: description
    }
    |> Map.merge(extra)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp policy_for_stage(:verify, config), do: config[:verify_failure_policy]
  defp policy_for_stage(:sanitize, config), do: config[:sanitize_failure_policy]

  defp failure_description(stage, :timeout),
    do: "Security #{stage} timed out"

  defp failure_description(stage, reason),
    do: "Security #{stage} failed: #{inspect(reason)}"

  defp emit_decision(instance_module, decision, timeout_ms) do
    :telemetry.execute(
      @telemetry_event,
      %{
        elapsed_ms: Map.fetch!(decision, :elapsed_ms),
        timeout_ms: timeout_ms
      },
      decision
      |> Map.take([
        :stage,
        :channel,
        :classification,
        :outcome,
        :action,
        :policy,
        :mode,
        :adapter,
        :reason,
        :changed,
        :fallback
      ])
      |> Map.put(:instance_module, instance_module)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    )
  end

  defp root_reason(%{reason: reason}), do: root_reason(reason)
  defp root_reason({tag, _detail}) when is_atom(tag), do: tag
  defp root_reason(reason), do: reason

  defp denied_reason?(reason)
       when reason in [
              :denied,
              :unauthorized_sender,
              :forbidden_sender,
              :untrusted_sender,
              :spoofed_sender,
              :sender_claim_mismatch
            ],
       do: true

  defp denied_reason?(_reason), do: false

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end
end
