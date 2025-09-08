defmodule Pm7Web.PageController do
  use Pm7Web, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
