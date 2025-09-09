defmodule Pm7Web.ProcessLive do
  @moduledoc """
  LiveView for managing processes in PM7.

  Provides real-time interface for starting, stopping, and monitoring
  Node.js processes with live updates via Phoenix PubSub.
  """

  use Pm7Web, :live_view

  alias Pm7.ProcessManager
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to process events for real-time updates
      Phoenix.PubSub.subscribe(Pm7.PubSub, "process_events")
    end

    # Load initial process list
    {:ok, processes} = ProcessManager.list_processes()

    socket =
      socket
      |> assign(:processes, processes)
      |> assign(:page_title, "PM7 Process Manager")
      |> assign(:show_form, false)
      |> assign(:form_data, %{})

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :show_form, !socket.assigns.show_form)}
  end

  @impl true
  def handle_event("start_process", params, socket) do
    config = %{
      name: Map.get(params, "name", ""),
      command: Map.get(params, "command", ""),
      cwd: Map.get(params, "cwd", System.get_env("PWD") || "/tmp"),
      env: parse_env_string(Map.get(params, "env", "")),
      auto_restart: Map.get(params, "auto_restart") == "true"
    }

    case ProcessManager.start_process(config) do
      {:ok, process_id} ->
        socket =
          socket
          |> put_flash(:info, "Process started successfully: #{process_id}")
          |> assign(:show_form, false)
          |> assign(:form_data, %{})

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to start process: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop_process", %{"process_id" => process_id}, socket) do
    case ProcessManager.stop_process(process_id) do
      :ok ->
        socket = put_flash(socket, :info, "Process stopped: #{process_id}")
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to stop process: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("restart_process", %{"process_id" => process_id}, socket) do
    case ProcessManager.restart_process(process_id) do
      {:ok, _new_process_id} ->
        socket = put_flash(socket, :info, "Process restarted: #{process_id}")
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to restart process: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_process", %{"process_id" => process_id}, socket) do
    # Check if process exists in ETS (handles both running and stopped processes)
    case :ets.lookup(:pm7_processes, process_id) do
      [{^process_id, process_data}] ->
        # If process is running, stop it first
        if process_data.status == :running do
          ProcessManager.stop_process(process_id)
        end

        # Remove from ETS tables regardless of stop result
        :ets.delete(:pm7_processes, process_id)
        :ets.delete(:pm7_process_stats, process_id)

        # Remove logs for this process
        match_spec = [{{:"$1", :"$2"}, [{:"=:=", {:element, 1, :"$2"}, process_id}], [:"$1"]}]
        log_keys = :ets.select(:pm7_process_logs, match_spec)
        Enum.each(log_keys, &:ets.delete(:pm7_process_logs, &1))

        # Refresh the process list to update the UI
        {:ok, processes} = ProcessManager.list_processes()

        socket =
          socket
          |> put_flash(:info, "Process deleted: #{process_id}")
          |> assign(:processes, processes)

        {:noreply, socket}

      [] ->
        socket = put_flash(socket, :error, "Process not found: #{process_id}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh_processes", _params, socket) do
    {:ok, processes} = ProcessManager.list_processes()
    {:noreply, assign(socket, :processes, processes)}
  end

  @impl true
  def handle_info({:process_event, _process_id, _event, _data}, socket) do
    # Refresh process list when we receive process events
    {:ok, processes} = ProcessManager.list_processes()
    {:noreply, assign(socket, :processes, processes)}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("ProcessLive received unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Template will be in process_live.html.heex
  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-6">
      <div class="flex justify-between items-center mb-6">
        <h1 class="text-3xl font-bold">PM7 Process Manager</h1>
        <div class="flex gap-2">
          <button
            phx-click="refresh_processes"
            class="btn btn-secondary"
          >
            🔄 Refresh
          </button>
          <button
            phx-click="toggle_form"
            class="btn btn-primary"
          >
            ➕ New Process
          </button>
        </div>
      </div>

      <%= if @show_form do %>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title">Start New Process</h2>
            <form phx-submit="start_process" class="space-y-4">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Process Name</span>
                </label>
                <input
                  type="text"
                  name="name"
                  placeholder="e.g., my-app"
                  class="input input-bordered w-full"
                  required
                />
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Command</span>
                </label>
                <input
                  type="text"
                  name="command"
                  placeholder="e.g., node app.js"
                  class="input input-bordered w-full"
                  required
                />
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Working Directory</span>
                </label>
                <input
                  type="text"
                  name="cwd"
                  placeholder="/path/to/project"
                  class="input input-bordered w-full"
                  value={System.get_env("PWD") || "/tmp"}
                />
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Environment Variables (KEY=value, one per line)</span>
                </label>
                <textarea
                  name="env"
                  placeholder="NODE_ENV=production&#10;PORT=3000"
                  class="textarea textarea-bordered"
                ></textarea>
              </div>

              <div class="form-control">
                <label class="label cursor-pointer">
                  <span class="label-text">Auto Restart</span>
                  <input type="checkbox" name="auto_restart" value="true" class="checkbox" />
                </label>
              </div>

              <div class="card-actions justify-end">
                <button type="button" phx-click="toggle_form" class="btn btn-ghost">Cancel</button>
                <button type="submit" class="btn btn-primary">Start Process</button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <div class="grid gap-4">
        <%= if Enum.empty?(@processes) do %>
          <div class="alert alert-info">
            <span>No processes running. Start your first process by clicking "New Process".</span>
          </div>
        <% else %>
          <%= for {process_id, process_data} <- @processes do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <div class="flex justify-between items-start">
                  <div>
                    <h3 class="card-title text-lg">
                      <%= process_data.name %>
                      <div class={"badge " <> status_badge_class(process_data.status)}>
                        <%= process_data.status %>
                      </div>
                    </h3>
                    <p class="text-sm text-base-content/70">ID: <%= process_id %></p>
                    <p class="text-sm"><strong>Command:</strong> <%= process_data.command %></p>
                    <p class="text-sm"><strong>Working Dir:</strong> <%= process_data.cwd %></p>
                    <%= if process_data.os_pid do %>
                      <p class="text-sm"><strong>OS PID:</strong> <%= process_data.os_pid %></p>
                    <% end %>
                    <%= if process_data.started_at do %>
                      <p class="text-sm"><strong>Started:</strong> <%= format_timestamp(process_data.started_at) %></p>
                    <% end %>
                    <%= if process_data.restarts > 0 do %>
                      <p class="text-sm"><strong>Restarts:</strong> <%= process_data.restarts %></p>
                    <% end %>
                  </div>

                  <div class="card-actions">
                    <%= if process_data.status == :running do %>
                      <button
                        phx-click="stop_process"
                        phx-value-process_id={process_id}
                        class="btn btn-sm btn-error"
                      >
                        ⏹ Stop
                      </button>
                      <button
                        phx-click="restart_process"
                        phx-value-process_id={process_id}
                        class="btn btn-sm btn-warning"
                      >
                        🔄 Restart
                      </button>
                    <% else %>
                      <button
                        phx-click="restart_process"
                        phx-value-process_id={process_id}
                        class="btn btn-sm btn-success"
                      >
                        ▶ Start
                      </button>
                    <% end %>
                    <button
                      phx-click="delete_process"
                      phx-value-process_id={process_id}
                      class="btn btn-sm btn-outline btn-error"
                      onclick="return confirm('Are you sure you want to delete this process?')"
                    >
                      🗑 Delete
                    </button>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions

  defp status_badge_class(:running), do: "badge-success"
  defp status_badge_class(:stopped), do: "badge-error"
  defp status_badge_class(:exited), do: "badge-warning"
  defp status_badge_class(:starting), do: "badge-info"
  defp status_badge_class(_), do: "badge-ghost"

  defp format_timestamp(timestamp) when is_integer(timestamp) do
    datetime = DateTime.from_unix!(timestamp, :millisecond)
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  defp format_timestamp(_), do: "Unknown"

  defp parse_env_string(""), do: %{}
  defp parse_env_string(env_string) do
    env_string
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end
end
