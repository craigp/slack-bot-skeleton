defmodule Slackbot.Bot do

  require Logger
  alias HTTPoison.Response

  @behaviour :websocket_client_handler
  @pong_url "https://s3-static-ak.buzzfed.com/static/campaign_images/webdr03/2013/6/4/13/atari-teenage-riot-the-inside-story-of-pong-and-t-1-29190-1370367066-10_big.jpg"
  @url "https://slack.com/api/rtm.start?token="
  @token System.get_env("SLACK_TOKEN")
  @interval 30000

  def start_link(_name, initial_state \\ %{}) do
    {:ok, rtm} = connect
    :websocket_client.start_link(rtm.url, __MODULE__, %{rtm: rtm, state: initial_state})
  end

  defp connect do
    with {:ok, %Response{body: body}} <- HTTPoison.get(@url <> @token),
      {:ok, json} <- Poison.Parser.parse(body, keys: :atoms),
      do: {:ok, json}
  end

  def init(%{rtm: rtm, state: state}, socket) do
    channels = Enum.reduce(rtm.channels, %{}, fn(channel, map) ->
      Map.put(map, channel.id, channel)
    end)
    users = Enum.reduce(rtm.users, %{}, fn(user, map) ->
      Map.put(map, user.id, user)
    end)
    slack = %{
      socket: socket,
      me: rtm.self,
      channels: channels,
      users: users,
      last_message_id: 0
    }
    {:ok, %{slack: slack, state: state}}
  end

  def websocket_info(:ping, _connection, %{slack: slack, state: state}) do
    slack = send_ping(slack)
    Process.send_after(self(), :ping, @interval)
    {:ok, %{state: state, slack: slack}}
  end

  def websocket_info(what, _connection, state) do
    IO.inspect func: "websocket_info", what: what
    {:ok, state}
  end

  def websocket_terminate(reason, _connection, _state) do
    IO.puts "Websocket closed: #{reason}"
  end

  def websocket_handle({:ping, data}, _connection, state) do
    Logger.debug "<ping>"
    # does this even do anything?
    {:reply, {:pong, data}, state}
  end

  def websocket_handle({:text, message}, _connection, %{slack: slack, state: state}) do
    case Poison.Parser.parse(message, keys: :atoms) do
      {:ok, %{type: "hello"}} ->
        Logger.debug "Connected to Slack"
        Process.send_after(self(), :ping, @interval)
      {:ok, %{type: "pong", reply_to: reply_to}} ->
        Logger.debug "<pong:#{reply_to}>"
      {:ok, %{type: "message", channel: channel_id, text: "ping"}} ->
        slack = send_text_message(@pong_url, channel_id, slack)
      {:ok, %{type: "message", channel: channel_id, text: text}} ->
        slack = parse_message(channel_id, text, slack)
      {:ok, %{ok: true}} ->
        Logger.debug "Message sent"
      {:ok, %{type: "user_typing", channel: channel_id, user: user_id}} ->
        if Regex.match?(~r/^D/, channel_id) do
          case Map.fetch(slack.users, user_id) do
            {:ok, user} ->
              Logger.debug "User #{user.name} typing a direct message"
            :error ->
              Logger.debug "Unknown user typing a direct message"
          end
        else
          with {:ok, channel} <- Map.fetch(slack.channels, channel_id),
            {:ok, user} <- Map.fetch(slack.users, user_id) do
              {:ok, channel, user}
            end
            |> case do
              {:ok, channel, user} ->
                Logger.debug "User #{user.name} typing in channel #{channel.name}"
              :error ->
                Logger.debug "Unknown user typing in unknown channel"
            end
        end
      {:ok, %{presence: presence, user: user_id}} ->
        case Map.fetch(slack.users, user_id) do
          {:ok, user} ->
            Logger.debug "User #{user.name} is #{presence}"
          :error ->
            Logger.debug "Unknown user is #{presence}"
        end
      {:ok, something_else} ->
        IO.inspect something_else: something_else
      wtf ->
        IO.inspect wtf: wtf
    end
    {:ok, %{slack: slack, state: state}}
  end

  def websocket_handle(thing, _connection, state) do
    IO.inspect func: "websocket_handle", thing: thing
    {:ok, state}
  end

  def parse_message(channel_id, text, slack) do
    if Regex.match?(~r/^D/, channel_id) do
      Logger.debug "Echoing direct message: #{text}"
      slack = send_text_message(text, channel_id, slack)
    else
      case Map.fetch(slack.channels, channel_id) do
        {:ok, channel} ->
          Logger.debug "Not echoing message to channel #{channel.name}"
        :error ->
          Logger.debug "Not echoing channel message"
      end
    end
    slack
  end

  def send_text_message(text, channel, slack) do
    %{
      type: "message",
      text: text,
      channel: channel
    } |> send_slack_message(slack)
  end

  def send_ping(slack) do
    %{
      type: "ping"
    } |> send_slack_message(slack)
  end

  def send_slack_message(message, slack) do
    %{last_message_id: last_message_id, socket: socket} = slack
    message_id = last_message_id + 1
    Map.put(message, :id, message_id) |> Poison.encode |> do_send_message(socket)
    %{slack | last_message_id: message_id}
  end

  defp do_send_message({:ok, json}, socket) do
    do_send_message(json, socket)
  end

  defp do_send_message(json, socket) do
    # completely pointless use of a task here, but this is a learning exercise..
    # Task.async(fn -> :websocket_client.send({:text, json}, socket) end)
    :websocket_client.send({:text, json}, socket)
  end

end
