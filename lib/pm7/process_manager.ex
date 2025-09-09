defmodule Pm7.ProcessManager do
  @moduledoc """
  Main process management GenServer for PM7.

  Manages spawning, monitoring, and lifecycle of Node.js processes.
  Uses ETS for fast access and SQLite for persistence.
  """

  use GenServer
  require Logger

  alias Pm7.ExecWrapper

  # Client API

  @doc """
  Start the ProcessManager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a new process with the given configuration.
  """
  def start_process(config) do
    GenServer.call(__MODULE__, {:start_process, config})
  end

  @doc """
  Stop a process by ID.
  """
  def stop_process(process_id) do
    GenServer.call(__MODULE__, {:stop_process, process_id})
  end

  @doc """
  Restart a process by ID.
  """
  def restart_process(process_id) do
    GenServer.call(__MODULE__, {:restart_process, process_id})
  end

  @doc """
  Get the status of a specific process.
  """
  def get_process_status(process_id) do
    GenServer.call(__MODULE__, {:get_process_status, process_id})
  end

  @doc """
  List all managed processes.
  """
  def list_processes do
    GenServer.call(__MODULE__, :list_processes)
  end

  @doc """
  Get process logs for a specific process.
  """
  def get_process_logs(process_id, limit \\ 100) do
    GenServer.call(__MODULE__, {:get_process_logs, process_id, limit})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting PM7 ProcessManager")

    # Set up process monitoring
    Process.flag(:trap_exit, true)

    # Initialize state
    state = %{
      processes: %{},
      monitors: %{},
      start_time: System.monotonic_time(:millisecond)
    }

    # Load existing processes from database if any
    {:ok, load_persisted_processes(state)}
  end

  @impl true
  def handle_call({:start_process, config}, _from, state) do
    case validate_process_config(config) do
      {:ok, validated_config} ->
        start_new_process(validated_config, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:stop_process, process_id}, _from, state) do
    case Map.get(state.processes, process_id) do
      nil ->
        {:reply, {:error, :process_not_found}, state}

      process_info ->
        stop_existing_process(process_id, process_info, state)
    end
  end

  @impl true
  def handle_call({:restart_process, process_id}, _from, state) do
    # Look up process from ETS instead of state, since stopped processes are removed from state
    case :ets.lookup(:pm7_processes, process_id) do
      [{^process_id, process_data}] ->
        restart_existing_process(process_id, process_data, state)

      [] ->
        {:reply, {:error, :process_not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_process_status, process_id}, _from, state) do
    case :ets.lookup(:pm7_processes, process_id) do
      [{^process_id, process_data}] ->
        {:reply, {:ok, process_data}, state}

      [] ->
        {:reply, {:error, :process_not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_processes, _from, state) do
    processes = :ets.tab2list(:pm7_processes)
    {:reply, {:ok, processes}, state}
  end

  @impl true
  def handle_call({:get_process_logs, process_id, limit}, _from, state) do
    logs = get_logs_from_ets(process_id, limit)
    {:reply, {:ok, logs}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Map.get(state.monitors, monitor_ref) do
      nil ->
        Logger.warning("Received DOWN message for unknown monitor: #{inspect(monitor_ref)}")
        {:noreply, state}

      process_id ->
        case Map.get(state.processes, process_id) do
          nil ->
            Logger.warning("Received DOWN message for unknown process: #{process_id}")
            {:noreply, state}

          process_info ->
            handle_process_exit(process_id, process_info, reason, state)
        end
    end
  end

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.info("ProcessManager received EXIT signal: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:stdout, _os_pid, data}, state) do
    Logger.debug("ProcessManager received stdout: #{inspect(data)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:stderr, _os_pid, data}, state) do
    Logger.debug("ProcessManager received stderr: #{inspect(data)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("ProcessManager received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp validate_process_config(config) do
    required_fields = [:name, :command, :cwd]

    case Enum.all?(required_fields, &Map.has_key?(config, &1)) do
      true ->
        {:ok, Map.put_new(config, :id, generate_process_id())}
      false ->
        missing = Enum.filter(required_fields, &(!Map.has_key?(config, &1)))
        {:error, {:missing_fields, missing}}
    end
  end

  defp start_new_process(config, state) do
    process_id = config.id
    timestamp = System.monotonic_time(:millisecond)

    case ExecWrapper.spawn_process(config) do
      {:ok, pid, os_pid} ->
        monitor_ref = Process.monitor(pid)

        # Preserve existing restart count if this is a restart
        existing_restarts = case :ets.lookup(:pm7_processes, process_id) do
          [{^process_id, existing_data}] -> Map.get(existing_data, :restarts, 0)
          [] -> 0
        end

        process_data = %{
          id: process_id,
          name: config.name,
          command: config.command,
          cwd: config.cwd,
          env: Map.get(config, :env, %{}),
          pid: pid,
          os_pid: os_pid,
          status: :running,
          started_at: timestamp,
          restarts: Map.get(config, :restarts, existing_restarts),
          auto_restart: Map.get(config, :auto_restart, false)
        }

        # Store in ETS
        :ets.insert(:pm7_processes, {process_id, process_data})

        # Update state
        new_processes = Map.put(state.processes, process_id, process_data)
        new_monitors = Map.put(state.monitors, monitor_ref, process_id)
        new_state = %{state | processes: new_processes, monitors: new_monitors}

        # Persist to database
        persist_process_config(process_data)

        # Broadcast process started
        broadcast_process_event(process_id, :started, process_data)

        Logger.info("Started process #{process_id} (#{config.name}) with PID #{os_pid}, restarts: #{process_data.restarts}")
        {:reply, {:ok, process_id}, new_state}

      {:error, reason} ->
        Logger.error("Failed to start process #{config.name}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  defp stop_existing_process(process_id, process_info, state) do
    case ExecWrapper.stop_process(process_info.pid) do
      :ok ->
        # Update ETS
        updated_data = %{process_info | status: :stopped}
        updated_data = Map.put(updated_data, :stopped_at, System.monotonic_time(:millisecond))
        :ets.insert(:pm7_processes, {process_id, updated_data})

        # Clean up state
        new_processes = Map.delete(state.processes, process_id)
        monitor_ref = find_monitor_ref_for_process(process_id, state.monitors)
        new_monitors = if monitor_ref do
          Process.demonitor(monitor_ref, [:flush])
          Map.delete(state.monitors, monitor_ref)
        else
          state.monitors
        end

        new_state = %{state | processes: new_processes, monitors: new_monitors}

        # Broadcast process stopped
        broadcast_process_event(process_id, :stopped, updated_data)

        Logger.info("Stopped process #{process_id}")
        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to stop process #{process_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  defp restart_existing_process(process_id, process_data, state) do
    # Get current restart count and increment it for manual restart
    current_restarts = Map.get(process_data, :restarts, 0)
    new_restart_count = current_restarts + 1

    # Check if process is currently running
    case process_data.status do
      :running ->
        # Process is running, stop it first then restart
        case stop_existing_process(process_id, process_data, state) do
          {:reply, :ok, new_state} ->
            # Wait a moment for cleanup
            Process.sleep(100)
            start_process_with_restart_count(process_id, process_data, new_restart_count, new_state)

          error ->
            error
        end

      _ ->
        # Process is not running, just start it with incremented restart count
        start_process_with_restart_count(process_id, process_data, new_restart_count, state)
    end
  end

  defp handle_process_exit(process_id, process_info, reason, state) do
    Logger.info("Process #{process_id} exited: #{inspect(reason)}")

    # Update process status - safely add fields
    timestamp = System.monotonic_time(:millisecond)
    updated_data = %{process_info |
      status: :exited,
      pid: nil,
      os_pid: nil
    }
    updated_data = Map.put(updated_data, :exit_reason, reason)
    updated_data = Map.put(updated_data, :stopped_at, timestamp)
    :ets.insert(:pm7_processes, {process_id, updated_data})

    # Clean up state
    new_processes = Map.delete(state.processes, process_id)
    monitor_ref = find_monitor_ref_for_process(process_id, state.monitors)
    new_monitors = if monitor_ref do
      Map.delete(state.monitors, monitor_ref)
    else
      state.monitors
    end

    new_state = %{state | processes: new_processes, monitors: new_monitors}

    # Broadcast process exit
    broadcast_process_event(process_id, :exited, updated_data)

    # Handle auto-restart if enabled and not a normal exit
    should_restart = Map.get(process_info, :auto_restart, false) and reason != :normal

    if should_restart do
      Logger.info("Auto-restarting process #{process_id}")

      # Increment restart count for auto-restart
      current_restarts = Map.get(process_info, :restarts, 0)
      new_restart_count = current_restarts + 1

      case start_process_with_restart_count(process_id, process_info, new_restart_count, new_state) do
        {:reply, {:ok, _}, final_state} ->
          {:noreply, final_state}

        {:reply, {:error, restart_reason}, final_state} ->
          Logger.error("Failed to auto-restart process #{process_id}: #{inspect(restart_reason)}")
          {:noreply, final_state}
      end
    else
      {:noreply, new_state}
    end
  end

  defp start_process_with_restart_count(process_id, process_data, restart_count, state) do
    # Create config from existing process data with specific restart count
    config = %{
      id: process_id,
      name: process_data.name,
      command: process_data.command,
      cwd: process_data.cwd,
      env: Map.get(process_data, :env, %{}),
      auto_restart: Map.get(process_data, :auto_restart, false),
      restarts: restart_count
    }

    start_new_process(config, state)
  end

  defp find_monitor_ref_for_process(process_id, monitors) do
    Enum.find_value(monitors, fn {ref, id} ->
      if id == process_id, do: ref, else: nil
    end)
  end

  defp generate_process_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp get_logs_from_ets(process_id, limit) do
    # Get logs for specific process, limited and ordered by timestamp
    match_spec = [{{:"$1", :"$2"}, [{:"=:=", {:element, 1, :"$2"}, process_id}], [:"$_"]}]

    :ets.select(:pm7_process_logs, match_spec)
    |> Enum.sort_by(fn {timestamp, _log} -> timestamp end, :desc)
    |> Enum.take(limit)
  end

  defp load_persisted_processes(state) do
    # TODO: Load processes from SQLite database
    # For now, return state as-is
    state
  end

  defp persist_process_config(_process_data) do
    # TODO: Persist to SQLite database
    :ok
  end

  defp broadcast_process_event(process_id, event, data) do
    Phoenix.PubSub.broadcast(
      Pm7.PubSub,
      "process_events",
      {:process_event, process_id, event, data}
    )
  end
end
