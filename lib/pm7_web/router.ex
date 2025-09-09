defmodule Pm7Web.Router do
  use Pm7Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Pm7Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Pm7Web do
    pipe_through :browser

    get "/", PageController, :home
    live "/processes", ProcessLive, :index
    live "/dashboard", ProcessLive, :index
  end

  # API routes for TUI interface
  scope "/api", Pm7Web do
    pipe_through :api

    get "/processes", ProcessController, :index
    post "/processes", ProcessController, :create
    get "/processes/:id", ProcessController, :show
    put "/processes/:id", ProcessController, :update
    delete "/processes/:id", ProcessController, :delete
    post "/processes/:id/start", ProcessController, :start
    post "/processes/:id/stop", ProcessController, :stop
    post "/processes/:id/restart", ProcessController, :restart
    get "/processes/:id/logs", ProcessController, :logs
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:pm7, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: Pm7Web.Telemetry
    end
  end
end
