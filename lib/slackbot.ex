defmodule Slackbot do

  use Application
  require Logger

  def start(_type, _args) do
    Slackbot.Supervisor.start_link
  end

  def stop(_args) do
  end

end

