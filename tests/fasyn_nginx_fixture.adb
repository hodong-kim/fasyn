-- ============================================================================
-- fasyn_nginx_fixture.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Command_Line;
with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with Fasyn.Classic;
with Fasyn.Listener;
with Fasyn.Protocol;
with Fasyn.Request;
with Fasyn.Request.Connection;
with Fasyn.Request.Execution;

procedure Fasyn_Nginx_Fixture is

  package P renames Fasyn.Protocol;
  package R renames Fasyn.Request;
  package RC renames Fasyn.Request.Connection;
  package E renames Fasyn.Request.Execution;

  use type Clair.Status.Code;
  use type P.Byte;
  use type R.Write_Status;

  EXPECTED_BODY : constant String := "fasyn-nginx-body";
  CRLF : constant String :=
    [1 => Character'Val(13), 2 => Character'Val(10)];

  function matches
    (data : P.Byte_Array;
     text : String) return Boolean
  is
  begin
    if data'length /= text'length then
      return False;
    end if;

    for offset in 0 .. text'length - 1 loop
      if data(data'first + offset) /=
           P.Byte(Character'Pos(text(text'first + offset)))
      then
        return False;
      end if;
    end loop;

    return True;
  end matches;

  function to_bytes (text : String) return P.Byte_Array is
    result : P.Byte_Array (1 .. text'length);
  begin
    for offset in 0 .. text'length - 1 loop
      result(offset + 1) :=
        P.Byte(Character'Pos(text(text'first + offset)));
    end loop;
    return result;
  end to_bytes;

  type Nginx_Application is new R.Application with record
    method_ok     : Boolean := False;
    query_ok      : Boolean := False;
    params_closed : Boolean := False;
    body_ok       : Boolean := True;
    body_length   : Natural := 0;
    input_bytes   : P.Byte_Array (1 .. 256) := [others => 0];
  end record;

  overriding procedure on_parameter
    (self    : in out Nginx_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Nginx_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Nginx_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Nginx_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Nginx_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (context);
  begin
    if matches (name, "REQUEST_METHOD") then
      self.method_ok := matches (value, "POST");
    elsif matches (name, "QUERY_STRING") then
      self.query_ok := matches (value, "probe=nginx");
    end if;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Nginx_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.params_closed := True;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Nginx_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    if self.body_length + data'length > self.input_bytes'length then
      self.body_ok := False;
      return;
    end if;

    for offset in 0 .. data'length - 1 loop
      self.input_bytes(self.body_length + offset + 1) :=
        data(data'first + offset);
    end loop;
    self.body_length := self.body_length + data'length;
  end on_stdin;

  procedure write_response
    (response : in out R.Writer;
     success  : Boolean)
  is
    success_text : constant String :=
      "Status: 200 OK" & CRLF &
      "Content-Type: text/plain" & CRLF &
      "Content-Length: 15" & CRLF & CRLF &
      "fasyn-nginx-ok" & Character'Val(10);
    failure_text : constant String :=
      "Status: 500 Internal Server Error" & CRLF &
      "Content-Type: text/plain" & CRLF &
      "Content-Length: 21" & CRLF & CRLF &
      "fasyn-nginx-mismatch" & Character'Val(10);
    write_status  : R.Write_Status;
    finish_status : R.Write_Status;
  begin
    if success then
      declare
        data : constant P.Byte_Array := to_bytes (success_text);
      begin
        R.write_stdout (response, data, write_status);
      end;
    else
      declare
        data : constant P.Byte_Array := to_bytes (failure_text);
      begin
        R.write_stdout (response, data, write_status);
      end;
    end if;

    if write_status = R.Write_Complete then
      R.finish (response, 0, finish_status);
    end if;
  end write_response;

  overriding procedure on_stdin_end
    (self     : in out Nginx_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    body_matches : Boolean := self.body_ok and then
      self.body_length = EXPECTED_BODY'length;
  begin
    if body_matches then
      for offset in 0 .. EXPECTED_BODY'length - 1 loop
        if self.input_bytes(offset + 1) /=
             P.Byte(Character'Pos(EXPECTED_BODY(EXPECTED_BODY'first + offset)))
        then
          body_matches := False;
          exit;
        end if;
      end loop;
    end if;

    write_response
      (response,
       self.method_ok and then self.query_ok and then
       self.params_closed and then body_matches);
  end on_stdin_end;

  type Server_Handler is limited new
    Fasyn.Listener.Accept_Handler with record
    event_loop  : Clair.Event_Loop.Context_Access := null;
    executor    : E.Context_Access := null;
    application : aliased Nginx_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 256,
       max_value_bytes             => 1_024,
       max_request_output_bytes    => 1_024,
       max_output_bytes            => 1_024,
       read_buffer_bytes           => 512,
       write_chunk_bytes           => 256);
    accepted : Boolean := False;
  end record;

  overriding function on_accept
    (self : in out Server_Handler;
     fd   : Clair.IO.Descriptor) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if self.accepted then
      return Clair.IO.close (fd);
    end if;

    status := RC.initialize
      (self            => self.connection,
       event_loop      => self.event_loop,
       fd              => fd,
       handler         => self.application'Unchecked_Access,
       executor        => self.executor,
       request_timeout => 5_000,
       connection_id   => 1,
       input_limits    =>
         (max_params_bytes => 16_384,
          max_stdin_bytes  => 1_024,
          max_data_bytes   => 1));

    if status = Clair.Status.OK then
      self.accepted := True;
    end if;
    return status;
  end on_accept;

  loop_context : aliased Clair.Event_Loop.Context;
  executor     : aliased E.Context;
  classic      : aliased Fasyn.Classic.Context;
  server       : aliased Server_Handler;
  status       : Clair.Status.Code;
  dispatched   : Boolean;
  loop_ready   : Boolean := False;
  executor_ready : Boolean := False;
  classic_ready  : Boolean := False;
  request_done   : Boolean := False;

  procedure fail (code : Ada.Command_Line.Exit_Status) is
  begin
    Ada.Command_Line.set_exit_status (code);
  end fail;

