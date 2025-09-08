defmodule Pm7.Repo do
  use Ecto.Repo,
    otp_app: :pm7,
    adapter: Ecto.Adapters.SQLite3
end
