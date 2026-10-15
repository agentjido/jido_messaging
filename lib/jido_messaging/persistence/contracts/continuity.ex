defmodule Jido.Messaging.Persistence.Contracts.Continuity do
  @moduledoc """
  Storage contract for continuity.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.JidokaDelegationEvent
  alias Jido.Messaging.ThreadContinuityLink

  @type state :: Jido.Messaging.Persistence.state()

  @callback save_jidoka_delegation_event(state, JidokaDelegationEvent.t()) ::
              {:ok, JidokaDelegationEvent.t()} | {:error, term()}

  @callback get_jidoka_delegation_event(state, String.t()) ::
              {:ok, JidokaDelegationEvent.t()} | {:error, :not_found | term()}

  @callback save_thread_continuity_link(state, ThreadContinuityLink.t()) ::
              {:ok, ThreadContinuityLink.t()} | {:error, term()}

  @callback get_thread_continuity_link(state, String.t()) ::
              {:ok, ThreadContinuityLink.t()} | {:error, :not_found | term()}
end
