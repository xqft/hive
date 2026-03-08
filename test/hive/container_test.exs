defmodule Hive.ContainerTest do
  use ExUnit.Case, async: false

  defp put_hive_env(key, value) do
    previous = Application.get_env(:hive, key)
    Application.put_env(:hive, key, value)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:hive, key)
      else
        Application.put_env(:hive, key, previous)
      end
    end)
  end

  setup do
    Phoenix.PubSub.subscribe(Hive.PubSub, "containers")
    Registry.register(Hive.AgentRegistry, "container-test-agent", nil)

    put_hive_env(:anthropic_api_key, "test-api-key")
    put_hive_env(:container_docker_available, true)
    put_hive_env(:container_image_available, true)

    :ok
  end

  test "startup failure stops once and does not restart" do
    put_hive_env(:container_docker_executable, "/definitely-missing-docker")

    assert {:ok, container_id} =
             Hive.Container.start("container-test-agent", %{"task" => "echo hello"})

    assert_receive {:stopped, ^container_id, :failed}, 1_000
    assert_receive {:system_message, message}, 1_000
    assert message =~ "[Container #{container_id}] failed to start"
    assert message =~ "Startup failed:"

    refute_receive {:stopped, ^container_id, :failed}, 200
    refute_receive {:system_message, _}, 200
    assert Registry.lookup(Hive.ContainerRegistry, container_id) == []
  end
end
