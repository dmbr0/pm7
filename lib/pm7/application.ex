defmodule Pm7.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize ETS tables for process management
    :ets.new(:pm7_processes, [
      :set,
      :public,
      :named_table,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    :ets.new(:pm7_process_logs, [
      :ordered_set,
      :public,
      :named_table,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    :ets.new(:pm7_process_stats, [
      :set,
      :public,
      :named_table,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    children = [
      Pm7Web.Telemetry,
      Pm7.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:pm7, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:pm7, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pm7.PubSub},
      # Process management supervisor
      {Pm7.ProcessManager, []},
      # Start to serve requests, typically the last entry
      Pm7Web.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pm7.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Pm7Web.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
