defmodule Jido.Messaging.Diagnostics do
  @moduledoc false

  alias Jido.Chat.Operations.{Definitions, Failure}

  @spec provider_result(Jido.Chat.Binding.t(), Jido.Signal.t(), term(), non_neg_integer()) :: :ok
  def provider_result(binding, request, result, duration) do
    operation =
      case Definitions.lookup(request.type) do
        {_, name, _, _, _} -> name
        _ -> :unknown
      end

    {outcome, class} =
      case result do
        {:ok, %{type: "jido.chat.operation.completed"}} -> {:completed, nil}
        {:ok, %{type: "jido.chat.operation.failed"} = signal} -> {:failed, Failure.class(binding, signal)}
        _ -> {:contract_error, nil}
      end

    :telemetry.execute(
      [:jido_messaging, :provider_call, :stop],
      %{duration: duration},
      Map.merge(correlation(request), %{stage: :provider, operation: operation, outcome: outcome, failure_class: class})
    )
  end

  @spec failure(atom(), term(), atom()) :: :ok
  def failure(stage, request, kind) do
    :telemetry.execute(
      [:jido_messaging, :execution, :failure],
      %{count: 1},
      Map.merge(correlation(request), %{stage: stage, failure_class: kind})
    )
  end

  defp correlation(%Jido.Signal{id: id, data: %{"request_id" => request_id}})
       when is_binary(id) and byte_size(id) in 1..128 and
              is_binary(request_id) and byte_size(request_id) in 1..128,
       do: %{signal_id: id, request_id: request_id}

  defp correlation(_), do: %{}
end
