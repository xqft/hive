defmodule Hive.PropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hive.Validation
  alias Hive.Topic

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # Valid first character: [a-zA-Z0-9]
  defp alnum_char do
    one_of([
      integer(?a..?z),
      integer(?A..?Z),
      integer(?0..?9)
    ])
  end

  # Valid tail character: [a-zA-Z0-9_-]
  defp name_tail_char do
    one_of([
      integer(?a..?z),
      integer(?A..?Z),
      integer(?0..?9),
      constant(?_),
      constant(?-)
    ])
  end

  # Generates a string that matches ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$
  defp valid_name do
    gen all(
          first <- alnum_char(),
          rest <- list_of(name_tail_char(), min_length: 0, max_length: 30)
        ) do
      List.to_string([first | rest])
    end
  end

  # Generates strings that should always be rejected by validate_name.
  defp invalid_name do
    one_of([
      # Empty string
      constant(""),
      # Starts with underscore
      gen_starting_with(?_),
      # Starts with hyphen
      gen_starting_with(?-),
      # Starts with dot
      gen_starting_with(?.),
      # Starts with space
      gen_starting_with(?\s),
      # Too long: 32+ chars (first char valid, then 31+ tail chars)
      gen all(
            first <- alnum_char(),
            rest <- list_of(name_tail_char(), min_length: 31, max_length: 60)
          ) do
        List.to_string([first | rest])
      end,
      # Contains a space in the middle
      gen all(
            prefix <- list_of(alnum_char(), min_length: 1, max_length: 5),
            suffix <- list_of(alnum_char(), min_length: 1, max_length: 5)
          ) do
        List.to_string(prefix) <> " " <> List.to_string(suffix)
      end,
      # Contains special characters
      gen all(
            prefix <- list_of(alnum_char(), min_length: 1, max_length: 5),
            bad <- one_of([constant(?!), constant(?@), constant(?#), constant(?.)]),
            suffix <- list_of(alnum_char(), min_length: 1, max_length: 5)
          ) do
        List.to_string(prefix) <> <<bad>> <> List.to_string(suffix)
      end
    ])
  end

  defp gen_starting_with(char) do
    gen all(rest <- list_of(name_tail_char(), min_length: 0, max_length: 10)) do
      List.to_string([char | rest])
    end
  end

  # ---------------------------------------------------------------------------
  # 1. Name validation property
  # ---------------------------------------------------------------------------

  describe "name validation properties" do
    property "valid names are always accepted" do
      check all(name <- valid_name()) do
        assert :ok = Validation.validate_name(name)
      end
    end

    property "invalid names are always rejected" do
      check all(name <- invalid_name()) do
        assert {:error, :invalid_name} = Validation.validate_name(name)
      end
    end

    property "validate_name agrees with direct regex match" do
      regex = ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$/

      check all(name <- string(:printable, min_length: 0, max_length: 40)) do
        expected =
          if Regex.match?(regex, name),
            do: :ok,
            else: {:error, :invalid_name}

        assert Validation.validate_name(name) == expected
      end
    end

    property "single alphanumeric character is always valid" do
      check all(char <- alnum_char()) do
        assert :ok = Validation.validate_name(<<char>>)
      end
    end

    property "names at exactly max length (31 chars) are valid" do
      check all(
              first <- alnum_char(),
              rest <- list_of(name_tail_char(), length: 30)
            ) do
        name = List.to_string([first | rest])
        assert byte_size(name) == 31
        assert :ok = Validation.validate_name(name)
      end
    end

    property "names exceeding max length (32+ chars) are rejected" do
      check all(
              first <- alnum_char(),
              rest <- list_of(name_tail_char(), min_length: 31, max_length: 60)
            ) do
        name = List.to_string([first | rest])
        assert byte_size(name) >= 32
        assert {:error, :invalid_name} = Validation.validate_name(name)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2. DM naming symmetry
  # ---------------------------------------------------------------------------

  describe "DM naming properties" do
    property "dm_channel_name is symmetric: f(a,b) == f(b,a)" do
      check all(
              a <- valid_name(),
              b <- valid_name()
            ) do
        assert Topic.dm_channel_name(a, b) == Topic.dm_channel_name(b, a)
      end
    end

    property "dm_channel_name starts with 'dm:' and contains both names" do
      check all(
              a <- valid_name(),
              b <- valid_name()
            ) do
        result = Topic.dm_channel_name(a, b)
        assert String.starts_with?(result, "dm:")
        assert String.contains?(result, a)
        assert String.contains?(result, b)
      end
    end

    property "dm_channel_name uses alphabetical ordering" do
      check all(
              a <- valid_name(),
              b <- valid_name()
            ) do
        result = Topic.dm_channel_name(a, b)
        [sorted_first, sorted_second] = Enum.sort([a, b])
        assert result == "dm:#{sorted_first}:#{sorted_second}"
      end
    end

    property "dm_channel_name is idempotent: f(a,b) == f(a,b)" do
      check all(
              a <- valid_name(),
              b <- valid_name()
            ) do
        first = Topic.dm_channel_name(a, b)
        second = Topic.dm_channel_name(a, b)
        assert first == second
      end
    end

    property "dm_channel_name with identical names produces dm:x:x" do
      check all(name <- valid_name()) do
        assert Topic.dm_channel_name(name, name) == "dm:#{name}:#{name}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Ring buffer invariant
  # ---------------------------------------------------------------------------

  describe "ring buffer properties" do
    property "buffer holds at most 50 messages, most recent first" do
      check all(n <- integer(1..100)) do
        # Use a unique topic name per iteration to avoid collisions
        uid = :erlang.unique_integer([:positive])
        topic_name = "prop-ring-#{uid}"

        pid =
          start_supervised!(
            {Topic,
             name: topic_name, description: "prop test", type: :topic, created_by: "test"},
            id: topic_name
          )

        # Join a sender so we can post
        Topic.join(topic_name, "sender")

        # Measure baseline — the Topic may have loaded persisted messages on init
        baseline = length(Topic.recent(topic_name, 100))

        # Post n messages
        for i <- 1..n do
          Topic.post(topic_name, "sender", "msg-#{i}")
        end

        messages = Topic.recent(topic_name, 100)

        # Buffer size is min(baseline + n, 50) because the ring buffer caps at 50
        assert length(messages) == min(baseline + n, 50)

        # Most recent message is first (our last posted message)
        assert hd(messages).body == "msg-#{n}"

        # Our messages are in reverse chronological order (most recent first)
        our_messages = Enum.filter(messages, fn m -> String.starts_with?(m.body, "msg-") end)

        if length(our_messages) > 1 do
          msg_numbers =
            Enum.map(our_messages, fn %{body: "msg-" <> num} -> String.to_integer(num) end)

          assert msg_numbers == Enum.sort(msg_numbers, :desc)
        end

        GenServer.stop(pid)
      end
    end

    property "recent(n) returns at most n messages" do
      check all(
              msg_count <- integer(1..60),
              request_count <- integer(1..100)
            ) do
        uid = :erlang.unique_integer([:positive])
        topic_name = "prop-recent-#{uid}"

        pid =
          start_supervised!(
            {Topic,
             name: topic_name, description: "prop test", type: :topic, created_by: "test"},
            id: topic_name
          )

        Topic.join(topic_name, "sender")

        baseline = length(Topic.recent(topic_name, 100))

        for i <- 1..msg_count do
          Topic.post(topic_name, "sender", "m-#{i}")
        end

        messages = Topic.recent(topic_name, request_count)
        total_buffered = min(baseline + msg_count, 50)
        expected = min(request_count, total_buffered)
        assert length(messages) == expected

        GenServer.stop(pid)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Container validation with random timeouts
  # ---------------------------------------------------------------------------

  describe "container validation properties" do
    setup do
      put_hive_env(:claude_oauth_token, "test-oauth-token")
      put_hive_env(:container_docker_available, true)
      put_hive_env(:container_image_available, true)
      :ok
    end

    property "valid integer timeouts (1-60) pass validation" do
      check all(minutes <- integer(1..60)) do
        task_input = %{"task" => "test task", "timeout_minutes" => minutes}
        assert :ok = Hive.Container.validate_execution(task_input)
      end
    end

    property "valid float timeouts (1.0-60.0) pass validation" do
      check all(minutes <- float(min: 1.0, max: 60.0)) do
        task_input = %{"task" => "test task", "timeout_minutes" => minutes}
        assert :ok = Hive.Container.validate_execution(task_input)
      end
    end

    property "valid string timeouts ('1'-'60') pass validation" do
      check all(minutes <- integer(1..60)) do
        task_input = %{"task" => "test task", "timeout_minutes" => Integer.to_string(minutes)}
        assert :ok = Hive.Container.validate_execution(task_input)
      end
    end

    property "nil timeout uses default and passes validation" do
      check all(task_desc <- string(:alphanumeric, min_length: 1, max_length: 50)) do
        task_input = %{"task" => task_desc, "timeout_minutes" => nil}
        assert :ok = Hive.Container.validate_execution(task_input)
      end
    end

    property "missing timeout_minutes key uses default and passes validation" do
      check all(task_desc <- string(:alphanumeric, min_length: 1, max_length: 50)) do
        task_input = %{"task" => task_desc}
        assert :ok = Hive.Container.validate_execution(task_input)
      end
    end

    property "zero and negative timeouts are rejected" do
      check all(minutes <- one_of([constant(0), integer(-100..-1)])) do
        task_input = %{"task" => "test task", "timeout_minutes" => minutes}
        assert {:error, msg} = Hive.Container.validate_execution(task_input)
        assert msg =~ "timeout_minutes must be between"
      end
    end

    property "timeouts above 60 are rejected" do
      check all(minutes <- integer(61..1000)) do
        task_input = %{"task" => "test task", "timeout_minutes" => minutes}
        assert {:error, msg} = Hive.Container.validate_execution(task_input)
        assert msg =~ "timeout_minutes must be between"
      end
    end

    property "non-numeric string timeouts are rejected" do
      check all(
              bad <- filter(string(:alphanumeric, min_length: 1, max_length: 10), fn s ->
                case Float.parse(s) do
                  {_, ""} -> false
                  _ -> true
                end
              end)
            ) do
        task_input = %{"task" => "test task", "timeout_minutes" => bad}
        assert {:error, _} = Hive.Container.validate_execution(task_input)
      end
    end

    property "empty task is rejected regardless of timeout" do
      check all(minutes <- one_of([constant(nil), integer(1..60)])) do
        task_input = %{"task" => "", "timeout_minutes" => minutes}
        assert {:error, "task is required"} = Hive.Container.validate_execution(task_input)
      end
    end

    property "missing task key is rejected" do
      check all(minutes <- one_of([constant(nil), integer(1..60)])) do
        task_input = %{"timeout_minutes" => minutes}
        assert {:error, "task is required"} = Hive.Container.validate_execution(task_input)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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
end
