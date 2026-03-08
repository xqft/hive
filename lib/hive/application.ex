defmodule Hive.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Ensure directories exist
    File.mkdir_p!("priv/sqlite")
    File.mkdir_p!("priv/agents")

    children = [
      HiveWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:hive, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hive.PubSub},
      # Registries
      {Registry, keys: :unique, name: Hive.TopicRegistry},
      {Registry, keys: :unique, name: Hive.AgentRegistry},
      {Registry, keys: :unique, name: Hive.ContainerRegistry},
      {Registry, keys: :unique, name: Hive.TerminalRelayRegistry},
      # Persistence (SQLite) — must start before topics/agents
      Hive.Persistence,
      # Dynamic supervisors
      {DynamicSupervisor, name: Hive.TopicSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Hive.AgentSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Hive.ContainerSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Hive.TerminalRelaySup, strategy: :one_for_one},
      # Boot task — restores topics and agents from DB after supervisors are up
      {Task, &boot/0},
      # Web endpoint — last
      HiveWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Hive.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HiveWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp boot do
    Hive.Container.cleanup_orphaned_containers()
    restore_topics()
    restore_agents()
    Logger.info("Hive boot complete")
  end

  defp restore_topics do
    {:ok, topics} = Hive.Persistence.get_topics()

    for topic <- topics do
      type = if topic.type == "dm", do: :dm, else: :topic

      DynamicSupervisor.start_child(
        Hive.TopicSup,
        {Hive.Topic,
         name: topic.name,
         description: topic.description,
         type: type,
         created_by: topic.created_by}
      )
    end
  end

  defp restore_agents do
    {:ok, agents} = Hive.Persistence.get_agents()

    for agent <- agents do
      DynamicSupervisor.start_child(
        Hive.AgentSup,
        {Hive.Agent,
         name: agent.name, description: agent.description, personality: agent.personality}
      )
    end
  end

end
