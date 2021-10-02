defmodule Matrix2051.ClientPool do
  @moduledoc """
    Supervises matrix clients; one per user:homeserver.
  """

  use DynamicSupervisor

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    ret = DynamicSupervisor.init(strategy: :one_for_one)

    Task.start_link(fn ->
      DynamicSupervisor.start_child(
        __MODULE__,
        {Registry, name: Matrix2051.ClientRegistry}
      )
    end)

    ret
  end

  def start_or_get_client(matrix_id) do
    # TODO: there has to be a better way to atomically do this than create one and immediately
    # terminate it...
    {:ok, new_pid} =
      DynamicSupervisor.start_child(
        __MODULE__,
        {Matrix2051.Client, {matrix_id}}
      )

    case Registry.register({Matrix2051.ClientRegistry, keys: :duplicate}, matrix_id, new_pid) do
      {:ok, _} ->
        new_pid

      {:error, {:already_registered, existing_pid}} ->
        # There is already a client for that matrix_id. Terminate the client we just
        # created, then return the existing one
        :ok = DynamicSupervisor.terminate_child(Matrix2051.ClientSupervisor, new_pid)
        existing_pid
    end
  end
end