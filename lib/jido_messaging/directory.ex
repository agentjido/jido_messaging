defmodule Jido.Messaging.Directory do
  @moduledoc """
  Unified directory lookup and search APIs.

  Directory adapters expose consistent behavior for participant and room
  resolution. Lookup returns a single deterministic match and reports
  `{:ambiguous, matches}` when a query maps to multiple entities.
  """

  alias Jido.Messaging.Runtime

  @typedoc "Supported directory entity targets."
  @type target :: :participant | :room

  @typedoc "Directory query map consumed by adapters."
  @type query :: map()

  @typedoc "Lookup contract for directory adapters."
  @type lookup_result :: {:ok, map()} | {:error, :not_found | {:ambiguous, [map()]} | term()}

  @typedoc "Search contract for directory adapters."
  @type search_result :: {:ok, [map()]} | {:error, term()}

  @callback lookup(adapter_state :: term(), target(), query()) :: lookup_result()
  @callback search(adapter_state :: term(), target(), query()) :: search_result()

  @doc "Lookup a single directory entity for an instance module."
  @spec lookup(module(), target(), query(), keyword()) :: lookup_result()
  def lookup(instance_module, target, query, opts \\ [])
      when is_atom(instance_module) and is_atom(target) and is_map(query) and is_list(opts) do
    runtime = instance_module.__jido_messaging__(:runtime)
    {adapter, adapter_state} = Runtime.get_persistence(runtime)
    adapter.directory_lookup(adapter_state, target, query, opts)
  end

  @doc "Search directory entities for an instance module."
  @spec search(module(), target(), query(), keyword()) :: search_result()
  def search(instance_module, target, query, opts \\ [])
      when is_atom(instance_module) and is_atom(target) and is_map(query) and is_list(opts) do
    runtime = instance_module.__jido_messaging__(:runtime)
    {adapter, adapter_state} = Runtime.get_persistence(runtime)
    adapter.directory_search(adapter_state, target, query, opts)
  end
end
