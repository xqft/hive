defmodule Hive.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Ensure directories exist
    File.mkdir_p!("priv/sqlite")
    File.mkdir_p!("priv/agents")
    Hive.Media.ensure_upload_dir()

    children = [
      HiveWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:hive, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hive.PubSub},
      # Registries
      {Registry, keys: :unique, name: Hive.TopicRegistry},
      {Registry, keys: :unique, name: Hive.AgentRegistry},
      {Registry, keys: :unique, name: Hive.ContainerRegistry},
      {Registry, keys: :unique, name: Hive.EventSourceRegistry},
      {Registry, keys: :unique, name: Hive.TerminalRelayRegistry},
      # Persistence (SQLite) — must start before topics/agents
      Hive.Persistence,
      # Dynamic supervisors
      {DynamicSupervisor, name: Hive.TopicSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Hive.AgentSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Hive.ContainerSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Hive.EventSourceSup, strategy: :one_for_one},
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
    restore_event_sources()
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
      # Stop stale agent processes (e.g. surviving from hot reload) so they
      # restart with fresh SDK subprocesses and pick up any code changes.
      case Registry.lookup(Hive.AgentRegistry, agent.name) do
        [{pid, _}] ->
          Logger.info("Stopping stale agent #{agent.name} for restart")
          GenServer.stop(pid, :normal, 5_000)

        [] ->
          :ok
      end

      DynamicSupervisor.start_child(
        Hive.AgentSup,
        {Hive.Agent,
         name: agent.name, description: agent.description, personality: agent.personality}
      )
    end
  end

  defp restore_event_sources do
    {:ok, sources} = Hive.Persistence.get_enabled_event_sources()

    for src <- sources do
      config = if is_binary(src.config), do: Jason.decode!(src.config), else: src.config

      DynamicSupervisor.start_child(
        Hive.EventSourceSup,
        {Hive.Connector.EventSource,
         [
           name: src.name,
           type: src.type,
           topic: src.topic,
           config: config,
           enabled: src.enabled
         ]}
      )
    end
  end
end
