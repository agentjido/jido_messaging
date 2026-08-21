defmodule Jido.Messaging.ChatActions.Result do
  @moduledoc "Stable serializable result helpers for scoped chat actions."

  @doc false
  @spec ok(atom(), map(), term(), map()) :: map()
  def ok(action, target, data, audit) do
    base(:ok, action, target, audit)
    |> Map.put(:data, data)
  end

  @doc false
  @spec error(atom(), atom(), map(), map()) :: map()
  def error(action, code, details \\ %{}, audit \\ %{}) do
    %{
      status: :error,
      code: code,
      action: action,
      details: details,
      audit: audit
    }
  end

  @doc false
  @spec denied(atom(), atom(), map()) :: map()
  def denied(action, code, audit) do
    %{
      status: :denied,
      code: code,
      action: action,
      audit: audit
    }
  end

  @doc false
  @spec approval_required(atom(), map()) :: map()
  def approval_required(action, audit) do
    %{
      status: :approval_required,
      code: :approval_required,
      action: action,
      audit: audit
    }
  end

  defp base(status, action, target, audit) do
    %{
      status: status,
      action: action,
      adapter: target.adapter,
      bridge_id: target.bridge_id,
      channel_id: target.channel_id,
      thread_id: target.thread_id,
      audit: audit
    }
  end
end
