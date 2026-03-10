defmodule HiveWeb.AgentDetailLive do
  use HiveWeb, :live_view

  alias Hive.ToolEnrichment

  require Logger

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Hive.Persistence.get_agent(name) do
      {:ok, nil} ->
        {:ok, push_navigate(socket, to: ~p"/dashboard")}

      {:ok, agent} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Hive.PubSub, "agent:scratchpad:#{name}")
          Phoenix.PubSub.subscribe(Hive.PubSub, "agents")
        end

        # Load existing scratchpad (stored most-recent-first, reverse for timeline)
        events =
          try do
            name |> Hive.Agent.scratchpad() |> Enum.reverse()
          catch
            _, _ -> []
          end

        status =
          try do
            Hive.Agent.status(name)
          catch
            _, _ -> :unknown
          end

        container_name = "hive-agent-#{name}"
        container_status = check_container_status(container_name)

        {:ok,
         assign(socket,
           page_title: agent.name,
           agent: agent,
           status: status,
           events: events,
           tab: :activity,
           container_name: container_name,
           container_status: container_status,
           relay: nil,
           expanded: MapSet.new()
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell current={:chat} title={@agent.name}>
        <div class="ui-agent-detail">
          <%!-- Header --%>
          <div class="ui-agent-detail__header">
            <div>
              <div class="flex items-center gap-2">
                <h1 class="ui-page-title">{@agent.name}</h1>
                <.status_badge status={@status} />
              </div>
              <p :if={@agent.description != ""} class="ui-helper-text mt-1">{@agent.description}</p>
            </div>
            <.button navigate={~p"/"} variant="ghost" size="sm">Back</.button>
          </div>

          <%!-- Tab bar --%>
          <div class="ui-tab-bar">
            <button
              type="button"
              phx-click="switch_tab"
              phx-value-tab="activity"
              class={["ui-tab-bar__tab", @tab == :activity && "is-active"]}
            >
              <.icon name="hero-eye" class="size-4" />
              Activity
            </button>
            <button
              type="button"
              phx-click="switch_tab"
              phx-value-tab="terminal"
              class={["ui-tab-bar__tab", @tab == :terminal && "is-active"]}
            >
              <.icon name="hero-command-line" class="size-4" />
              Terminal
              <span
                :if={@container_status == :running}
                class="ui-dot"
                style="color: var(--ui-success);"
              />
            </button>
          </div>

          <%!-- Activity tab --%>
          <div :if={@tab == :activity} class="ui-activity-timeline" id="activity-timeline" phx-hook="ScrollBottom">
            <div :if={@events == []} class="ui-empty py-12">
              No activity yet. Send a message to this agent to get started.
            </div>

            <%= for {event, idx} <- Enum.with_index(@events) do %>
              <.activity_item event={event} idx={idx} expanded={@expanded} />
            <% end %>
          </div>

          <%!-- Terminal tab --%>
          <div :if={@tab == :terminal} class="ui-agent-detail__terminal">
            <div
              :if={@container_status == :running}
              id="terminal"
              phx-hook="Terminal"
              class="ui-terminal"
              phx-update="ignore"
            />
            <div :if={@container_status != :running} class="ui-empty py-12">
              Agent container is not running. Send a message to the agent to wake it up.
            </div>
          </div>
        </div>
      </.app_shell>
    </Layouts.app>
    """
  end

  # -- Components --

  defp activity_item(%{event: {:thinking, text, ts}} = assigns) do
    assigns = assign(assigns, :ts, ts) |> assign(:text, text)
    ~H"""
    <div class="ui-activity-item ui-activity-item--thinking">
      <div class="ui-activity-item__icon" style="color: var(--ui-text-soft);">
        <.icon name="hero-light-bulb" class="size-4" />
      </div>
      <div class="ui-activity-item__body">
        <div class="ui-activity-item__summary">Thinking</div>
        <.expandable_pre text={@text} idx={@idx} expanded={@expanded} max_lines={5} />
      </div>
      <div class="ui-activity-item__time">{relative_time(@ts)}</div>
    </div>
    """
  end

  defp activity_item(%{event: {:text, text, ts}} = assigns) do
    assigns = assign(assigns, :ts, ts) |> assign(:text, text)
    ~H"""
    <div class="ui-activity-item ui-activity-item--text">
      <div class="ui-activity-item__icon" style="color: var(--ui-accent);">
        <.icon name="hero-chat-bubble-bottom-center-text" class="size-4" />
      </div>
      <div class="ui-activity-item__body">
        <div class="ui-activity-item__summary">Response</div>
        <.expandable_pre text={@text} idx={@idx} expanded={@expanded} max_lines={5} />
      </div>
      <div class="ui-activity-item__time">{relative_time(@ts)}</div>
    </div>
    """
  end

  defp activity_item(%{event: {:tool_use, tool_name, tool_input, _id, ts}} = assigns) do
    enriched = ToolEnrichment.enrich(tool_name, tool_input)
    assigns = assign(assigns, :enriched, enriched) |> assign(:ts, ts) |> assign(:tool_input, tool_input)
    ~H"""
    <div class={["ui-activity-item ui-activity-item--tool", @enriched.link && "ui-activity-item--clickable"]}>
      <div class="ui-activity-item__icon" style="color: var(--ui-warning);">
        <.enriched_icon name={@enriched.icon} />
      </div>
      <div class="ui-activity-item__body">
        <.enriched_summary enriched={@enriched} />
        <.expandable_detail enriched={@enriched} idx={@idx} expanded={@expanded} />
      </div>
      <div class="ui-activity-item__time">{relative_time(@ts)}</div>
    </div>
    """
  end

  defp activity_item(%{event: {:tool_result, _id, output, ts}} = assigns) do
    assigns = assign(assigns, :ts, ts) |> assign(:output, output)
    ~H"""
    <div class="ui-activity-item ui-activity-item--result">
      <div class="ui-activity-item__icon" style="color: var(--ui-success);">
        <.icon name="hero-check-circle" class="size-4" />
      </div>
      <div class="ui-activity-item__body">
        <div class="ui-activity-item__summary">Result</div>
        <.expandable_pre text={@output} idx={@idx} expanded={@expanded} max_lines={5} muted={true} />
      </div>
      <div class="ui-activity-item__time">{relative_time(@ts)}</div>
    </div>
    """
  end

  defp activity_item(assigns), do: ~H""

  # Enriched icon — maps atom to hero icon name
  defp enriched_icon(assigns) do
    icon_name = case assigns.name do
      :chat_bubble_left -> "hero-chat-bubble-left"
      :chat_bubble_left_right -> "hero-chat-bubble-left-right"
      :user_plus -> "hero-user-plus"
      :user_minus -> "hero-user-minus"
      :hashtag -> "hero-hashtag"
      :arrow_right_on_rectangle -> "hero-arrow-right-on-rectangle"
      :arrow_left_on_rectangle -> "hero-arrow-left-on-rectangle"
      :clock -> "hero-clock"
      :user_group -> "hero-user-group"
      :rectangle_stack -> "hero-rectangle-stack"
      :academic_cap -> "hero-academic-cap"
      :document_text -> "hero-document-text"
      :command_line -> "hero-command-line"
      :document -> "hero-document"
      :document_plus -> "hero-document-plus"
      :pencil_square -> "hero-pencil-square"
      :magnifying_glass -> "hero-magnifying-glass"
      :folder_open -> "hero-folder-open"
      :globe_alt -> "hero-globe-alt"
      :cpu_chip -> "hero-cpu-chip"
      :bolt -> "hero-bolt"
      :computer_desktop -> "hero-computer-desktop"
      :trash -> "hero-trash"
      :wrench -> "hero-wrench"
      _ -> "hero-wrench"
    end
    assigns = assign(assigns, :icon_name, icon_name)
    ~H"""
    <.icon name={@icon_name} class="size-4" />
    """
  end

  # Enriched summary with optional link
  defp enriched_summary(%{enriched: %{link: {:navigate, path}}} = assigns) do
    assigns = assign(assigns, :path, path)
    ~H"""
    <.link navigate={@path} class="ui-activity-item__summary ui-activity-item__summary--link">
      {raw(@enriched.summary)}
    </.link>
    """
  end

  defp enriched_summary(%{enriched: %{link: {:tab, :terminal}}} = assigns) do
    ~H"""
    <div
      class="ui-activity-item__summary ui-activity-item__summary--link"
      phx-click="switch_tab"
      phx-value-tab="terminal"
    >
      {raw(@enriched.summary)}
    </div>
    """
  end

  defp enriched_summary(assigns) do
    ~H"""
    <div class="ui-activity-item__summary">{raw(@enriched.summary)}</div>
    """
  end

  # Expandable detail for enriched tools (shows detail/body)
  defp expandable_detail(%{enriched: %{detail: nil, body: nil}} = assigns), do: ~H""

  defp expandable_detail(%{enriched: enriched} = assigns) do
    # Build preview text from detail or body
    preview = enriched.detail || body_preview(enriched.body)
    has_more = has_more_content?(enriched)
    is_expanded = MapSet.member?(assigns.expanded, assigns.idx)
    is_diff = match?({:diff, _, _}, enriched.body)

    assigns = assign(assigns, preview: preview, has_more: has_more, is_expanded: is_expanded, is_diff: is_diff)

    ~H"""
    <div :if={@preview} class={["ui-activity-preview", @is_expanded && "is-expanded"]}>
      <pre :if={not @is_diff} class="ui-activity-preview__content">{@preview}</pre>
      <.diff_view :if={@is_diff && @is_expanded} body={@enriched.body} />
      <pre :if={@is_diff && not @is_expanded} class="ui-activity-preview__content">{@preview}</pre>
      <button
        :if={@has_more}
        type="button"
        class="ui-activity-toggle"
        phx-click="toggle_expand"
        phx-value-idx={@idx}
      >
        {if @is_expanded, do: "Show less", else: "Show more"}
      </button>
    </div>
    """
  end

  # Expandable pre block for thinking/text/result
  attr :text, :string, required: true
  attr :idx, :integer, required: true
  attr :expanded, :any, required: true
  attr :max_lines, :integer, default: 5
  attr :muted, :boolean, default: false

  defp expandable_pre(assigns) do
    text = assigns.text || ""
    lines = String.split(text, "\n")
    is_expanded = MapSet.member?(assigns.expanded, assigns.idx)
    # Check both line count AND character length (thinking text often has few newlines but is very long)
    has_more = length(lines) > assigns.max_lines || String.length(text) > assigns.max_lines * 120
    preview = if has_more && !is_expanded, do: lines |> Enum.take(assigns.max_lines) |> Enum.join("\n") |> String.slice(0, assigns.max_lines * 120), else: text

    assigns = assign(assigns, preview: preview, has_more: has_more, is_expanded: is_expanded)
    ~H"""
    <div :if={@text && @text != ""} class={["ui-activity-preview", @is_expanded && "is-expanded"]}>
      <pre class={["ui-activity-preview__content", @muted && "ui-activity-preview__content--muted"]}>{@preview}</pre>
      <button
        :if={@has_more}
        type="button"
        class="ui-activity-toggle"
        phx-click="toggle_expand"
        phx-value-idx={@idx}
      >
        {if @is_expanded, do: "Show less", else: "Show more"}
      </button>
    </div>
    """
  end

  # Simple diff view for Edit tool
  defp diff_view(%{body: {:diff, old, new}} = assigns) do
    assigns = assign(assigns, :old, old) |> assign(:new, new)
    ~H"""
    <div class="ui-diff">
      <%= for line <- String.split(@old || "", "\n") do %>
        <div class="ui-diff__del">- {line}</div>
      <% end %>
      <%= for line <- String.split(@new || "", "\n") do %>
        <div class="ui-diff__add">+ {line}</div>
      <% end %>
    </div>
    """
  end

  defp diff_view(assigns), do: ~H""

  defp status_badge(assigns) do
    ~H"""
    <span :if={@status == :idle} class="ui-pill" style="color: var(--ui-success)">idle</span>
    <span :if={@status == :thinking} class="ui-pill" style="color: var(--ui-warning)">thinking</span>
    <span :if={@status == :unknown} class="ui-pill">offline</span>
    """
  end

  # -- Events --

  @impl true
  def handle_event("switch_tab", %{"tab" => "terminal"}, socket) do
    {:noreply, assign(socket, :tab, :terminal)}
  end

  def handle_event("switch_tab", %{"tab" => "activity"}, socket) do
    {:noreply, assign(socket, :tab, :activity)}
  end

  def handle_event("toggle_expand", %{"idx" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, idx),
        do: MapSet.delete(expanded, idx),
        else: MapSet.put(expanded, idx)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  # Terminal events (same as ContainerLive)
  def handle_event("terminal_input", %{"data" => data}, socket) do
    if socket.assigns.relay do
      Hive.TerminalRelay.send_input(socket.assigns.relay, Base.decode64!(data))
    end
    {:noreply, socket}
  end

  def handle_event("terminal_resize", %{"cols" => cols, "rows" => rows}, socket) do
    case socket.assigns.relay do
      nil ->
        relay = start_relay(socket.assigns.container_name, cols, rows)
        {:noreply, assign(socket, :relay, relay)}
      pid when is_pid(pid) ->
        Hive.TerminalRelay.resize(pid, cols, rows)
        {:noreply, socket}
    end
  end

  # -- PubSub handlers --

  @impl true
  def handle_info({:scratchpad_thinking, _agent_name, merged_event}, socket) do
    events = socket.assigns.events

    events =
      case List.last(events) do
        {:thinking, _, _} ->
          List.replace_at(events, length(events) - 1, merged_event)
        _ ->
          events ++ [merged_event]
      end

    {:noreply, assign(socket, :events, events)}
  end

  def handle_info({:scratchpad_text, _agent_name, merged_event}, socket) do
    events = socket.assigns.events

    events =
      case List.last(events) do
        {:text, _, _} ->
          List.replace_at(events, length(events) - 1, merged_event)
        _ ->
          events ++ [merged_event]
      end

    {:noreply, assign(socket, :events, events)}
  end

  def handle_info({:scratchpad, _agent_name, event}, socket) do
    events = socket.assigns.events ++ [event]
    events = if length(events) > 100, do: Enum.drop(events, length(events) - 100), else: events
    {:noreply, assign(socket, :events, events)}
  end

  def handle_info({:status, name, status}, socket) do
    if name == socket.assigns.agent.name do
      {:noreply, assign(socket, :status, status)}
    else
      {:noreply, socket}
    end
  end

  # Terminal relay messages
  def handle_info({:terminal_output, data}, socket) do
    {:noreply, push_event(socket, "terminal_output", %{data: Base.encode64(data)})}
  end

  def handle_info(:terminal_closed, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Private helpers --

  defp start_relay(container_name, cols, rows) do
    case Hive.TerminalRelay.start_link(
           container_id: container_name,
           viewer: self(),
           cols: cols,
           rows: rows,
           session: "shell"
         ) do
      {:ok, pid} -> pid
      {:error, _} -> nil
    end
  end

  defp check_container_status(container_name) do
    docker = docker_executable()
    case System.cmd(docker, ["inspect", "--format", "{{.State.Running}}", container_name],
           stderr_to_stdout: true) do
      {"true\n", 0} -> :running
      _ -> :stopped
    end
  end

  defp docker_executable do
    Application.get_env(:hive, :container_docker_executable) ||
      System.find_executable("docker") ||
      "docker"
  end

  defp relative_time(ts) when is_integer(ts) do
    now = System.system_time(:millisecond)
    diff_seconds = div(now - ts, 1000)

    cond do
      diff_seconds < 5 -> "just now"
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86400)}d ago"
    end
  end

  defp relative_time(_), do: ""

  defp body_preview({:content, text}) when is_binary(text) do
    text |> String.split("\n") |> Enum.take(5) |> Enum.join("\n")
  end

  defp body_preview({:diff, old, new}) do
    lines =
      (String.split(old || "", "\n") |> Enum.map(&("- " <> &1))) ++
      (String.split(new || "", "\n") |> Enum.map(&("+ " <> &1)))
    lines |> Enum.take(8) |> Enum.join("\n")
  end

  defp body_preview(_), do: nil

  defp has_more_content?(%{body: {:content, text}}) when is_binary(text) do
    length(String.split(text, "\n")) > 5
  end

  defp has_more_content?(%{body: {:diff, old, new}}) do
    old_lines = if old, do: length(String.split(old, "\n")), else: 0
    new_lines = if new, do: length(String.split(new, "\n")), else: 0
    old_lines + new_lines > 8
  end

  defp has_more_content?(%{detail: detail}) when is_binary(detail), do: false
  defp has_more_content?(_), do: false
end
