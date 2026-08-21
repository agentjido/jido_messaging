defmodule Jido.Messaging.ChatActions.Policy do
  @moduledoc """
  Serializable approval policy for visible chat writes.

  Rules are checked in list order. An empty selector is a wildcard. The default
  result is `:needs_approval`, which makes visible writes safe by default.
  """

  @results [:allow, :deny, :needs_approval]
  @selector_keys [:actions, :adapters, :bridge_ids, :channels, :threads, :actors]

  defstruct default: :needs_approval, rules: [], metadata: %{}

  @type result :: :allow | :deny | :needs_approval
  @type rule :: %{
          required(:result) => result(),
          required(:actions) => [atom()],
          required(:adapters) => [atom()],
          required(:bridge_ids) => [String.t()],
          required(:channels) => [String.t()],
          required(:threads) => [String.t()],
          required(:actors) => [String.t()]
        }
  @type t :: %__MODULE__{default: result(), rules: [rule()], metadata: map()}

  @doc "Returns the safe default policy."
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc "Builds a policy from a struct or plain map."
  @spec new(map() | t()) :: t()
  def new(%__MODULE__{} = policy), do: policy

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      default: attrs |> get(:default) |> Kernel.||(:needs_approval) |> normalize_result(),
      rules: attrs |> get(:rules) |> Kernel.||([]) |> Enum.map(&normalize_rule/1),
      metadata: get(attrs, :metadata) || %{}
    }
  end

  @doc "Creates a safe policy with one narrow allow rule."
  @spec allow([atom()], keyword()) :: t()
  def allow(actions, opts \\ []) when is_list(actions) do
    rule = %{
      result: :allow,
      actions: actions,
      adapters: atom_list_opt(opts, :adapter),
      bridge_ids: list_opt(opts, :bridge_id),
      channels: list_opt(opts, :channel),
      threads: list_opt(opts, :thread),
      actors: list_opt(opts, :actor)
    }

    new(%{rules: [rule]})
  end

  @doc "Converts a policy to a JSON-safe plain map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = policy) do
    %{
      "default" => Atom.to_string(policy.default),
      "rules" => Enum.map(policy.rules, &serialize_rule/1),
      "metadata" => policy.metadata
    }
  end

  @doc "Builds a policy from serialized data."
  @spec from_map(map() | t()) :: t()
  def from_map(value), do: new(value)

  @doc false
  @spec evaluate(t(), map()) :: result()
  def evaluate(%__MODULE__{} = policy, audit) when is_map(audit) do
    case Enum.find(policy.rules, &matches?(&1, audit)) do
      nil -> policy.default
      rule -> rule.result
    end
  end

  defp matches?(rule, audit) do
    selector_matches?(rule.actions, audit.action) and
      selector_matches?(rule.adapters, audit.adapter) and
      selector_matches?(rule.bridge_ids, audit.bridge_id) and
      selector_matches?(rule.channels, audit.channel_id) and
      selector_matches?(rule.threads, audit.thread_id) and
      selector_matches?(rule.actors, audit.actor_id)
  end

  defp selector_matches?([], _value), do: true
  defp selector_matches?(values, value), do: value in values

  defp normalize_rule(rule) when is_map(rule) do
    %{
      result: rule |> get(:result) |> Kernel.||(:needs_approval) |> normalize_result(),
      actions: normalize_atoms(get(rule, :actions)),
      adapters: normalize_atoms(get(rule, :adapters)),
      bridge_ids: normalize_strings(get(rule, :bridge_ids)),
      channels: normalize_strings(get(rule, :channels)),
      threads: normalize_strings(get(rule, :threads)),
      actors: normalize_strings(get(rule, :actors))
    }
  end

  defp serialize_rule(rule) do
    Map.new([:result | @selector_keys], fn
      :result -> {"result", Atom.to_string(rule.result)}
      key -> {Atom.to_string(key), Enum.map(Map.fetch!(rule, key), &stringify/1)}
    end)
  end

  defp normalize_result(result) when result in @results, do: result

  defp normalize_result(result) when is_binary(result) do
    Enum.find(@results, fn item -> Atom.to_string(item) == result end) ||
      raise ArgumentError, "invalid policy result"
  end

  defp normalize_result(_result), do: raise(ArgumentError, "invalid policy result")

  defp normalize_atoms(nil), do: []

  defp normalize_atoms(values) do
    values
    |> List.wrap()
    |> Enum.map(fn
      value when is_atom(value) -> value
      value when is_binary(value) -> String.to_existing_atom(value)
    end)
  end

  defp normalize_strings(nil), do: []
  defp normalize_strings(values), do: values |> List.wrap() |> Enum.map(&stringify/1)
  defp atom_list_opt(opts, key), do: opts |> Keyword.get(key) |> normalize_atoms()
  defp list_opt(opts, key), do: opts |> Keyword.get(key) |> normalize_strings()

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