begin
  status := Clair.Event_Loop.initialize (loop_context);
  loop_ready := status = Clair.Status.OK;
  if not loop_ready then
    fail (65);
    return;
  end if;

  status := E.initialize
    (self             => executor,
     event_loop       => loop_context'Unchecked_Access,
     worker_count     => 1,
     pending_capacity => 8,
     max_input_bytes  => 2_048,
     max_output_bytes => 2_048);
  executor_ready := status = Clair.Status.OK;
  if not executor_ready then
    fail (66);
    return;
  end if;

  server.event_loop := loop_context'Unchecked_Access;
  server.executor := executor'Unchecked_Access;
  status := Fasyn.Classic.initialize
    (self       => classic,
     event_loop => loop_context'Unchecked_Access,
     handler    => server'Unchecked_Access);
  classic_ready := status = Clair.Status.OK;
  if not classic_ready then
    fail (67);
    return;
  end if;

  for iteration in 1 .. 2_000 loop
    pragma Unreferenced (iteration);
    status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
    exit when status /= Clair.Status.OK;

    if server.accepted and then not RC.is_active(server.connection) then
      request_done := True;
      exit;
    end if;
  end loop;

  declare
    cleanup_ok : Boolean := status = Clair.Status.OK and then request_done;
  begin
    if classic_ready then
      status := Fasyn.Classic.finalize (classic);
      cleanup_ok := cleanup_ok and then status = Clair.Status.OK;
    end if;

    if server.accepted then
      if RC.is_active(server.connection) then
        status := RC.begin_shutdown (server.connection);
        cleanup_ok := cleanup_ok and then status = Clair.Status.OK;

        for iteration in 1 .. 200 loop
          pragma Unreferenced (iteration);
          exit when not RC.is_active(server.connection);
          status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
          exit when status /= Clair.Status.OK;
        end loop;
      end if;

      status := RC.finalize (server.connection);
      cleanup_ok := cleanup_ok and then status = Clair.Status.OK;
    end if;

    if executor_ready then
      status := E.begin_shutdown (executor);
      cleanup_ok := cleanup_ok and then status = Clair.Status.OK;

      for iteration in 1 .. 200 loop
        pragma Unreferenced (iteration);
        exit when E.is_idle(executor) and then
          E.completed_count(executor) = 0;
        status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
        exit when status /= Clair.Status.OK;
      end loop;

      status := E.finalize (executor);
      cleanup_ok := cleanup_ok and then status = Clair.Status.OK;
    end if;

    if loop_ready then
      status := Clair.Event_Loop.finalize (loop_context);
      cleanup_ok := cleanup_ok and then status = Clair.Status.OK;
    end if;

    if cleanup_ok then
      fail (0);
    elsif request_done then
      fail (69);
    else
      fail (68);
    end if;
  end;
end Fasyn_Nginx_Fixture;
