defmodule Pm7.ProcessRecord do
  @moduledoc """
  Defines the structure and utilities for process records in PM7.

  Process records contain all information about managed processes,
  including configuration, runtime state, and statistics.
  """

  @type status :: :starting | :running | :stopping | :stopped | :exited | :errored

  @type t :: %__MODULE__{
    id: String.t(),
    name: String.t(),
    command: String.t(),
    cwd: String.t(),
    env: map(),
    pid: pid() | nil,
    os_pid: non_neg_integer() | nil,
    status: status(),
    started_at: integer() | nil,
    stopped_at: integer() | nil,
    restarts: non_neg_integer(),
    auto_restart: boolean(),
    max_restarts: non_neg_integer(),
    restart_delay: non_neg_integer(),
    exit_reason: term() | nil,
    cpu_usage: float() | nil,
    memory_usage: non_neg_integer() | nil,
    uptime: non_neg_integer() | nil
  }

  defstruct [
    :id,
    :name,
    :command,
    :cwd,
    :env,
    :pid,
    :os_pid,
    :status,
    :started_at,
    :stopped_at,
    :restarts,
    :auto_restart,
    :max_restarts,
    :restart_delay,
    :exit_reason,
    :cpu_usage,
    :memory_usage,
    :uptime
  ]

  @doc """
  Create a new process record from configuration.
  """
  def new(config) do
    %__MODULE__{
      id: Map.get(config, :id),
      name: Map.get(config, :name),
      command: Map.get(config, :command),
      cwd: Map.get(config, :cwd),
      env: Map.get(config, :env, %{}),
      status: :starting,
      restarts: 0,
      auto_restart: Map.get(config, :auto_restart, false),
      max_restarts: Map.get(config, :max_restarts, 10),
      restart_delay: Map.get(config, :restart_delay, 1000)
    }
  end

  @doc """
  Update process record with runtime information.
  """
  def update_runtime_info(record, pid, os_pid) do
    timestamp = System.monotonic_time(:millisecond)

    %{record |
      pid: pid,
      os_pid: os_pid,
      status: :running,
      started_at: timestamp
    }
  end

  @doc """
  Mark process as stopped.
  """
  def mark_stopped(record, reason \\ :normal) do
    timestamp = System.monotonic_time(:millisecond)

    %{record |
      status: :stopped,
      stopped_at: timestamp,
      exit_reason: reason,
      pid: nil,
      os_pid: nil
    }
  end

  @doc """
  Mark process as exited.
  """
  def mark_exited(record, reason) do
    timestamp = System.monotonic_time(:millisecond)

    %{record |
      status: :exited,
      stopped_at: timestamp,
      exit_reason: reason,
      pid: nil,
      os_pid: nil
    }
  end

  @doc """
  Increment restart counter.
  """
  def increment_restarts(record) do
    %{record | restarts: record.restarts + 1}
  end

  @doc """
  Update process statistics.
  """
  def update_stats(record, cpu_usage, memory_usage) do
    uptime = if record.started_at do
      System.monotonic_time(:millisecond) - record.started_at
    else
      nil
    end

    %{record |
      cpu_usage: cpu_usage,
      memory_usage: memory_usage,
      uptime: uptime
    }
  end

  @doc """
  Check if process can be restarted based on restart policy.
  """
  def can_restart?(record) do
    record.auto_restart and record.restarts < record.max_restarts
  end

  @doc """
  Convert process record to map for serialization.
  """
  def to_map(record) do
    Map.from_struct(record)
  end

  @doc """
  Create process record from map.
  """
  def from_map(map) when is_map(map) do
    struct(__MODULE__, map)
  end

  @doc """
  Validate process configuration.
  """
  def validate_config(config) do
    required_fields = [:name, :command, :cwd]
    errors = []

    errors = Enum.reduce(required_fields, errors, fn field, acc ->
      case Map.get(config, field) do
        nil -> [{:missing_field, field} | acc]
        "" -> [{:empty_field, field} | acc]
        _ -> acc
      end
    end)

    # Validate command exists and is executable
    errors = case Map.get(config, :command) do
      nil -> errors
      command ->
        case validate_command(command) do
          :ok -> errors
          {:error, reason} -> [{:invalid_command, reason} | errors]
        end
    end

    # Validate working directory exists
    errors = case Map.get(config, :cwd) do
      nil -> errors
      cwd ->
        case File.dir?(cwd) do
          true -> errors
          false -> [{:invalid_cwd, "Directory does not exist: #{cwd}"} | errors]
        end
    end

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  # Private functions

  defp validate_command(command) when is_binary(command) do
    case String.split(command, " ", trim: true) do
      [] -> {:error, "Empty command"}
      [cmd | _] -> validate_executable(cmd)
    end
  end

  defp validate_command(_), do: {:error, "Command must be a string"}

  defp validate_executable(cmd) do
    case System.find_executable(cmd) do
      nil -> {:error, "Executable not found: #{cmd}"}
      _ -> :ok
    end
  end
end
