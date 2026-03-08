defmodule Hive.ContainerTest do
  use ExUnit.Case, async: false

  @mock_docker Path.expand("test/support/mock_docker.sh")

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

  defp put_sys_env(key, value) do
    previous = System.get_env(key)
    System.put_env(key, value)

    on_exit(fn ->
      if is_nil(previous) do
        System.delete_env(key)
      else
        System.put_env(key, previous)
      end
    end)
  end

  defp use_mock_docker(opts \\ []) do
    put_hive_env(:container_docker_executable, @mock_docker)

    exit_code = Keyword.get(opts, :exit_code, "0")
    sleep = Keyword.get(opts, :sleep, "0")
    output = Keyword.get(opts, :output, "mock output line")

    put_sys_env("MOCK_DOCKER_EXIT_CODE", to_string(exit_code))
    put_sys_env("MOCK_DOCKER_SLEEP", to_string(sleep))
    put_sys_env("MOCK_DOCKER_OUTPUT", to_string(output))
  end

  # Wait for a GenServer to fully terminate and unregister from ContainerRegistry.
  # After receiving {:stopped, ...} via PubSub, the GenServer is in the process of
  # stopping but Registry cleanup is asynchronous. This polls until the entry is gone.
  defp await_registry_cleanup(container_id, attempts \\ 20) do
    if attempts <= 0 do
      flunk("Container #{container_id} still registered after waiting")
    end

    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [] -> :ok
      _ ->
        Process.sleep(10)
        await_registry_cleanup(container_id, attempts - 1)
    end
  end

  setup do
    Phoenix.PubSub.subscribe(Hive.PubSub, "containers")
    Registry.register(Hive.AgentRegistry, "container-test-agent", nil)

    put_hive_env(:anthropic_api_key, "test-api-key")
    put_hive_env(:container_docker_available, true)
    put_hive_env(:container_image_available, true)

    :ok
  end

  # --------------------------------------------------------------------------
  # Existing test
  # --------------------------------------------------------------------------

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

  # --------------------------------------------------------------------------
  # 1. Successful execution
  # --------------------------------------------------------------------------

  test "successful execution broadcasts started/stopped and notifies agent with exit code 0" do
    use_mock_docker(exit_code: 0, output: "all good")

    assert {:ok, container_id} =
             Hive.Container.start("container-test-agent", %{"task" => "do stuff"})

    assert_receive {:started, "container-test-agent", ^container_id, "do stuff"}, 2_000
    assert_receive {:stopped, ^container_id, :completed}, 2_000

    assert_receive {:system_message, message}, 2_000
    assert message =~ "[Container #{container_id}] completed successfully"
    assert message =~ "Task: do stuff"

    await_registry_cleanup(container_id)
  end

  # --------------------------------------------------------------------------
  # 2. Failed execution
  # --------------------------------------------------------------------------

  test "failed execution (non-zero exit) broadcasts :failed and notifies agent" do
    use_mock_docker(exit_code: 1, output: "something broke")

    assert {:ok, container_id} =
             Hive.Container.start("container-test-agent", %{"task" => "break things"})

    assert_receive {:started, "container-test-agent", ^container_id, "break things"}, 2_000
    assert_receive {:stopped, ^container_id, :failed}, 2_000

    assert_receive {:system_message, message}, 2_000
    assert message =~ "[Container #{container_id}] failed with exit code 1"

    await_registry_cleanup(container_id)
  end

  # --------------------------------------------------------------------------
  # 3. Timeout
  # --------------------------------------------------------------------------

  test "container times out, gets killed, broadcasts :timed_out" do
    # Use a short sleep so the port exits shortly after the timeout fires.
    # The mock kill command doesn't actually kill the run process, so the run
    # process must finish its sleep on its own for the exit_status to arrive.
    use_mock_docker(exit_code: 0, sleep: 2, output: "working...")

    # 100ms timeout — fires well before the 2s sleep finishes
    assert {:ok, container_id} =
             Hive.Container.start(
               "container-test-agent",
               %{"task" => "long task"},
               100
             )

    assert_receive {:started, "container-test-agent", ^container_id, _}, 2_000
    # The port will exit after ~2s sleep, then the timed_out handler fires
    assert_receive {:stopped, ^container_id, :timed_out}, 5_000

    assert_receive {:system_message, message}, 2_000
    assert message =~ "[Container #{container_id}] timed out"

    await_registry_cleanup(container_id)
  end

  # --------------------------------------------------------------------------
  # 4. Kill
  # --------------------------------------------------------------------------

  test "killing a running container broadcasts :killed and notifies agent" do
    # Use a moderate sleep so the container is still running when we call kill.
    # The kill handler calls {:stop, :normal, ...} which closes the port and
    # terminates the GenServer immediately — no need to wait for the sleep.
    use_mock_docker(exit_code: 0, sleep: 30, output: "running...")

    assert {:ok, container_id} =
             Hive.Container.start("container-test-agent", %{"task" => "killable task"})

    assert_receive {:started, "container-test-agent", ^container_id, _}, 2_000

    Hive.Container.kill(container_id)

    assert_receive {:stopped, ^container_id, :killed}, 2_000

    assert_receive {:system_message, message}, 2_000
    assert message =~ "[Container #{container_id}] was killed"

    await_registry_cleanup(container_id)
  end

  # --------------------------------------------------------------------------
  # 5. 16/agent limit
  # --------------------------------------------------------------------------

  test "rejects 17th container for the same agent" do
    use_mock_docker()

    # Register 16 fake containers in ContainerRegistry with the same agent_name metadata
    for i <- 1..16 do
      Registry.register(Hive.ContainerRegistry, "fake-#{i}", "container-test-agent")
    end

    on_exit(fn ->
      for i <- 1..16 do
        Registry.unregister(Hive.ContainerRegistry, "fake-#{i}")
      end
    end)

    assert {:error, message} =
             Hive.Container.start("container-test-agent", %{"task" => "too many"})

    assert message =~ "maximum of 16"
    assert message =~ "container-test-agent"
  end

  # --------------------------------------------------------------------------
  # 6. Output buffer capped at 30 lines
  # --------------------------------------------------------------------------

  test "output buffer is capped at 30 lines" do
    # Generate 50 lines of output
    lines = Enum.map_join(1..50, "\n", fn i -> "line-#{i}" end)
    use_mock_docker(exit_code: 0, output: lines)

    assert {:ok, container_id} =
             Hive.Container.start("container-test-agent", %{"task" => "lots of output"})

    assert_receive {:started, "container-test-agent", ^container_id, _}, 2_000
    # Wait for container to complete so all output is buffered
    assert_receive {:stopped, ^container_id, :completed}, 2_000

    # The system_message includes the buffer contents (last 30 lines)
    assert_receive {:system_message, message}, 2_000
    assert message =~ "line-50"
    # line-20 should have been evicted (only last 30 of 50 lines kept)
    refute message =~ "\nline-20\n"
    # line-21 is the first line in the 30-line window
    assert message =~ "line-21"
  end

  # --------------------------------------------------------------------------
  # 7. Agent gone on completion — no crash
  # --------------------------------------------------------------------------

  test "container does not crash when agent is gone on completion" do
    use_mock_docker(exit_code: 0, sleep: 1, output: "done")

    assert {:ok, container_id} =
             Hive.Container.start("container-test-agent", %{"task" => "orphan task"})

    assert_receive {:started, "container-test-agent", ^container_id, _}, 2_000

    # Unregister the agent before container exits
    Registry.unregister(Hive.AgentRegistry, "container-test-agent")

    # Container should still complete cleanly — no crash
    assert_receive {:stopped, ^container_id, :completed}, 5_000

    # No system_message since agent is gone, but no crash either
    refute_receive {:system_message, _}, 200

    await_registry_cleanup(container_id)
  end

  # --------------------------------------------------------------------------
  # 8. Validation — each check independently
  # --------------------------------------------------------------------------

  describe "validation" do
    test "rejects empty task" do
      use_mock_docker()

      assert {:error, "task is required"} =
               Hive.Container.start("container-test-agent", %{"task" => ""})
    end

    test "rejects missing task key" do
      use_mock_docker()

      assert {:error, "task is required"} =
               Hive.Container.start("container-test-agent", %{})
    end

    test "rejects whitespace-only task" do
      use_mock_docker()

      assert {:error, "task is required"} =
               Hive.Container.start("container-test-agent", %{"task" => "   "})
    end

    test "rejects timeout_minutes below minimum (1)" do
      use_mock_docker()

      assert {:error, msg} =
               Hive.Container.start("container-test-agent", %{
                 "task" => "hello",
                 "timeout_minutes" => 0
               })

      assert msg =~ "timeout_minutes must be between 1 and 60"
    end

    test "rejects timeout_minutes above maximum (60)" do
      use_mock_docker()

      assert {:error, msg} =
               Hive.Container.start("container-test-agent", %{
                 "task" => "hello",
                 "timeout_minutes" => 120
               })

      assert msg =~ "timeout_minutes must be between 1 and 60"
    end

    test "rejects non-numeric string timeout_minutes" do
      use_mock_docker()

      assert {:error, msg} =
               Hive.Container.start("container-test-agent", %{
                 "task" => "hello",
                 "timeout_minutes" => "abc"
               })

      assert msg =~ "timeout_minutes must be between 1 and 60"
    end

    test "accepts valid string timeout_minutes" do
      use_mock_docker()

      assert {:ok, container_id} =
               Hive.Container.start("container-test-agent", %{
                 "task" => "hello",
                 "timeout_minutes" => "5"
               })

      assert_receive {:started, _, ^container_id, _}, 2_000
      assert_receive {:stopped, ^container_id, :completed}, 2_000
    end

    test "accepts valid float timeout_minutes" do
      use_mock_docker()

      assert {:ok, container_id} =
               Hive.Container.start("container-test-agent", %{
                 "task" => "hello",
                 "timeout_minutes" => 2.5
               })

      assert_receive {:started, _, ^container_id, _}, 2_000
      assert_receive {:stopped, ^container_id, :completed}, 2_000
    end

    test "rejects when docker is unavailable" do
      put_hive_env(:container_docker_available, false)

      assert {:error, msg} =
               Hive.Container.start("container-test-agent", %{"task" => "hello"})

      assert msg =~ "docker is not installed"
    end

    test "rejects when image is unavailable" do
      use_mock_docker()
      put_hive_env(:container_image_available, false)

      assert {:error, msg} =
               Hive.Container.start("container-test-agent", %{"task" => "hello"})

      assert msg =~ "not available locally"
    end

    test "rejects when API key is missing" do
      use_mock_docker()
      put_hive_env(:anthropic_api_key, "")
      put_hive_env(:claude_oauth_token, nil)

      assert {:error, msg} =
               Hive.Container.start("container-test-agent", %{"task" => "hello"})

      assert msg =~ "Neither ANTHROPIC_API_KEY nor CLAUDE_CODE_OAUTH_TOKEN is configured"
    end

    test "rejects when API key is nil" do
      use_mock_docker()
      put_hive_env(:anthropic_api_key, nil)
      put_hive_env(:claude_oauth_token, nil)

      assert {:error, msg} =
               Hive.Container.start("container-test-agent", %{"task" => "hello"})

      assert msg =~ "Neither ANTHROPIC_API_KEY nor CLAUDE_CODE_OAUTH_TOKEN is configured"
    end
  end

  # --------------------------------------------------------------------------
  # 9. Kill on already-stopped container — no crash
  # --------------------------------------------------------------------------

  test "killing an already-stopped container returns :ok without crash" do
    use_mock_docker(exit_code: 0)

    assert {:ok, container_id} =
             Hive.Container.start("container-test-agent", %{"task" => "quick job"})

    assert_receive {:stopped, ^container_id, :completed}, 2_000
    await_registry_cleanup(container_id)

    # kill/1 should return :ok (not found path)
    assert Hive.Container.kill(container_id) == :ok
  end

  # --------------------------------------------------------------------------
  # 10. check returns status info
  # --------------------------------------------------------------------------

  test "check returns status info for a running container" do
    use_mock_docker(exit_code: 0, sleep: 5, output: "hello from container")

    assert {:ok, container_id} =
             Hive.Container.start("container-test-agent", %{"task" => "check me"})

    assert_receive {:started, "container-test-agent", ^container_id, _}, 2_000

    # Small delay to let output arrive
    Process.sleep(100)

    assert {:ok, status_string} = Hive.Container.check(container_id)
    assert status_string =~ "Container: #{container_id}"
    assert status_string =~ "Status: running"
    assert status_string =~ "Task: check me"
    assert status_string =~ "Recent Output"

    # Clean up: kill the long-running container
    Hive.Container.kill(container_id)
    assert_receive {:stopped, ^container_id, :killed}, 2_000
  end

  test "check returns :not_found for unknown container" do
    assert {:error, :not_found} = Hive.Container.check("nonexistent-container-id")
  end
end
