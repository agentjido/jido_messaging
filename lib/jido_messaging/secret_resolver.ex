defmodule Jido.Messaging.SecretResolver do
  @moduledoc """
  Resolves durable bridge secret references at an adapter operation boundary.

  Configure a resolver globally or for one messaging module:

      config :jido_messaging, secret_resolver: MyApp.SecretResolver
      config MyApp.Messaging, secret_resolver: MyApp.SecretResolver

  A resolver receives the opaque stored reference and safe operation context:

      defmodule MyApp.SecretResolver do
        @behaviour Jido.Messaging.SecretResolver

        @impl true
        def resolve(reference, context) do
          MySecretManager.fetch(reference, context)
        end
      end

  The resolved value exists only in the adapter options for the current
  operation. Resolver error details are reduced to a classified reason so a
  provider cannot put a secret in diagnostics.
  """

  alias Jido.Messaging.{BridgeConfig, ConfigStore}

  @type secret_reference :: term()
  @type context :: %{
          required(:instance_module) => module(),
          required(:bridge_id) => String.t(),
          required(:adapter_module) => module(),
          required(:operation) => atom(),
          required(:credential) => atom() | String.t()
        }
  @type failure_category ::
          :resolver_not_configured | :not_found | :resolver_failed | :invalid_resolver_response
  @type failure ::
          {:secret_resolution_failed, String.t(), atom() | String.t(), failure_category()}

  @callback resolve(secret_reference(), context()) :: {:ok, term()} | {:error, term()}

  @doc "Adds operation-scoped credentials and bridge settings to adapter options."
  @spec adapter_opts(module(), String.t(), atom(), keyword()) :: {:ok, keyword()} | {:error, failure() | term()}
  def adapter_opts(instance_module, bridge_id, operation, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_atom(operation) and is_list(opts) do
    adapter_opts(instance_module, bridge_id, nil, operation, opts)
  end

  @doc "Adds operation-scoped credentials after checking the requested adapter."
  @spec adapter_opts(module(), String.t(), module(), atom(), keyword()) ::
          {:ok, keyword()} | {:error, failure() | term()}
  def adapter_opts(instance_module, bridge_id, adapter_module, operation, opts)
      when is_atom(instance_module) and is_binary(bridge_id) and
             (is_atom(adapter_module) or is_nil(adapter_module)) and is_atom(operation) and is_list(opts) do
    case ConfigStore.get_bridge_config(instance_module, bridge_id) do
      {:ok, %BridgeConfig{} = config} ->
        with :ok <- validate_adapter(config, adapter_module) do
          adapter_opts_for_config(instance_module, config, operation, opts)
        end

      {:error, :not_found} ->
        {:ok, opts}
    end
  end

  @doc "Adds credentials from a fetched bridge config to adapter options."
  @spec adapter_opts_for_config(module(), BridgeConfig.t(), atom(), keyword()) ::
          {:ok, keyword()} | {:error, failure() | term()}
  def adapter_opts_for_config(instance_module, %BridgeConfig{} = config, operation, opts)
      when is_atom(instance_module) and is_atom(operation) and is_list(opts) do
    with :ok <- BridgeConfig.validate_for_storage(config),
         {:ok, credentials} <- resolve_credentials(instance_module, config, operation) do
      {:ok,
       opts
       |> Keyword.put(:bridge_config, config)
       |> Keyword.put(:credentials, credentials)
       |> Keyword.put(:settings, config.opts)}
    end
  end

  @doc "Resolves all credential references for one bridge operation."
  @spec resolve_credentials(module(), BridgeConfig.t(), atom()) ::
          {:ok, map()} | {:error, failure() | term()}
  def resolve_credentials(instance_module, %BridgeConfig{} = config, operation)
      when is_atom(instance_module) and is_atom(operation) do
    refs = Map.get(config, :secret_refs, %{}) || %{}

    if map_size(refs) == 0 do
      {:ok, %{}}
    else
      resolve_references(instance_module, config, operation, refs)
    end
  end

  defp resolve_references(instance_module, config, operation, refs) do
    resolver = configured_resolver(instance_module)

    refs
    |> Enum.sort_by(fn {credential, _reference} -> to_string(credential) end)
    |> Enum.reduce_while({:ok, %{}}, fn {credential, reference}, {:ok, credentials} ->
      context = %{
        instance_module: instance_module,
        bridge_id: config.id,
        adapter_module: config.adapter_module,
        operation: operation,
        credential: credential
      }

      case resolve_one(resolver, reference, context) do
        {:ok, value} -> {:cont, {:ok, Map.put(credentials, credential, value)}}
        {:error, category} -> {:halt, {:error, failure(config.id, credential, category)}}
      end
    end)
  end

  defp configured_resolver(instance_module) do
    Application.get_env(instance_module, :secret_resolver) ||
      Application.get_env(:jido_messaging, :secret_resolver)
  end

  defp validate_adapter(_config, nil), do: :ok

  defp validate_adapter(%BridgeConfig{adapter_module: adapter_module}, adapter_module), do: :ok

  defp validate_adapter(%BridgeConfig{} = config, adapter_module) do
    {:error, {:bridge_adapter_mismatch, config.id, config.adapter_module, adapter_module}}
  end

  defp resolve_one(nil, _reference, _context), do: {:error, :resolver_not_configured}

  defp resolve_one(resolver, reference, context) when is_atom(resolver) do
    try do
      case resolver.resolve(reference, context) do
        {:ok, value} -> {:ok, value}
        {:error, :not_found} -> {:error, :not_found}
        {:error, _reason} -> {:error, :resolver_failed}
        _other -> {:error, :invalid_resolver_response}
      end
    rescue
      _exception -> {:error, :resolver_failed}
    catch
      _kind, _reason -> {:error, :resolver_failed}
    end
  end

  defp resolve_one(_resolver, _reference, _context), do: {:error, :resolver_not_configured}

  defp failure(bridge_id, credential, category) do
    {:secret_resolution_failed, bridge_id, credential, category}
  end
end
