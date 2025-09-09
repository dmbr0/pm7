defmodule Pm7Web.ProcessController do
  @moduledoc """
  JSON API controller for process management.

  Provides REST endpoints for the BubbleTea TUI interface
  to interact with the PM7 process manager.
  """

  use Pm7Web, :controller

  alias Pm7.ProcessManager
  require Logger

  @doc """
  GET /api/processes
  List all processes
  """
  def index(conn, _params) do
    case ProcessManager.list_processes() do
      {:ok, processes} ->
        # Convert ETS tuples to maps for JSON serialization
        process_list = Enum.map(processes, fn {id, data} ->
          # Convert PIDs to strings for JSON serialization
          data
          |> Map.put(:id, id)
          |> Map.update(:pid, nil, fn pid -> if pid, do: inspect(pid), else: nil end)
          |> Map.update(:os_pid, nil, fn os_pid -> os_pid end)
        end)

        json(conn, %{
          status: "success",
          data: process_list
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          status: "error",
          message: "Failed to list processes",
          error: inspect(reason)
        })
    end
  end

  @doc """
  POST /api/processes
  Start a new process
  """
  def create(conn, params) do
    config = %{
      name: Map.get(params, "name"),
      command: Map.get(params, "command"),
      cwd: Map.get(params, "cwd", System.get_env("PWD") || "/tmp"),
      env: Map.get(params, "env", %{}),
      auto_restart: Map.get(params, "auto_restart", false)
    }

    case ProcessManager.start_process(config) do
      {:ok, process_id} ->
        case ProcessManager.get_process_status(process_id) do
          {:ok, process_data} ->
            conn
            |> put_status(:created)
            |> json(%{
              status: "success",
              message: "Process started successfully",
              data: Map.put(process_data, :id, process_id)
            })

          {:error, _} ->
            conn
            |> put_status(:created)
            |> json(%{
              status: "success",
              message: "Process started successfully",
              data: %{id: process_id}
            })
        end

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          status: "error",
          message: "Failed to start process",
          error: inspect(reason)
        })
    end
  end

  @doc """
  GET /api/processes/:id
  Get specific process details
  """
  def show(conn, %{"id" => process_id}) do
    case ProcessManager.get_process_status(process_id) do
      {:ok, process_data} ->
        json(conn, %{
          status: "success",
          data: Map.put(process_data, :id, process_id)
        })

      {:error, :process_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          status: "error",
          message: "Process not found"
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          status: "error",
          message: "Failed to get process status",
          error: inspect(reason)
        })
    end
  end

  @doc """
  POST /api/processes/:id/start
  Start a stopped process
  """
  def start(conn, %{"id" => process_id}) do
    case ProcessManager.restart_process(process_id) do
      {:ok, _} ->
        json(conn, %{
          status: "success",
          message: "Process started successfully"
        })

      {:error, :process_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          status: "error",
          message: "Process not found"
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          status: "error",
          message: "Failed to start process",
          error: inspect(reason)
        })
    end
  end

  @doc """
  POST /api/processes/:id/stop
  Stop a running process
  """
  def stop(conn, %{"id" => process_id}) do
    case ProcessManager.stop_process(process_id) do
      :ok ->
        json(conn, %{
          status: "success",
          message: "Process stopped successfully"
        })

      {:error, :process_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          status: "error",
          message: "Process not found"
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          status: "error",
          message: "Failed to stop process",
          error: inspect(reason)
        })
    end
  end

  @doc """
  POST /api/processes/:id/restart
  Restart a process
  """
  def restart(conn, %{"id" => process_id}) do
    case ProcessManager.restart_process(process_id) do
      {:ok, _} ->
        json(conn, %{
          status: "success",
          message: "Process restarted successfully"
        })

      {:error, :process_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          status: "error",
          message: "Process not found"
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          status: "error",
          message: "Failed to restart process",
          error: inspect(reason)
        })
    end
  end

  @doc """
  DELETE /api/processes/:id
  Remove a process (stop and delete)
  """
  def delete(conn, %{"id" => process_id}) do
    with :ok <- ProcessManager.stop_process(process_id) do
      # Remove from ETS tables
      :ets.delete(:pm7_processes, process_id)
      :ets.delete(:pm7_process_stats, process_id)

      # Remove logs for this process
      match_spec = [{{:"$1", :"$2"}, [{:"=:=", {:element, 1, :"$2"}, process_id}], [:"$1"]}]
      log_keys = :ets.select(:pm7_process_logs, match_spec)
      Enum.each(log_keys, &:ets.delete(:pm7_process_logs, &1))

      json(conn, %{
        status: "success",
        message: "Process removed successfully"
      })
    else
      {:error, :process_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          status: "error",
          message: "Process not found"
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          status: "error",
          message: "Failed to remove process",
          error: inspect(reason)
        })
    end
  end

  @doc """
  GET /api/processes/:id/logs
  Get process logs
  """
  def logs(conn, %{"id" => process_id} = params) do
    limit = String.to_integer(Map.get(params, "limit", "100"))

    case ProcessManager.get_process_logs(process_id, limit) do
      {:ok, logs} ->
        formatted_logs = Enum.map(logs, fn {timestamp, log_data} ->
          %{
            timestamp: timestamp,
            message: log_data.message,
            level: log_data.level,
            source: log_data.source
          }
        end)

        json(conn, %{
          status: "success",
          data: formatted_logs
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          status: "error",
          message: "Failed to get process logs",
          error: inspect(reason)
        })
    end
  end

  @doc """
  PUT /api/processes/:id
  Update process configuration (restart required)
  """
  def update(conn, _params) do
    # For now, just return not implemented
    # In the future, this could update process config and restart
    conn
    |> put_status(:not_implemented)
    |> json(%{
      status: "error",
      message: "Process update not yet implemented"
    })
  end
end
