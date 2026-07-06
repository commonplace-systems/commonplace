defmodule CommonplaceWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CommonplaceWebWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:commonplace_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CommonplaceWeb.PubSub},
      # Per-peer deferral budget for the federation import endpoint
      # (CX-orfw.1 — bounds pending_imports contribution per peer).
      CommonplaceWebWeb.FederationPeerBudget,
      # CX-qat5.6 (M1 safe subset): per-connection browser write rate
      # limiter — the LiveView write handlers call
      # WriteRateLimit.check_and_record/1 before performing a write.
      CommonplaceWebWeb.WriteRateLimit,
      # Start to serve requests, typically the last entry
      CommonplaceWebWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CommonplaceWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CommonplaceWebWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
