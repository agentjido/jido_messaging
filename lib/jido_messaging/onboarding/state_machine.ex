defmodule Jido.Messaging.Onboarding.StateMachine do
  @moduledoc """
  Deterministic onboarding state transitions with persisted idempotency.
  """

  alias Jido.Messaging.Onboarding.Flow

  @transitions %{
    started: %{resolve_directory: :directory_resolved, cancel: :cancelled},
    directory_resolved: %{pair_identity: :paired, cancel: :cancelled},
    paired: %{complete: :completed, cancel: :cancelled},
    completed: %{},
    cancelled: %{}
  }

  @type transition :: :resolve_directory | :pair_identity | :complete | :cancel

  @type transition_result :: %{
          required(:onboarding_id) => String.t(),
          required(:transition) => transition(),
          required(:previous_status) => atom(),
          required(:status) => atom(),
          required(:idempotent) => boolean(),
          required(:classification) => :ok,
          optional(:completion_metadata) => map() | nil
        }

  @doc "Returns valid transitions for a status."
  @spec allowed_transitions(atom()) :: [transition()]
  def allowed_transitions(status) when is_atom(status) do
    @transitions
    |> Map.get(status, %{})
    |> Map.keys()
  end

  @doc "Apply a validated transition to a flow."
  @spec transition(Flow.t(), transition(), map(), keyword()) ::
          {:ok, Flow.t(), transition_result()}
          | {:error,
             {:invalid_transition, %{from: atom(), transition: transition(), allowed: [transition()], class: :fatal}}}
  def transition(%Flow{} = flow, transition, metadata, opts \\ [])
      when is_atom(transition) and is_map(metadata) and is_list(opts) do
    idempotency_key = normalize_idempotency_key(opts)

    case idempotency_hit(flow, idempotency_key) do
      {:hit, cached_result} ->
        {:ok, flow, Map.put(cached_result, :idempotent, true)}

      :miss ->
        do_transition(flow, transition, metadata, idempotency_key)
    end
  end

  defp do_transition(flow, transition, metadata, idempotency_key) do
    current_status = flow.status
    transition_map = Map.get(@transitions, current_status, %{})

    case Map.fetch(transition_map, transition) do
      {:ok, next_status} ->
        now = DateTime.utc_now()

        transition_record = %{
          transition: transition,
          from: current_status,
          to: next_status,
          metadata: metadata,
          idempotency_key: idempotency_key,
          inserted_at: now
        }

        side_effect = %{
          idempotency_key: idempotency_key,
          effect: transition,
          inserted_at: now
        }

        next_flow =
          flow
          |> apply_transition_metadata(transition, metadata)
          |> Map.put(:status, next_status)
          |> Map.put(:updated_at, now)
          |> Map.update!(:transitions, &(&1 ++ [transition_record]))
          |> Map.update!(:side_effects, &(&1 ++ [side_effect]))

        result = %{
          onboarding_id: flow.onboarding_id,
          transition: transition,
          previous_status: current_status,
          status: next_status,
          idempotent: false,
          classification: :ok,
          completion_metadata: next_flow.completion_metadata
        }

        next_flow = put_idempotency_result(next_flow, idempotency_key, result)

        {:ok, next_flow, result}

      :error ->
        {:error,
         {:invalid_transition,
          %{
            from: current_status,
            transition: transition,
            allowed: Map.keys(transition_map),
            class: :fatal
          }}}
    end
  end

  defp apply_transition_metadata(flow, :resolve_directory, metadata) do
    Map.put(flow, :directory_match, metadata)
  end

  defp apply_transition_metadata(flow, :pair_identity, metadata) do
    Map.put(flow, :pairing, metadata)
  end

  defp apply_transition_metadata(flow, :complete, metadata) do
    Map.put(flow, :completion_metadata, metadata)
  end

  defp apply_transition_metadata(flow, :cancel, metadata) do
    Map.put(flow, :completion_metadata, Map.put(metadata, :cancelled, true))
  end

  defp idempotency_hit(_flow, nil), do: :miss

  defp idempotency_hit(flow, idempotency_key) do
    case Map.fetch(flow.idempotency, idempotency_key) do
      {:ok, result} -> {:hit, result}
      :error -> :miss
    end
  end

  defp put_idempotency_result(flow, nil, _result), do: flow

  defp put_idempotency_result(flow, idempotency_key, result) do
    Map.put(flow, :idempotency, Map.put(flow.idempotency, idempotency_key, result))
  end

  defp normalize_idempotency_key(opts) do
    case Keyword.get(opts, :idempotency_key) do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end
end
