defmodule Drab.Channel do
  require Logger
  @moduledoc false

  use Phoenix.Channel

  @spec join(String.t(), any, Phoenix.Socket.t()) :: {:ok, Phoenix.Socket.t()}
  def join("__drab:" <> broadcast_topic, _, socket) do
    # socket already contains controller and action
    socket_with_topic = socket |> assign(:__broadcast_topic, broadcast_topic)

    {:ok, pid} = Drab.start_link(socket)

    socket_with_pid = assign(socket_with_topic, :__drab_pid, pid)

    {:ok, socket_with_pid}
  end

  @spec handle_in(String.t(), map, Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def handle_in("execjs", %{"ok" => [sender_encrypted, reply]}, socket) do
    # sender contains PID of the process which sent the query
    # sender is waiting for the result
    {sender, ref} = sender(socket, sender_encrypted)
    send(sender, {:got_results_from_client, :ok, ref, reply})

    {:noreply, socket}
  end

  def handle_in("execjs", %{"error" => [sender_encrypted, reply]}, socket) do
    {sender, ref} = sender(socket, sender_encrypted)
    send(sender, {:got_results_from_client, :error, ref, reply})

    {:noreply, socket}
  end

  def handle_in("modal", %{"ok" => [sender_encrypted, reply]}, socket) do
    # sends { "button_name", %{"Param" => "value"}}
    {sender, ref} = sender(socket, sender_encrypted)

    send(sender, {
      :got_results_from_client,
      :ok,
      ref,
      {
        reply["button_clicked"] |> String.to_existing_atom(),
        reply["params"] |> Map.delete("__drab_modal_hidden_input")
      }
    })

    {:noreply, socket}
  end

  def handle_in("waiter", %{"drab_waiter_token" => waiter_token, "sender" => sender}, socket) do
    {pid, ref} = Drab.Waiter.detokenize_waiter(socket, waiter_token)

    send(pid, {:waiter, ref, sender})

    {:noreply, socket}
  end

  def handle_in("onload", payload, socket) do
    # IO.inspect(payload)
    verify_and_cast(:onload, [payload], socket)
  end

  def handle_in("onconnect", payload, socket) do
    # IO.inspect payload

    Drab.set_socket(socket.assigns.__drab_pid, socket)
    # for debugging
    if IEx.started?() do
      commander = Drab.get_commander(socket)
      modules = DrabModule.all_modules_for(commander.__drab__().modules)

      grouped =
        modules
        |> Enum.map(fn module ->
          [_ | rest] = Module.split(module)
          Enum.join(rest, ".")
        end)
        |> Enum.join(", ")

      live_example =
        case Drab.Live.assigns(socket) do
          [] ->
            %{Drab.Live => "socket |> poke(text: \"This assign has been drabbed!\")"}

          [example_assign | _] ->
            %{Drab.Live => "socket |> poke(#{example_assign}: \"This assign has been drabbed!\")"}
        end

      other_examples = %{
        Drab.Element => "socket |> set_style(\"body\", backgroundColor: \"red\")",
        Drab.Query => "socket |> select(:htmls, from: \"h4\")",
        Drab.Modal => "socket |> alert(\"Title\", \"Sure?\", buttons: [ok: \"Azaliż\", cancel: \"Poniechaj\"])",
        Drab.Core => "socket |> exec_js(\"alert('hello from IEx!')\")"
      }

      module_examples = Map.merge(live_example, other_examples)

      examples =
        modules
        |> Enum.map(fn module -> module_examples[module] end)
        |> Enum.filter(fn x -> !is_nil(x) end)

      p = inspect(socket.assigns.__drab_pid)
      pid_string = ~r/#PID<(?<pid>.*)>/ |> Regex.named_captures(p) |> Map.get("pid")

      IO.puts("""

          Started Drab for #{socket.assigns.__broadcast_topic}, handling events in #{inspect(commander)}
          You may debug Drab functions in IEx by copy/paste the following:
      import Drab.{#{grouped}}
      socket = Drab.get_socket(pid("#{pid_string}"))

          Examples:
      #{examples |> Enum.join("\n")}
      """)
    end

    verify_and_cast(:onconnect, [payload], socket)
  end

  def handle_in(
        "event",
        %{
          # "event" => event_name,
          "payload" => payload,
          "event_handler_function" => event_handler_function,
          "reply_to" => reply_to
        },
        socket
      ) do
    verify_and_cast(:event, [payload, event_handler_function, reply_to], socket)
  end

  @spec verify_and_cast(atom, list, Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  defp verify_and_cast(event_name, params, socket) do
    p = [event_name, socket] ++ params
    GenServer.cast(socket.assigns.__drab_pid, List.to_tuple(p))
    {:noreply, socket}
  end

  @spec sender(Phoenix.Socket.t(), String.t()) :: {pid, reference}
  defp sender(socket, sender_encrypted) do
    Drab.detokenize(socket, sender_encrypted)
  end
end
