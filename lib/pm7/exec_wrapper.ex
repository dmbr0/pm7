defmodule Pm7.ExecWrapper do
  @moduledoc """
  Wrapper module for erlexec library to manage external processes.

  Provides a clean interface for spawning, monitoring, and controlling
  Node.js processes with proper logging and error handling.
  """

  require Logger

  @doc """
  Spawn a new external process using erlexec.

  Returns {:ok, pid, os_pid} on success or {:error, reason} on failure.
  """
  def spawn_process(config) do
    exec_opts = build_exec_options(config)
    command_with_args = build_command(config.command)

    Logger.debug("Spawning process with command: #{inspect(command_with_args)}")
    Logger.debug("Exec options: #{inspect(exec_opts)}")

    case :exec.run(command_with_args, exec_opts) do
      {:ok, pid, os_pid} ->
        Logger.info("Successfully spawned process - PID: #{inspect(pid)}, OS PID: #{os_pid}")
        {:ok, pid, os_pid}

      {:error, reason} ->
        Logger.error("Failed to spawn process: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stop a process gracefully, with fallback to force kill.
  """
  def stop_process(pid) when is_pid(pid) do
    try do
      # First try graceful shutdown
      case :exec.stop(pid) do
        :ok ->
          Logger.info("Process #{inspect(pid)} stopped gracefully")
          :ok

        {:error, :not_found} ->
          Logger.warning("Process #{inspect(pid)} not found when stopping")
          :ok

        {:error, reason} ->
          Logger.warning("Graceful stop failed for #{inspect(pid)}: #{inspect(reason)}, trying force kill")
          force_kill_process(pid)
      end
    catch
      :exit, reason ->
        Logger.error("Error stopping process #{inspect(pid)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def stop_process(pid) do
    {:error, {:invalid_pid, pid}}
  end

  @doc """
  Force kill a process.
  """
  def force_kill_process(pid) when is_pid(pid) do
    try do
      case :exec.kill(pid, 9) do
        :ok ->
          Logger.info("Process #{inspect(pid)} force killed")
          :ok

        {:error, reason} ->
          Logger.error("Force kill failed for #{inspect(pid)}: #{inspect(reason)}")
          {:error, reason}
      end
    catch
      :exit, reason ->
        Logger.error("Error force killing process #{inspect(pid)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get process information.
  """
  def get_process_info(pid) when is_pid(pid) do
    try do
      case :exec.which_children() do
        children when is_list(children) ->
          case Enum.find(children, fn {child_pid, _os_pid} -> child_pid == pid end) do
            {^pid, os_pid} ->
              {:ok, %{pid: pid, os_pid: os_pid, status: :running}}

            nil ->
              {:error, :not_found}
          end

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, reason ->
        {:error, reason}
    end
  end

  @doc """
  Send a signal to a process.
  """
  def send_signal(pid, signal) when is_pid(pid) and is_integer(signal) do
    try do
      case :exec.kill(pid, signal) do
        :ok ->
          Logger.debug("Sent signal #{signal} to process #{inspect(pid)}")
          :ok

        {:error, reason} ->
          Logger.error("Failed to send signal #{signal} to #{inspect(pid)}: #{inspect(reason)}")
          {:error, reason}
      end
    catch
      :exit, reason ->
        {:error, reason}
    end
  end

  # Private functions

  defp build_exec_options(config) do
    base_opts = [
      :stdout,
      :stderr,
      {:cd, config.cwd},
      {:env, build_env_list(config)},
      :monitor,
      {:kill_timeout, 5000},
      {:nice, 0}
    ]

    # Add any additional options from config
    additional_opts = Map.get(config, :exec_opts, [])
    base_opts ++ additional_opts
  end

  defp build_env_list(config) do
    base_env = System.get_env()
    custom_env = Map.get(config, :env, %{})

    # Merge base environment with custom environment
    merged_env = Map.merge(base_env, custom_env)

    # Convert to list of tuples for erlexec, filtering out nil/empty values
    merged_env
    |> Enum.filter(fn {_key, value} ->
      value != nil and value != ""
    end)
    |> Enum.map(fn {key, value} ->
      {to_charlist(key), to_charlist(value)}
    end)
  end

  defp build_command(command) when is_binary(command) do
    # Parse command string into command and arguments
    case String.split(command, " ", trim: true) do
      [] ->
        raise ArgumentError, "Empty command provided"

      [cmd] ->
        [to_charlist(cmd)]

      [cmd | args] ->
        [to_charlist(cmd) | Enum.map(args, &to_charlist/1)]
    end
  end

  defp build_command(command) when is_list(command) do
    # Assume it's already a list of command and arguments
    Enum.map(command, fn
      item when is_binary(item) -> to_charlist(item)
      item when is_list(item) -> item
      item -> to_charlist(to_string(item))
    end)
  end

  defp build_command(command) do
    raise ArgumentError, "Command must be a string or list, got: #{inspect(command)}"
  end
end
