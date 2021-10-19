##
# Copyright (C) 2021  Valentin Lorentz
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License version 3,
# as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
###

defmodule MockMatrixClient do
  use GenServer

  def start_link(args) do
    {sup_pid} = args
    name = {:via, Registry, {Matrix2051.Registry, {sup_pid, :matrix_client}}}
    GenServer.start_link(__MODULE__, args, name: name)
  end

  @impl true
  def init({sup_pid}) do
    {:ok,
     %Matrix2051.MatrixClient.Client{
       state: :initial_state,
       irc_pid: sup_pid,
       args: []
     }}
  end

  @impl true
  def handle_call({:connect, local_name, hostname, password}, _from, state) do
    case {hostname, password} do
      {"i-hate-passwords.example.org", _} ->
        {:reply, {:error, :no_password_flow, "No password flow"}, state}

      {_, "correct password"} ->
        state = %{state | local_name: local_name, hostname: hostname}
        {:reply, {:ok}, %{state | state: :connected}}

      {_, "invalid password"} ->
        {:reply, {:error, :invalid_password, "Invalid password"}, state}
    end
  end

  @impl true
  def handle_call({:register, local_name, hostname, password}, _from, state) do
    case {local_name, password} do
      {"user", "my p4ssw0rd"} ->
        state = %{state | state: :connected, local_name: local_name, hostname: hostname}
        {:reply, {:ok, local_name <> ":" <> hostname}, state}

      {"reserveduser", _} ->
        {:reply, {:error, :exclusive, "This username is reserved"}, state}
    end
  end

  @impl true
  def handle_call({:join_room, room_alias}, _from, state) do
    case room_alias do
      "#existing_room:example.org" -> {:reply, {:ok, "!existing_room_id:example.org"}, state}
    end
  end

  @impl true
  def handle_call({:dump_state}, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(msg, _from, state) do
    %Matrix2051.MatrixClient.Client{irc_pid: irc_pid} = state
    send(irc_pid, msg)
    {:reply, {:ok, nil}, state}
  end
end

defmodule Matrix2051.IrcConn.HandlerTest do
  use ExUnit.Case, async: false
  doctest Matrix2051.IrcConn.Handler

  @cap_ls_302 "CAP * LS :account-tag batch draft/account-registration=before-connect draft/multiline=max-bytes=8192 echo-message extended-join labeled-response message-tags sasl=PLAIN server-time\r\n"
  @cap_ls "CAP * LS :account-tag batch draft/account-registration draft/multiline echo-message extended-join labeled-response message-tags sasl server-time\r\n"
  @isupport "CASEMAPPING=rfc3454 CLIENTTAGDENY=*,-draft/reply CHANLIMIT= CHANTYPES=#! TARGMAX=JOIN:1,PART:1 UTF8ONLY :are supported by this server\r\n"

  setup do
    start_supervised!({Registry, keys: :unique, name: Matrix2051.Registry})
    start_supervised!({Matrix2051.Config, []})
    start_supervised!({MockMatrixClient, {self()}})
    state = start_supervised!({Matrix2051.IrcConn.State, {self()}})

    handler = start_supervised!({Matrix2051.IrcConn.Handler, {self()}})

    start_supervised!({MockIrcConnWriter, {self()}})
    start_supervised!({MockMatrixState, {self()}})

    %{
      state: state,
      handler: handler
    }
  end

  def cmd(line) do
    {:ok, command} = Matrix2051.Irc.Command.parse(line)
    command
  end

  defp assert_message(expected) do
    receive do
      msg -> assert msg == expected
    end
  end

  defp assert_line(line) do
    assert_message({:line, line})
  end

  defp assert_open_batch() do
    receive do
      msg ->
        {:line, line} = msg
        {:ok, cmd} = Matrix2051.Irc.Command.parse(line)
        %Matrix2051.Irc.Command{command: "BATCH", params: [param1 | _]} = cmd
        batch_id = String.slice(param1, 1, String.length(param1))
        {batch_id, line}
    end
  end

  def assert_welcome(nick) do
    assert_line(":server 001 #{nick} :Welcome to this Matrix bouncer.\r\n")
    assert_line(":server 005 #{nick} #{@isupport}")
    assert_line(":server 375 #{nick} :- Message of the day\r\n")
    assert_line(":server 372 #{nick} :Welcome to Matrix2051, a Matrix bouncer.\r\n")
    assert_line(":server 376 #{nick} :End of /MOTD command.\r\n")
  end

  def do_connection_registration(handler, capabilities \\ []) do
    send(handler, cmd("CAP LS 302"))
    assert_line(@cap_ls_302)

    joined_caps = Enum.join(["batch", "labeled-response", "sasl"] ++ capabilities, " ")
    send(handler, cmd("CAP REQ :" <> joined_caps))
    assert_line("CAP * ACK :" <> joined_caps <> "\r\n")

    send(handler, cmd("NICK foo:example.org"))
    send(handler, cmd("USER ident * * :My GECOS"))

    send(handler, cmd("@label=reg01 AUTHENTICATE PLAIN"))
    assert_line("@label=reg01 AUTHENTICATE :+\r\n")

    send(
      handler,
      cmd(
        "@label=reg02 AUTHENTICATE Zm9vOmV4YW1wbGUub3JnAGZvbzpleGFtcGxlLm9yZwBjb3JyZWN0IHBhc3N3b3Jk"
      )
    )

    assert_line(
      "@label=reg02 :server 900 foo:example.org foo:example.org!foo@example.org foo:example.org :You are now logged in as foo:example.org\r\n"
    )

    assert_line("@label=reg02 :server 903 foo:example.org :Authentication successful\r\n")

    send(handler, cmd("CAP END"))
    assert_welcome("foo:example.org")
  end

  test "non-IRCv3 connection registration with no authenticate", %{handler: handler} do
    send(handler, cmd("NICK foo:example.org"))

    send(handler, cmd("PING sync1"))
    assert_line("PONG :sync1\r\n")

    send(handler, cmd("USER ident * * :My GECOS"))
    assert_line("FAIL * ACCOUNT_REQUIRED :You must authenticate.\r\n")
    assert_message({:close})
  end

  test "IRCv3 connection registration with no SASL", %{handler: handler} do
    send(handler, cmd("CAP LS"))
    assert_line(@cap_ls)

    send(handler, cmd("PING sync1"))
    assert_line("PONG :sync1\r\n")

    send(handler, cmd("NICK foo:example.org"))
    send(handler, cmd("USER ident * * :My GECOS"))

    send(handler, cmd("CAP END"))
    assert_line("FAIL * ACCOUNT_REQUIRED :You must authenticate.\r\n")
    assert_message({:close})
  end

  test "IRCv3 connection registration with no authenticate", %{handler: handler} do
    send(handler, cmd("CAP LS"))
    assert_line(@cap_ls)

    send(handler, cmd("CAP REQ sasl"))
    assert_line("CAP * ACK :sasl\r\n")

    send(handler, cmd("PING sync1"))
    assert_line("PONG :sync1\r\n")

    send(handler, cmd("NICK foo:example.org"))
    send(handler, cmd("USER ident * * :My GECOS"))

    send(handler, cmd("CAP END"))
    assert_line("FAIL * ACCOUNT_REQUIRED :You must authenticate.\r\n")
    assert_message({:close})
  end

  test "Connection registration", %{state: state, handler: handler} do
    send(handler, cmd("CAP LS 302"))
    assert_line(@cap_ls_302)

    send(handler, cmd("CAP REQ sasl"))
    assert_line("CAP * ACK :sasl\r\n")

    send(handler, cmd("NICK foo:example.org"))
    send(handler, cmd("USER ident * * :My GECOS"))

    send(handler, cmd("AUTHENTICATE PLAIN"))
    assert_line("AUTHENTICATE :+\r\n")

    # foo:example.org\x00foo:example.org\x00correct password
    send(
      handler,
      cmd("AUTHENTICATE Zm9vOmV4YW1wbGUub3JnAGZvbzpleGFtcGxlLm9yZwBjb3JyZWN0IHBhc3N3b3Jk")
    )

    assert_line(
      ":server 900 foo:example.org foo:example.org!foo@example.org foo:example.org :You are now logged in as foo:example.org\r\n"
    )

    assert_line(":server 903 foo:example.org :Authentication successful\r\n")

    send(handler, cmd("CAP END"))
    assert_welcome("foo:example.org")

    assert Matrix2051.IrcConn.State.nick(state) == "foo:example.org"
    assert Matrix2051.IrcConn.State.gecos(state) == "My GECOS"
  end

  test "Connection registration with AUTHENTICATE before NICK", %{state: state, handler: handler} do
    send(handler, cmd("CAP LS 302"))
    assert_line(@cap_ls_302)

    send(handler, cmd("CAP REQ sasl"))
    assert_line("CAP * ACK :sasl\r\n")

    send(handler, cmd("AUTHENTICATE PLAIN"))
    assert_line("AUTHENTICATE :+\r\n")

    # foo:example.org\x00foo:example.org\x00correct password
    send(
      handler,
      cmd("AUTHENTICATE Zm9vOmV4YW1wbGUub3JnAGZvbzpleGFtcGxlLm9yZwBjb3JyZWN0IHBhc3N3b3Jk")
    )

    assert_line(":server 900 * * foo:example.org :You are now logged in as foo:example.org\r\n")

    assert_line(":server 903 * :Authentication successful\r\n")

    send(handler, cmd("NICK foo:example.org"))
    send(handler, cmd("USER ident * * :My GECOS"))

    send(handler, cmd("CAP END"))
    assert_welcome("foo:example.org")

    assert Matrix2051.IrcConn.State.nick(state) == "foo:example.org"
    assert Matrix2051.IrcConn.State.gecos(state) == "My GECOS"
  end

  test "Registration with mismatched nick", %{state: state, handler: handler} do
    send(handler, cmd("CAP LS 302"))
    assert_line(@cap_ls_302)

    send(handler, cmd("CAP REQ sasl"))
    assert_line("CAP * ACK :sasl\r\n")

    send(handler, cmd("NICK initial_nick"))
    send(handler, cmd("USER ident * * :My GECOS"))

    send(handler, cmd("AUTHENTICATE PLAIN"))
    assert_line("AUTHENTICATE :+\r\n")

    # foo:example.org\x00foo:example.org\x00correct password
    send(
      handler,
      cmd("AUTHENTICATE Zm9vOmV4YW1wbGUub3JnAGZvbzpleGFtcGxlLm9yZwBjb3JyZWN0IHBhc3N3b3Jk")
    )

    assert_line(
      ":server 900 initial_nick initial_nick!foo@example.org foo:example.org :You are now logged in as foo:example.org\r\n"
    )

    assert_line(":server 903 initial_nick :Authentication successful\r\n")

    send(handler, cmd("CAP END"))
    assert_welcome("initial_nick")
    assert_line(":initial_nick!foo@example.org NICK :foo:example.org\r\n")

    assert Matrix2051.IrcConn.State.nick(state) == "foo:example.org"
    assert Matrix2051.IrcConn.State.gecos(state) == "My GECOS"
  end

  test "user_id validation", %{state: state, handler: handler} do
    send(handler, cmd("CAP LS"))
    assert_line(@cap_ls)

    send(handler, cmd("CAP REQ sasl"))
    assert_line("CAP * ACK :sasl\r\n")

    send(handler, cmd("NICK foo:bar"))
    send(handler, cmd("USER ident * * :My GECOS"))

    try_userid = fn userid, expected_message ->
      send(handler, cmd("AUTHENTICATE PLAIN"))
      assert_line("AUTHENTICATE :+\r\n")

      send(
        handler,
        cmd(
          "AUTHENTICATE " <>
            Base.encode64(userid <> "\x00" <> userid <> "\x00" <> "correct password")
        )
      )

      assert_line(expected_message)
    end

    try_userid.(
      "foo",
      ":server 904 foo:bar :Invalid account/user id: must contain a colon (':'), to separate the username and hostname. For example: foo:matrix.org\r\n"
    )

    try_userid.(
      "foo:bar:baz",
      ":server 904 foo:bar :Invalid account/user id: must not contain more than one colon.\r\n"
    )

    try_userid.(
      "foo bar:baz",
      ":server 904 foo:bar :Invalid account/user id: your local name may only contain lowercase latin letters, digits, and the following characters: -.=_/\r\n"
    )

    try_userid.(
      "café:baz",
      ":server 904 foo:bar :Invalid account/user id: your local name may only contain lowercase latin letters, digits, and the following characters: -.=_/\r\n"
    )

    try_userid.(
      "café:baz",
      ":server 904 foo:bar :Invalid account/user id: your local name may only contain lowercase latin letters, digits, and the following characters: -.=_/\r\n"
    )

    try_userid.(
      "foo:bar",
      ":server 900 foo:bar foo:bar!foo@bar foo:bar :You are now logged in as foo:bar\r\n"
    )

    assert_line(":server 903 foo:bar :Authentication successful\r\n")

    send(handler, cmd("CAP END"))

    assert_welcome("foo:bar")

    send(handler, cmd("PING sync2"))
    assert_line("PONG :sync2\r\n")

    assert Matrix2051.IrcConn.State.nick(state) == "foo:bar"
    assert Matrix2051.IrcConn.State.gecos(state) == "My GECOS"
  end

  test "Account registration", %{handler: handler} do
    send(handler, cmd("CAP LS 302"))
    assert_line(@cap_ls_302)

    send(handler, cmd("CAP REQ sasl"))
    assert_line("CAP * ACK :sasl\r\n")

    send(handler, cmd("NICK user:example.org"))
    send(handler, cmd("USER ident * * :My GECOS"))

    send(handler, cmd("REGISTER * * :my p4ssw0rd"))

    assert_line(
      "REGISTER SUCCESS user:example.org :You are now registered as user:example.org\r\n"
    )

    assert_line(
      ":server 900 user:example.org user:example.org!user@example.org user:example.org :You are now logged in as user:example.org\r\n"
    )

    send(handler, cmd("CAP END"))

    assert_welcome("user:example.org")
  end

  test "labeled response", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("@label=abcd PING sync1"))
    assert_line("@label=abcd PONG :sync1\r\n")
  end

  test "joining a room", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("@label=abcd JOIN #existing_room:example.org"))
    assert_line("@label=abcd ACK\r\n")
  end

  test "ignores TAGMSG", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("TAGMSG #"))

    send(handler, cmd("PING sync1"))
    assert_line("PONG :sync1\r\n")
  end

  test "sending privmsg", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("PRIVMSG #existing_room:example.org :hello world"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{"body" => "hello world", "msgtype" => "m.text"}}
    )
  end

  test "sending formatted privmsg", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("PRIVMSG #existing_room:example.org :\x02hello \x1dworld\x1d\x02"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{
         "body" => "*hello /world/*",
         "format" => "org.matrix.custom.html",
         "formatted_body" => "<b>hello </b><i><b>world</b></i>",
         "msgtype" => "m.text"
       }}
    )
  end

  test "sending privmsg + ACTION", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("PRIVMSG #existing_room:example.org :\x01ACTION says hello\x01"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{"body" => "says hello", "msgtype" => "m.emote"}}
    )
  end

  test "sending notice", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("NOTICE #existing_room:example.org :hello world"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{"body" => "hello world", "msgtype" => "m.notice"}}
    )
  end

  test "sending privmsg with label", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("@label=foo PRIVMSG #existing_room:example.org :hello world"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", "foo",
       %{"body" => "hello world", "msgtype" => "m.text"}}
    )
  end

  test "sending multiline privmsg", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("BATCH +tag draft/multiline #existing_room:example.org"))
    send(handler, cmd("@batch=tag PRIVMSG #existing_room:example.org :hello"))
    send(handler, cmd("@batch=tag PRIVMSG #existing_room:example.org :world"))
    send(handler, cmd("@batch=tag;draft/multiline-concat PRIVMSG #existing_room:example.org :!"))
    send(handler, cmd("BATCH -tag"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{"body" => "hello\nworld!", "msgtype" => "m.text"}}
    )
  end

  test "sending multiline privmsg + ACTION", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("BATCH +tag draft/multiline #existing_room:example.org"))
    send(handler, cmd("@batch=tag PRIVMSG #existing_room:example.org :\x01ACTION says"))
    send(handler, cmd("@batch=tag PRIVMSG #existing_room:example.org :hello"))

    send(
      handler,
      cmd("@batch=tag;draft/multiline-concat PRIVMSG #existing_room:example.org :!\x01")
    )

    send(handler, cmd("BATCH -tag"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{"body" => "says\nhello!", "msgtype" => "m.emote"}}
    )
  end

  test "sending multiline notice", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("BATCH +tag draft/multiline #existing_room:example.org"))
    send(handler, cmd("@batch=tag NOTICE #existing_room:example.org :hello"))
    send(handler, cmd("@batch=tag NOTICE #existing_room:example.org :world"))
    send(handler, cmd("@batch=tag;draft/multiline-concat NOTICE #existing_room:example.org :!"))
    send(handler, cmd("BATCH -tag"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{"body" => "hello\nworld!", "msgtype" => "m.notice"}}
    )
  end

  test "sending multiline privmsg with label", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("@label=foo BATCH +tag draft/multiline #existing_room:example.org"))
    send(handler, cmd("@batch=tag PRIVMSG #existing_room:example.org :hello"))
    send(handler, cmd("@batch=tag PRIVMSG #existing_room:example.org :world"))
    send(handler, cmd("@batch=tag;draft/multiline-concat PRIVMSG #existing_room:example.org :!"))
    send(handler, cmd("BATCH -tag"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", "foo",
       %{"body" => "hello\nworld!", "msgtype" => "m.text"}}
    )
  end

  test "sending privmsg reply", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("@+draft/reply=$event1 PRIVMSG #existing_room:example.org :hello world"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{
         "body" => "hello world",
         "msgtype" => "m.text",
         "m.relates_to" => %{
           "m.in_reply_to" => %{
             "event_id" => "$event1"
           }
         }
       }}
    )
  end

  test "sending privmsg + ACTION reply", %{handler: handler} do
    do_connection_registration(handler)

    send(
      handler,
      cmd("@+draft/reply=$event1 PRIVMSG #existing_room:example.org :\x01ACTION says hello\x01")
    )

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{
         "body" => "says hello",
         "msgtype" => "m.emote",
         "m.relates_to" => %{
           "m.in_reply_to" => %{
             "event_id" => "$event1"
           }
         }
       }}
    )
  end

  test "sending notice reply", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("@+draft/reply=$event1 NOTICE #existing_room:example.org :hello world"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{
         "body" => "hello world",
         "msgtype" => "m.notice",
         "m.relates_to" => %{
           "m.in_reply_to" => %{
             "event_id" => "$event1"
           }
         }
       }}
    )
  end

  test "sending multiline privmsg reply", %{handler: handler} do
    do_connection_registration(handler)

    send(
      handler,
      cmd("@+draft/reply=$event1 BATCH +tag draft/multiline #existing_room:example.org")
    )

    send(handler, cmd("@batch=tag PRIVMSG #existing_room:example.org :hello"))
    send(handler, cmd("@batch=tag PRIVMSG #existing_room:example.org :world"))
    send(handler, cmd("@batch=tag;draft/multiline-concat PRIVMSG #existing_room:example.org :!"))
    send(handler, cmd("BATCH -tag"))

    assert_message(
      {:send_event, "#existing_room:example.org", "m.room.message", nil,
       %{
         "body" => "hello\nworld!",
         "msgtype" => "m.text",
         "m.relates_to" => %{
           "m.in_reply_to" => %{
             "event_id" => "$event1"
           }
         }
       }}
    )
  end

  test "WHO o on channel", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("@label=l1 WHO #nonexistant_room:example.org o"))

    assert_line(
      "@label=l1 :server 315 foo:example.org #nonexistant_room:example.org :End of WHO list\r\n"
    )

    send(handler, cmd("@label=l2 WHO #existing_room:example.org o"))

    assert_line(
      "@label=l2 :server 315 foo:example.org #existing_room:example.org :End of WHO list\r\n"
    )
  end

  test "WHO on channel", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("@label=l1 WHO #nonexistant_room:example.org"))

    # No reply because the room is not synced (and never will be)
    send(handler, cmd("PING sync1"))
    assert_line("PONG :sync1\r\n")

    send(handler, cmd("@label=l2 WHO #existing_room:example.org"))

    {batch_id, line} = assert_open_batch()
    assert line == "@label=l2 BATCH +#{batch_id} :labeled-response\r\n"

    assert_line(
      "@batch=#{batch_id} :server 352 foo:example.org #existing_room:example.org foo example.org * user1:example.org H :0 user1:example.org\r\n"
    )

    assert_line(
      "@batch=#{batch_id} :server 352 foo:example.org #existing_room:example.org foo example.org * user2:example.com H :0 user2:example.com\r\n"
    )

    assert_line(
      "@batch=#{batch_id} :server 315 foo:example.org #existing_room:example.org :End of WHO list\r\n"
    )

    assert_line("BATCH :-#{batch_id}\r\n")
  end

  test "WHO on channel without label", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("WHO #nonexistant_room:example.org"))

    # No reply because the room is not synced (and never will be)
    send(handler, cmd("PING sync1"))
    assert_line("PONG :sync1\r\n")

    send(handler, cmd("WHO #existing_room:example.org"))

    assert_line(
      ":server 352 foo:example.org #existing_room:example.org foo example.org * user1:example.org H :0 user1:example.org\r\n"
    )

    assert_line(
      ":server 352 foo:example.org #existing_room:example.org foo example.org * user2:example.com H :0 user2:example.com\r\n"
    )

    assert_line(":server 315 foo:example.org #existing_room:example.org :End of WHO list\r\n")
  end

  test "WHO on user", %{handler: handler} do
    do_connection_registration(handler)

    send(handler, cmd("@label=l1 WHO otheruser:example.org"))

    {batch_id, line} = assert_open_batch()
    assert line == "@label=l1 BATCH +#{batch_id} :labeled-response\r\n"

    assert_line(
      "@batch=#{batch_id} :server 352 foo:example.org * otheruser example.org * otheruser:example.org H :0 otheruser:example.org\r\n"
    )

    assert_line(
      "@batch=#{batch_id} :server 315 foo:example.org otheruser:example.org :End of WHO list\r\n"
    )

    assert_line("BATCH :-#{batch_id}\r\n")
  end
end
