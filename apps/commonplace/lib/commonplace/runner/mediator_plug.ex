defmodule Commonplace.Runner.MediatorPlug do
  @moduledoc false

  alias Commonplace.Runner.Mediator

  def init(opts), do: opts

  def call(conn, opts) do
    Mediator.serve(
      Keyword.fetch!(opts, :mediator),
      Keyword.fetch!(opts, :deployment_id),
      conn
    )
  end
end
