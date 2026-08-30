-- ============================================================================
-- tests-runtime.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Synchronous_Task_Control;
with Interfaces.C;
with System.Storage_Elements;
with Clair.Event_Loop;
with Clair.IO;
with Clair.IO.Posix;
with Clair.Status;
with Clair.Test.Assertions;
with Fasyn.Listener;
with Fasyn.Diagnostics;
with Fasyn.Protocol;
with Fasyn.Protocol.Codec;
with Fasyn.Protocol.Messages;
with Fasyn.Protocol.Name_Values;
with Fasyn.Request;
with Fasyn.Request.Connection;
with Fasyn.Request.Connection.Testing;
with Fasyn.Request.Execution;
with Fasyn.Request.Shutdown;

package body Tests.Runtime is

  package STC renames Ada.Synchronous_Task_Control;
  package A renames Clair.Test.Assertions;
  package D renames Fasyn.Diagnostics;
  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package M renames Fasyn.Protocol.Messages;
  package N renames Fasyn.Protocol.Name_Values;
  package R renames Fasyn.Request;
  package RC renames Fasyn.Request.Connection;
  package RCT renames Fasyn.Request.Connection.Testing;
  package E renames Fasyn.Request.Execution;
  package S renames Fasyn.Request.Shutdown;

  use type Interfaces.C.int;
  use type Interfaces.Unsigned_32;
  use type Clair.IO.Byte_Count;
  use type Clair.Status.Code;
  use type C.Decode_Status;
  use type D.Category;
  use type M.Body_Status;
  use type N.Encode_Status;
  use type R.Cancellation_Cause;
  use type R.Write_Status;
  use type S.Outcome;

  function c_socketpair
    (runtime_fd : access Interfaces.C.int;
     peer_fd    : access Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_socketpair";

  function c_listener_pair
    (listener_fd : access Interfaces.C.int;
     client_fd   : access Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_listener_pair";

  function c_is_nonblocking
    (fd : Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_is_nonblocking";

  type Accept_Recorder is new Fasyn.Listener.Accept_Handler with record
    count : Natural := 0;
  end record;

  overriding function on_accept
    (handler : in out Accept_Recorder;
     fd      : Clair.IO.Descriptor) return Clair.Status.Code;

  overriding function on_accept
    (handler : in out Accept_Recorder;
     fd      : Clair.IO.Descriptor) return Clair.Status.Code
  is
  begin
    handler.count := handler.count + 1;
    return Clair.IO.close (fd);
  end on_accept;

  type Diagnostic_Recorder is new D.Reporter with record
    count  : Natural := 0;
    kind   : D.Category := D.Protocol_Error;
    status : Clair.Status.Code := Clair.Status.OK;
  end record;

  overriding procedure report
    (self    : in out Diagnostic_Recorder;
     kind    : D.Category;
     status  : Clair.Status.Code;
     message : String)
  is
    pragma Unreferenced (message);
  begin
    self.count := self.count + 1;
    self.kind := kind;
    self.status := status;
  end report;

  type Test_Application is new R.Application with record
    parameter_count : Natural := 0;
    params_end_seen : Boolean := False;
    stdin_end_seen  : Boolean := False;
    large_write_ok  : Boolean := False;
    finish_ok       : Boolean := False;
  end record;

  overriding procedure on_parameter
    (self    : in out Test_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Test_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (context, name, value);
  begin
    self.parameter_count := self.parameter_count + 1;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    data   : constant P.Byte_Array (1 .. 60_000) := [others => 16#58#];
    status : R.Write_Status;
  begin
    self.params_end_seen := True;
    R.write_stdout (response, data, status);
    self.large_write_ok := status = R.Write_Complete;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, data, response);
  begin
    null;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    status : R.Write_Status;
  begin
    self.stdin_end_seen := True;
    R.finish (response, 0, status);
    self.finish_ok := status = R.Write_Complete;
  end on_stdin_end;

  type Limit_Application is new R.Application with record
    parameter_count      : Natural := 0;
    stdin_bytes          : Natural := 0;
    data_bytes           : Natural := 0;
    finish_on_stdin_end  : Boolean := False;
    finish_ok            : Boolean := False;
  end record;

  overriding procedure on_parameter
    (self : in out Limit_Application; context : in R.Request_Context;
     name : in P.Byte_Array; value : in P.Byte_Array);
  overriding procedure on_params_end
    (self : in out Limit_Application; context : in R.Request_Context;
     response : in out R.Writer);
  overriding procedure on_stdin
    (self : in out Limit_Application; context : in R.Request_Context;
     data : in P.Byte_Array; response : in out R.Writer);
  overriding procedure on_stdin_end
    (self : in out Limit_Application; context : in R.Request_Context;
     response : in out R.Writer);
  overriding procedure on_data
    (self : in out Limit_Application; context : in R.Request_Context;
     data : in P.Byte_Array; response : in out R.Writer);

  overriding procedure on_parameter
    (self : in out Limit_Application; context : in R.Request_Context;
     name : in P.Byte_Array; value : in P.Byte_Array)
  is
    pragma Unreferenced (context, name, value);
  begin
    self.parameter_count := self.parameter_count + 1;
  end on_parameter;

  overriding procedure on_params_end
    (self : in out Limit_Application; context : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin null; end on_params_end;

  overriding procedure on_stdin
    (self : in out Limit_Application; context : in R.Request_Context;
     data : in P.Byte_Array; response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.stdin_bytes := self.stdin_bytes + data'length;
  end on_stdin;

  overriding procedure on_stdin_end
    (self : in out Limit_Application; context : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    status : R.Write_Status;
  begin
    if self.finish_on_stdin_end then
      R.finish (response, 0, status);
      self.finish_ok := status = R.Write_Complete;
    end if;
  end on_stdin_end;

  overriding procedure on_data
    (self : in out Limit_Application; context : in R.Request_Context;
     data : in P.Byte_Array; response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.data_bytes := self.data_bytes + data'length;
  end on_data;

  type Runtime_Failure_Application is new Limit_Application with null record;

  overriding procedure on_stdin_end
    (self     : in out Runtime_Failure_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Runtime_Failure_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context);
    data   : constant P.Byte_Array := [1 => 16#58#];
    status : R.Write_Status;
  begin
    R.write_stdout (response, data, status);
    if status /= R.Write_Complete then
      raise Program_Error with "runtime failure fixture write failed";
    end if;
    raise Program_Error with "runtime callback failure fixture";
  end on_stdin_end;

  type Blocking_Application is limited new R.Application with record
    started               : STC.Suspension_Object;
    cancellation_observed : STC.Suspension_Object;
    release_gate          : STC.Suspension_Object;
    finish_after_release  : Boolean := False;
    wait_for_cancellation : Boolean := False;
    observed_cause        : R.Cancellation_Cause := R.Not_Cancelled;
  end record;

  overriding procedure on_parameter
    (self    : in out Blocking_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Blocking_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Blocking_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Blocking_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Blocking_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (self, context, name, value);
  begin
    null;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Blocking_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    data : constant P.Byte_Array (1 .. 4) :=
      [16#DE#, 16#AD#, 16#BE#, 16#EF#];
    write_status  : R.Write_Status;
    finish_status : R.Write_Status;
  begin
    STC.Set_True (self.started);

    if self.wait_for_cancellation then
      for attempt in 1 .. 1_000 loop
        pragma Unreferenced (attempt);
        self.observed_cause := R.cancellation_reason(context);
        exit when self.observed_cause /= R.Not_Cancelled;
        delay 0.001;
      end loop;
      STC.Set_True (self.cancellation_observed);
      STC.Suspend_Until_True (self.release_gate);
    else
      STC.Suspend_Until_True (self.release_gate);
      self.observed_cause := R.cancellation_reason(context);
    end if;

    R.write_stdout (response, data, write_status);
    if write_status = R.Write_Complete and then self.finish_after_release then
      R.finish (response, 0, finish_status);
      if finish_status /= R.Write_Complete then
        raise Program_Error with "blocking application finish failed";
      end if;
    end if;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Blocking_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, data, response);
  begin
    null;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Blocking_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin
    null;
  end on_stdin_end;

  function to_bytes (text : String) return P.Byte_Array is
    result : P.Byte_Array (1 .. text'length);
  begin
    for offset in 0 .. text'length - 1 loop
      result(offset + 1) :=
        P.Byte(Character'Pos(text(text'first + offset)));
    end loop;
    return result;
  end to_bytes;

  procedure append_pair
    (buffer : in out P.Byte_Array; position : in out Positive;
     name : String; value : String)
  is
    name_bytes : constant P.Byte_Array := to_bytes(name);
    value_bytes : constant P.Byte_Array := to_bytes(value);
    encoded : P.Byte_Array
      (1 .. N.encoded_size(name_bytes'length, value_bytes'length));
    written : Natural;
    status : N.Encode_Status;
  begin
    N.encode_pair
      (name_bytes, value_bytes, encoded, written, status);
    if status /= N.Encode_Complete or else
       position + written - 1 > buffer'last
    then
      raise Program_Error with "name-value fixture encoding failed";
    end if;
    for offset in 0 .. written - 1 loop
      buffer(position + offset) := encoded(encoded'first + offset);
    end loop;
    position := position + written;
  end append_pair;

  procedure append_record
    (buffer      : in out P.Byte_Array;
     position    : in out Positive;
     record_type : in P.Byte;
     content     : in P.Byte_Array)
  is
    record_header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => 1,
       content_length => P.Content_Length_Type(content'length),
       padding_length => 0,
       reserved       => 0);
    header_bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
  begin
    C.encode_header (record_header, header_bytes);

    for index in header_bytes'range loop
      buffer(position) := header_bytes(index);
      position := position + 1;
    end loop;

    for index in content'range loop
      buffer(position) := content(index);
      position := position + 1;
    end loop;
  end append_record;

  function write_all
    (fd   : Clair.IO.Descriptor;
     data : P.Byte_Array) return Clair.Status.Code
  is
    position : Natural := data'first;
    written  : Clair.IO.Byte_Count;
    status   : Clair.Status.Code;
  begin
    while position <= data'last loop
      status := Clair.IO.write
        (fd     => fd,
         buf    => data(position)'address,
         count  => Interfaces.C.size_t(data'last - position + 1),
         result => written);

      if status /= Clair.Status.OK then
        return status;
      end if;

      if written <= 0 then
        return Clair.Status.END_OF_STREAM;
      end if;

      position := position + Natural(written);
    end loop;

    return Clair.Status.OK;
  end write_all;

  procedure read_available
    (fd     : in Clair.IO.Descriptor;
     output : in out P.Byte_Array;
     length : in out Natural)
  is
    buffer : System.Storage_Elements.Storage_Array (1 .. 4096);
    count  : Clair.IO.Byte_Count;
    status : Clair.Status.Code;
  begin
    loop
      status := Clair.IO.read (fd, buffer, count);

      if status = Clair.Status.OK then
        exit when count = 0;

        for index in 1 .. Natural(count) loop
          exit when length = output'length;
          length := length + 1;
          output(output'first + length - 1) :=
            P.Byte(buffer(System.Storage_Elements.Storage_Offset(index)));
        end loop;
      elsif Clair.IO.Posix.is_would_block (status) then
        exit;
      else
        exit;
      end if;
    end loop;
  end read_available;

  function drain_peer (fd : Clair.IO.Descriptor) return Natural is
    buffer : System.Storage_Elements.Storage_Array (1 .. 8192);
    count  : Clair.IO.Byte_Count;
    status : Clair.Status.Code;
    total  : Natural := 0;
  begin
    loop
      status := Clair.IO.read (fd, buffer, count);

      if status = Clair.Status.OK then
        exit when count = 0;
        total := total + Natural(count);
      elsif Clair.IO.Posix.is_would_block (status) then
        exit;
      else
        exit;
      end if;
    end loop;

    return total;
  end drain_peer;

  procedure listener_lifecycle
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    listener     : aliased Fasyn.Listener.Context;
    recorder     : aliased Accept_Recorder;
    listener_raw : aliased Interfaces.C.int := -1;
    client_raw   : aliased Interfaces.C.int := -1;
    listener_fd  : Clair.IO.Descriptor;
    client_fd    : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
  begin
    native_error := c_listener_pair (listener_raw'access, client_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "listener fixture is created");

    listener_fd := Clair.IO.Descriptor(listener_raw);
    client_fd := Clair.IO.Descriptor(client_raw);

    A.assert_equal_integer
      (reporter,
       Integer(c_is_nonblocking(listener_raw)),
       0,
       "inherited listener starts blocking");

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "event loop initializes");

    status := Fasyn.Listener.initialize
      (self       => listener,
       event_loop => loop_context'Unchecked_Access,
       fd         => listener_fd,
       handler    => recorder'Unchecked_Access);
    A.assert_true (reporter, status = Clair.Status.OK, "listener initializes");
    A.assert_true
      (reporter,
       Fasyn.Listener.is_active(listener),
       "listener watch is active");
    A.assert_equal_integer
      (reporter,
       Integer(c_is_nonblocking(listener_raw)),
       1,
       "listener enters nonblocking mode while watched");

    status := Clair.Event_Loop.iterate (loop_context, 100, dispatched);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "listener event dispatch succeeds");
    A.assert_true (reporter, dispatched, "listener readiness dispatches");
    A.assert_equal_natural
      (reporter, recorder.count, 1, "one accepted connection reaches handler");

    status := Fasyn.Listener.finalize (listener);
    A.assert_true (reporter, status = Clair.Status.OK, "listener finalizes");
    A.assert_equal_integer
      (reporter,
       Integer(c_is_nonblocking(listener_raw)),
       0,
       "listener restores original blocking mode");

    status := Clair.IO.close (client_fd);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "listener client closes");
    status := Clair.IO.close (listener_fd);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "listener descriptor remains caller-owned");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true (reporter, status = Clair.Status.OK, "event loop finalizes");
  end listener_lifecycle;

  procedure bounded_connection_backpressure
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Test_Application;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 65_536,
       max_output_bytes            => 65_536,
       read_buffer_bytes => 5,
       write_chunk_bytes => 4_096);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    begin_request : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE,
       flags     => 0);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : M.Body_Status;
    empty : P.Byte_Array (1 .. 0);
    input : P.Byte_Array (1 .. 32);
    position : Positive := input'first;
    stalled_pending : Natural;
    drained : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "nonblocking socketpair is created");

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "event loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => loop_context'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 128,
       max_output_bytes => 65_536);
    A.assert_true (reporter, status = Clair.Status.OK, "executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => loop_context'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 1);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "connection watch initializes");

    M.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written,
       status       => body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       begin_written = M.BEGIN_REQUEST_BODY_LENGTH,
       "BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, P.PARAMS_TYPE, empty);
    append_record (input, position, P.STDIN_TYPE, empty);
    A.assert_equal_natural
      (reporter,
       position,
       input'last + 1,
       "complete request occupies expected bytes");

    status := write_all (peer_fd, input);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "fragmented request is written to peer");

    for iteration in 1 .. 200 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "connection input/completion dispatch succeeds");
      exit when RC.pending_output_bytes(connection) > 0;
    end loop;

    A.assert_positive
      (reporter,
       Integer(RC.pending_output_bytes(connection)),
       "application completion returns output to connection");
    A.assert_true
      (reporter,
       application.params_end_seen,
       "PARAMS EOF reaches application");
    A.assert_true
      (reporter,
       application.large_write_ok,
       "large bounded response is accepted");
    A.assert_true
      (reporter,
       RC.is_read_paused(connection),
       "high-water output pauses input");
    A.assert_false
      (reporter,
       application.stdin_end_seen,
       "high-water backpressure keeps probed STDIN EOF pending");
    A.assert_positive
      (reporter,
       Integer(RC.pending_input_bytes(connection)),
       "bytes already read after PARAMS EOF remain bounded and pending");
    A.assert_positive
      (reporter,
       Integer(RC.pending_output_bytes(connection)),
       "partial write leaves queued output");
    A.assert_true
      (reporter,
       RC.pending_output_bytes(connection) <= 65_536,
       "queued output never exceeds configured bound");
    A.assert_true
      (reporter,
       RC.pending_input_bytes(connection) <= P.HEADER_LENGTH + 255,
       "pending input stays within bounded control-probe storage");

    for iteration in 1 .. 16 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate
        (loop_context, Clair.Event_Loop.IMMEDIATE, dispatched);
      A.assert_true
        (reporter,
         status = Clair.Status.OK,
         "stalled-peer iteration succeeds");
    end loop;

    stalled_pending := RC.pending_output_bytes(connection);
    A.assert_positive
      (reporter,
       Integer(stalled_pending),
       "peer that does not read leaves bounded output pending");
    A.assert_true
      (reporter,
       stalled_pending <= 65_536,
       "stalled peer cannot grow connection output beyond bound");

    for round in 1 .. 1_000 loop
      pragma Unreferenced (round);
      drained := drained + drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      A.assert_true
        (reporter,
         status = Clair.Status.OK,
         "drain iteration succeeds");
      exit when not RC.is_active(connection);
    end loop;

    A.assert_positive
      (reporter, Integer(drained), "peer receives serialized response bytes");
    A.assert_true
      (reporter,
       application.stdin_end_seen,
       "input resumes and STDIN EOF is delivered");
    A.assert_true
      (reporter,
       application.finish_ok,
       "application response finishes after resume");
    A.assert_false
      (reporter,
       RC.is_active(connection),
       "non-KEEP_CONN request closes after drain");

    status := RC.finalize (connection);
    A.assert_true (reporter, status = Clair.Status.OK, "connection finalizes");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true (reporter, status = Clair.Status.OK, "executor finalizes");

    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "peer descriptor closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true (reporter, status = Clair.Status.OK, "event loop finalizes");
  end bounded_connection_backpressure;

  procedure application_callback_failure
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Runtime_Failure_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1024,
       max_output_bytes            => 1024,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    loop_ok      : Boolean := True;
    begin_request : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : M.Body_Status;
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array
      (1 .. 3 * P.HEADER_LENGTH + M.BEGIN_REQUEST_BODY_LENGTH);
    input_position : Positive := input'first;
    output         : P.Byte_Array (1 .. 64);
    output_length  : Natural := 0;
    header_bytes   : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    record_header  : P.Header;
    decode_status  : C.Decode_Status;
    end_bytes      : P.Byte_Array (0 .. M.END_REQUEST_BODY_LENGTH - 1);
    end_body       : M.End_Request_Body;
    end_status     : M.Body_Status;
    output_position : Positive := output'first;
    expected_length : constant Natural :=
      3 * P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH;

    procedure decode_next_header is
    begin
      for index in header_bytes'range loop
        header_bytes(index) := output(output_position + index);
      end loop;
      C.decode_header (header_bytes, record_header, decode_status);
      output_position :=
        output_position + P.HEADER_LENGTH +
        Natural(record_header.content_length) +
        Natural(record_header.padding_length);
    end decode_next_header;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "callback-failure socketpair is created");

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "callback-failure socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "callback-failure loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 128,
       max_output_bytes => 1024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "callback-failure executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 92);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "callback-failure connection initializes");

    M.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written,
       status       => body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       begin_written = M.BEGIN_REQUEST_BODY_LENGTH,
       "callback-failure BEGIN_REQUEST body encodes");

    append_record (input, input_position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, input_position, P.PARAMS_TYPE, empty);
    append_record (input, input_position, P.STDIN_TYPE, empty);
    A.assert_equal_natural
      (reporter, input_position, input'last + 1,
       "callback-failure request occupies expected bytes");

    status := write_all (peer_fd, input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "callback-failure request is written");

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      read_available (peer_fd, output, output_length);
      exit when
        RC.active_request_count(connection) = 0 and then
        RC.pending_output_bytes(connection) = 0 and then
        output_length >= expected_length;
    end loop;
    read_available (peer_fd, output, output_length);

    A.assert_true
      (reporter, loop_ok, "callback-failure runtime remains healthy");
    A.assert_equal_natural
      (reporter, output_length, expected_length,
       "callback failure emits only terminal FastCGI records");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "callback failure retires only its request");
    A.assert_true
      (reporter, RC.is_active(connection),
       "KEEP_CONN transport survives callback failure");

    decode_next_header;
    A.assert_true
      (reporter, decode_status = C.Complete,
       "callback-failure STDOUT header decodes");
    A.assert_equal_integer
      (reporter, Integer(record_header.record_type), Integer(P.STDOUT_TYPE),
       "callback failure closes STDOUT");
    A.assert_equal_integer
      (reporter, Integer(record_header.content_length), 0,
       "callback failure does not commit STDOUT payload");

    decode_next_header;
    A.assert_true
      (reporter, decode_status = C.Complete,
       "callback-failure STDERR header decodes");
    A.assert_equal_integer
      (reporter, Integer(record_header.record_type), Integer(P.STDERR_TYPE),
       "callback failure closes STDERR");
    A.assert_equal_integer
      (reporter, Integer(record_header.content_length), 0,
       "callback failure does not synthesize STDERR text");

    decode_next_header;
    A.assert_true
      (reporter, decode_status = C.Complete,
       "callback-failure END_REQUEST header decodes");
    A.assert_equal_integer
      (reporter, Integer(record_header.record_type),
       Integer(P.END_REQUEST_TYPE),
       "callback failure emits END_REQUEST");
    A.assert_equal_integer
      (reporter, Integer(record_header.content_length),
       M.END_REQUEST_BODY_LENGTH,
       "callback failure emits complete END_REQUEST body");

    for index in end_bytes'range loop
      end_bytes(index) :=
        output(output_position - M.END_REQUEST_BODY_LENGTH + index);
    end loop;
    M.decode_end_request (end_bytes, end_body, end_status);
    A.assert_true
      (reporter, end_status = M.Body_Complete,
       "callback-failure END_REQUEST body decodes");
    A.assert_true
      (reporter, end_body.application_status = 1,
       "callback failure maps to appStatus 1");
    A.assert_equal_integer
      (reporter, Integer(end_body.protocol_status_code),
       Integer(P.REQUEST_COMPLETE_STATUS),
       "callback failure keeps REQUEST_COMPLETE protocol status");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "callback-failure connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "callback-failure executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "callback-failure executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "callback-failure peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "callback-failure loop finalizes");
  end application_callback_failure;

  procedure request_timeout_cancellation
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Test_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1024,
       max_output_bytes            => 1024,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    loop_ok      : Boolean := True;
    begin_request : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : M.Body_Status;
    input         : P.Byte_Array
      (1 .. P.HEADER_LENGTH + M.BEGIN_REQUEST_BODY_LENGTH);
    position      : Positive := input'first;
    drained       : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "timeout socketpair is created");

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "timeout loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 128,
       max_output_bytes => 1024);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "timeout executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_timeout => 20,
       connection_id   => 2);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "timeout connection initializes");

    M.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written,
       status       => body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       begin_written = M.BEGIN_REQUEST_BODY_LENGTH,
       "timeout BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    status := write_all (peer_fd, input);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "timeout request is written");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;

      exit when
        RCT.current_cancellation_reason(connection, 1) = R.Request_Timeout;
    end loop;

    A.assert_true (reporter, loop_ok, "timeout event-loop iterations succeed");
    A.assert_true
      (reporter,
       RCT.current_cancellation_reason(connection, 1) = R.Request_Timeout,
       "request lifetime expiry records Request_Timeout");
    A.assert_true
      (reporter, RC.is_active(connection),
       "KEEP_CONN transport remains active while timeout output drains");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      drained := drained + drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when RC.active_request_count(connection) = 0;
    end loop;

    drained := drained + drain_peer (peer_fd);
    A.assert_true (reporter, loop_ok, "timeout drain iterations succeed");
    A.assert_positive
      (reporter,
       Integer(drained),
       "timeout emits FastCGI completion output");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "timed-out request retires after completion output drains");
    A.assert_true
      (reporter, RC.is_active(connection),
       "KEEP_CONN connection remains reusable after request timeout");

    status := RC.finalize (connection);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "timeout connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "timeout executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "timeout executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true (reporter, status = Clair.Status.OK, "timeout peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "timeout loop finalizes");
  end request_timeout_cancellation;

  procedure runtime_shutdown_cancellation
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Test_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1024,
       max_output_bytes            => 1024,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    loop_ok      : Boolean := True;
    begin_request : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : M.Body_Status;
    input         : P.Byte_Array
      (1 .. P.HEADER_LENGTH + M.BEGIN_REQUEST_BODY_LENGTH);
    position      : Positive := input'first;
    drained       : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "shutdown socketpair is created");

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "shutdown loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 128,
       max_output_bytes => 1024);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "shutdown executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 3);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "shutdown connection initializes");

    M.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written,
       status       => body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       begin_written = M.BEGIN_REQUEST_BODY_LENGTH,
       "shutdown BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    status := write_all (peer_fd, input);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "shutdown request is written");

    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when RC.active_request_count(connection) = 1;
    end loop;

    A.assert_true (reporter, loop_ok, "shutdown admission iterations succeed");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 1,
       "request is active before runtime shutdown");

    status := RC.begin_shutdown (connection);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "connection shutdown begins");
    A.assert_true
      (reporter,
       RCT.current_cancellation_reason(connection, 1) = R.Runtime_Shutdown,
       "runtime shutdown cause reaches active request");
    A.assert_true
      (reporter, RC.is_read_paused(connection),
       "runtime shutdown stops further connection input");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      drained := drained + drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when not RC.is_active(connection);
    end loop;

    drained := drained + drain_peer (peer_fd);
    A.assert_true (reporter, loop_ok, "shutdown drain iterations succeed");
    A.assert_positive
      (reporter,
       Integer(drained),
       "shutdown emits FastCGI completion output");
    A.assert_false
      (reporter, RC.is_active(connection),
       "runtime shutdown closes connection after cancellation output drains");

    status := RC.finalize (connection);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "shutdown connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "shutdown executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "shutdown executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true (reporter, status = Clair.Status.OK, "shutdown peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "shutdown loop finalizes");
  end runtime_shutdown_cancellation;

  procedure peer_abort_while_execution_pending
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Blocking_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1024,
       max_output_bytes            => 1024,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    loop_ok      : Boolean := True;
    begin_request : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : M.Body_Status;
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array
      (1 .. 2 * P.HEADER_LENGTH + M.BEGIN_REQUEST_BODY_LENGTH);
    abort_input   : P.Byte_Array (1 .. P.HEADER_LENGTH);
    position      : Positive := input'first;
    abort_position : Positive := abort_input'first;
    drained       : Natural := 0;
    abort_seen_while_running : Boolean := False;
    expected_bytes : constant Natural :=
      3 * P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH;
  begin
    application.finish_after_release := False;
    application.wait_for_cancellation := True;

    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "pending-abort socketpair is created");

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "pending-abort socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "pending-abort loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 128,
       max_output_bytes => 1024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "pending-abort executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 4);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "pending-abort connection initializes");

    M.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written,
       status       => body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       begin_written = M.BEGIN_REQUEST_BODY_LENGTH,
       "pending-abort BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, P.PARAMS_TYPE, empty);
    A.assert_equal_natural
      (reporter, position, input'last + 1,
       "pending-abort request occupies expected bytes");

    status := write_all (peer_fd, input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "pending-abort request is written");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when STC.Current_State (application.started);
    end loop;

    A.assert_true
      (reporter, loop_ok and then STC.Current_State(application.started),
       "application callback starts before peer abort");
    A.assert_equal_natural
      (reporter, E.active_count(executor), 1,
       "application work remains active while abort is sent");

    append_record (abort_input, abort_position, P.ABORT_REQUEST_TYPE, empty);
    A.assert_equal_natural
      (reporter, abort_position, abort_input'last + 1,
       "ABORT_REQUEST occupies one empty record");

    status := write_all (peer_fd, abort_input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "ABORT_REQUEST is written while application work is active");

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when STC.Current_State(application.cancellation_observed);
    end loop;

    abort_seen_while_running :=
      STC.Current_State(application.cancellation_observed) and then
      application.observed_cause = R.Peer_Abort and then
      E.active_count(executor) = 1;

    STC.Set_True (application.release_gate);

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      drained := drained + drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when
        RC.active_request_count(connection) = 0 and then
        E.active_count(executor) = 0 and then
        E.completed_count(executor) = 0;
    end loop;

    drained := drained + drain_peer (peer_fd);
    A.assert_true
      (reporter, loop_ok,
       "pending-abort completion iterations succeed");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "peer abort eventually retires request after running callback returns");
    A.assert_true
      (reporter, RC.is_active(connection),
       "KEEP_CONN transport survives peer abort");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "pending-abort connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "pending-abort executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "pending-abort executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "pending-abort peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "pending-abort loop finalizes");
    A.assert_equal_natural
      (reporter, drained, expected_bytes,
       "peer abort rejects late callback output and emits cancellation");
    A.assert_true
      (reporter, abort_seen_while_running,
       "running application observes Peer_Abort before release");
  end peer_abort_while_execution_pending;

  procedure late_worker_output_after_timeout
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Blocking_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1024,
       max_output_bytes            => 1024,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    loop_ok      : Boolean := True;
    begin_request : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : M.Body_Status;
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array
      (1 .. 2 * P.HEADER_LENGTH + M.BEGIN_REQUEST_BODY_LENGTH);
    position      : Positive := input'first;
    drained       : Natural := 0;
    cancellation_bytes : constant Natural :=
      3 * P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH;
  begin
    application.finish_after_release := True;

    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "late-output socketpair is created");

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "late-output socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late-output loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 128,
       max_output_bytes => 1024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late-output executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_timeout => 100,
       connection_id   => 5);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late-output connection initializes");

    M.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written,
       status       => body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       begin_written = M.BEGIN_REQUEST_BODY_LENGTH,
       "late-output BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, P.PARAMS_TYPE, empty);
    A.assert_equal_natural
      (reporter, position, input'last + 1,
       "late-output request occupies expected bytes");

    status := write_all (peer_fd, input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late-output request is written");

    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when STC.Current_State (application.started);
    end loop;

    A.assert_true
      (reporter, loop_ok and then STC.Current_State(application.started),
       "application callback is running before timeout");
    A.assert_equal_natural
      (reporter, E.active_count(executor), 1,
       "worker remains active while timeout is armed");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when
        RCT.current_cancellation_reason(connection, 1) = R.Request_Timeout;
    end loop;

    A.assert_true
      (reporter, loop_ok,
       "late-output timeout iterations succeed");
    A.assert_true
      (reporter,
       RCT.current_cancellation_reason(connection, 1) = R.Request_Timeout,
       "timeout cancels request while worker is still running");
    A.assert_equal_natural
      (reporter, E.active_count(executor), 1,
       "worker remains active after request cancellation");

    STC.Set_True (application.release_gate);

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      drained := drained + drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when
        RC.active_request_count(connection) = 0 and then
        E.active_count(executor) = 0 and then
        E.completed_count(executor) = 0;
    end loop;

    drained := drained + drain_peer (peer_fd);
    A.assert_true
      (reporter, loop_ok,
       "late-output completion iterations succeed");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "timed-out request retires after cancellation output drains");
    A.assert_true
      (reporter, RC.is_active(connection),
       "KEEP_CONN transport survives late worker completion");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late-output connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late-output executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late-output executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late-output peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late-output loop finalizes");
    A.assert_equal_natural
      (reporter, drained, cancellation_bytes,
       "late worker output is rejected after request timeout");
    A.assert_true
      (reporter,
       application.observed_cause = R.Request_Timeout,
       "running application observes Request_Timeout cancellation");
  end late_worker_output_after_timeout;

  procedure bounded_graceful_shutdown
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Blocking_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1024,
       max_output_bytes            => 1024,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    connections   : constant S.Connection_Array (1 .. 1)
                  := [1 => connection'Unchecked_Access];
    runtime_raw   : aliased Interfaces.C.int := -1;
    peer_raw      : aliased Interfaces.C.int := -1;
    runtime_fd    : Clair.IO.Descriptor;
    peer_fd       : Clair.IO.Descriptor;
    native_error  : Interfaces.C.int;
    status        : Clair.Status.Code;
    dispatched    : Boolean;
    loop_ok       : Boolean := True;
    started_seen  : Boolean;
    begin_request : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : M.Body_Status;
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array
      (1 .. 2 * P.HEADER_LENGTH + M.BEGIN_REQUEST_BODY_LENGTH);
    position      : Positive := input'first;
    first_status  : Clair.Status.Code;
    second_status : Clair.Status.Code;
    first_outcome : S.Outcome;
    second_outcome : S.Outcome;
    cancel_seen       : Boolean;
    transport_closed  : Boolean;
    worker_held       : Boolean;
    admission_stopped : Boolean;
    peer_close_status : Clair.Status.Code;
    loop_close_status : Clair.Status.Code;
  begin
    application.finish_after_release := False;
    application.wait_for_cancellation := True;

    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "graceful-shutdown socketpair is created");

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "graceful-shutdown socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "graceful-shutdown loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 128,
       max_output_bytes => 1024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "graceful-shutdown executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 6);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "graceful-shutdown connection initializes");

    M.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written,
       status       => body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       begin_written = M.BEGIN_REQUEST_BODY_LENGTH,
       "graceful-shutdown BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, P.PARAMS_TYPE, empty);
    A.assert_equal_natural
      (reporter, position, input'last + 1,
       "graceful-shutdown request occupies expected bytes");

    status := write_all (peer_fd, input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "graceful-shutdown request is written");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when STC.Current_State(application.started);
    end loop;

    started_seen := STC.Current_State(application.started);

    first_status := S.drain
      (event_loop   => event_loop,
       executor     => executor,
       connections  => connections,
       grace_period => 100,
       result       => first_outcome);

    cancel_seen :=
      STC.Current_State(application.cancellation_observed) and then
      application.observed_cause = R.Runtime_Shutdown;
    transport_closed := not RC.is_active(connection);
    worker_held := E.active_count(executor) = 1;
    admission_stopped := not E.is_accepting(executor);

    -- Release before assertions so a failed check cannot strand the worker.
    STC.Set_True (application.release_gate);

    second_status := S.drain
      (event_loop   => event_loop,
       executor     => executor,
       connections  => connections,
       grace_period => 1_000,
       result       => second_outcome);

    peer_close_status := Clair.IO.close (peer_fd);
    loop_close_status := Clair.Event_Loop.finalize (event_loop);

    A.assert_true
      (reporter, loop_ok and then started_seen,
       "application work is running before graceful shutdown");
    A.assert_true
      (reporter,
       first_status = Clair.Status.OK and then
       first_outcome = S.Grace_Expired,
       "bounded grace expires while application work remains active");
    A.assert_true
      (reporter, cancel_seen,
       "graceful shutdown signals Runtime_Shutdown to running work");
    A.assert_true
      (reporter, transport_closed,
       "grace expiry leaves no active connection transport");
    A.assert_true
      (reporter, worker_held,
       "grace expiry preserves executor lifetime for running work");
    A.assert_true
      (reporter, admission_stopped,
       "graceful shutdown stops new executor admission");
    A.assert_true
      (reporter,
       second_status = Clair.Status.OK and then
       second_outcome = S.Drained,
       "shutdown finalizes after cooperative work returns");
    A.assert_true
      (reporter, peer_close_status = Clair.Status.OK,
       "graceful-shutdown peer closes");
    A.assert_true
      (reporter, loop_close_status = Clair.Status.OK,
       "graceful-shutdown loop finalizes");
  end bounded_graceful_shutdown;

  procedure resource_limit_discard_timeout
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor : aliased E.Context;
    application : aliased Limit_Application;
    diagnostics : aliased Diagnostic_Recorder;
    connection : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 128,
       max_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : M.Body_Status;
    begin_input : P.Byte_Array
      (1 .. P.HEADER_LENGTH + M.BEGIN_REQUEST_BODY_LENGTH);
    position : Positive := begin_input'first;
    limit_header : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "discard-timeout socketpair is created");
    if native_error /= 0 then return; end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "discard-timeout socket prefill is removed");
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "discard-timeout loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 64, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "discard-timeout executor initializes");
    status := RC.initialize
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, handler => application'Unchecked_Access,
       executor => executor'Unchecked_Access, request_timeout => 100,
       connection_id => 97, diagnostics => diagnostics'Unchecked_Access,
       input_limits => (max_params_bytes => 4, max_stdin_bytes => 64,
                        max_data_bytes => 64));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "discard-timeout connection initializes");

    M.encode_begin_request
      (begin_body, begin_bytes, begin_written, body_status);
    append_record
      (begin_input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    status := write_all (peer_fd, begin_input);
    A.assert_true
      (reporter, status = Clair.Status.OK, "discard-timeout BEGIN writes");
    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      exit when status /= Clair.Status.OK or else
        RC.active_request_count(connection) = 1;
    end loop;
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 1,
       "discard-timeout request becomes active");

    C.encode_header
      ((version => P.VERSION_1, record_type => P.PARAMS_TYPE,
        request_id => 1, content_length => 5, padding_length => 0,
        reserved => 0), limit_header);
    status := write_all (peer_fd, limit_header);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "over-limit header writes without body");
    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      exit when status /= Clair.Status.OK or else diagnostics.count = 1;
    end loop;
    A.assert_equal_natural
      (reporter, diagnostics.count, 1,
       "over-limit header is rejected before body allocation");
    A.assert_true
      (reporter,
       RCT.current_cancellation_reason(connection, 1) = R.Resource_Limit,
       "discard-timeout request records resource cancellation");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 1,
       "request stays owned while rejected record body is pending");

    for iteration in 1 .. 30 loop
      pragma Unreferenced (iteration);
      delay 0.01;
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      exit when status /= Clair.Status.OK or else not RC.is_active(connection);
    end loop;
    A.assert_false
      (reporter, RC.is_active(connection),
       "stalled rejected record cannot hold connection beyond request timeout");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "discard-timeout connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "discard-timeout executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "discard-timeout executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "discard-timeout peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "discard-timeout loop finalizes");
  end resource_limit_discard_timeout;

  procedure stalled_output_timeout
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Limit_Application;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 128,
       max_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : M.Body_Status;
    empty : P.Byte_Array (1 .. 0);
    input : P.Byte_Array (1 .. 64);
    position : Positive := input'first;
  begin
    application.finish_on_stdin_end := True;
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "stalled-output socketpair is created");
    if native_error /= 0 then return; end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "stalled-output loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 64, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "stalled-output executor initializes");
    status := RC.initialize
      (connection, loop_context'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 200, 96);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "stalled-output connection initializes");

    M.encode_begin_request
      (begin_body, begin_bytes, begin_written, body_status);
    append_record (input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, P.PARAMS_TYPE, empty);
    append_record (input, position, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK, "stalled-output request writes");

    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      exit when status /= Clair.Status.OK or else
        (application.finish_ok and then
         RC.pending_output_bytes(connection) > 0);
    end loop;
    A.assert_true
      (reporter, application.finish_ok,
       "application completes while peer output remains stalled");
    A.assert_positive
      (reporter, Integer(RC.pending_output_bytes(connection)),
       "completed request retains pending output under stalled peer");
    A.assert_true
      (reporter, RC.is_active(connection),
       "stalled-output transport is active before request deadline");

    for iteration in 1 .. 40 loop
      pragma Unreferenced (iteration);
      delay 0.01;
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      exit when status /= Clair.Status.OK or else not RC.is_active(connection);
    end loop;
    A.assert_false
      (reporter, RC.is_active(connection),
       "request deadline closes a transport with undrained completed output");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "stalled-output connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "stalled-output executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "stalled-output executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "stalled-output peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "stalled-output loop finalizes");
  end stalled_output_timeout;

  procedure stream_input_limits
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Limit_Application;
    diagnostics  : aliased Diagnostic_Recorder;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 1_024,
       max_output_bytes => 1_024, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : M.Body_Status;
    first_three : constant P.Byte_Array :=
      [1, 1, P.Byte(Character'Pos('A'))];
    last_one : constant P.Byte_Array :=
      [1 => P.Byte(Character'Pos('B'))];
    over_one : constant P.Byte_Array := [1 => 0];
    input : P.Byte_Array (1 .. 64);
    position : Positive := input'first;
    drained  : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "limit socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "limit loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 64, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK, "limit executor initializes");
    status := RC.initialize
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, handler => application'Unchecked_Access,
       executor => executor'Unchecked_Access, request_timeout => 60_000,
       connection_id => 93,
       input_limits => (max_params_bytes => 4, max_stdin_bytes => 4,
                        max_data_bytes => 4),
       diagnostics => diagnostics'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK, "limit connection initializes");
    M.encode_begin_request
      (begin_body, begin_bytes, begin_written, body_status);

    append_record (input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, P.PARAMS_TYPE, first_three);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK, "below-limit input writes");
    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      exit when status /= Clair.Status.OK or else
        RC.pending_input_bytes(connection) = 0;
    end loop;
    A.assert_equal_natural
      (reporter, diagnostics.count, 0,
       "input below limit is not rejected");

    position := input'first;
    append_record (input, position, P.PARAMS_TYPE, last_one);
    status := write_all (peer_fd, input(input'first .. position - 1));
    for iteration in 1 .. 40 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      exit when status /= Clair.Status.OK or else
        application.parameter_count = 1;
    end loop;
    A.assert_equal_natural
      (reporter, application.parameter_count, 1,
       "input exactly at limit completes fragmented parameter");
    A.assert_equal_natural
      (reporter, diagnostics.count, 0,
       "input exactly at limit is accepted");

    position := input'first;
    append_record (input, position, P.PARAMS_TYPE, over_one);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK, "above-limit input writes");
    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      exit when status /= Clair.Status.OK or else diagnostics.count = 1;
    end loop;
    A.assert_equal_natural
      (reporter, diagnostics.count, 1,
       "input immediately above limit emits one diagnostic");
    A.assert_true
      (reporter, diagnostics.kind = D.Resource_Error and then
       diagnostics.status = Clair.Status.RANGE_ERROR,
       "input limit diagnostic preserves resource classification");
    A.assert_true
      (reporter,
       RCT.current_cancellation_reason(connection, 1) = R.Resource_Limit,
       "input limit records Resource_Limit cancellation");
    A.assert_true
      (reporter, RC.is_active(connection),
       "resource-limited KEEP_CONN request preserves transport");

    for iteration in 1 .. 40 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      drained := drained + drain_peer (peer_fd);
      exit when status /= Clair.Status.OK or else
        RC.active_request_count(connection) = 0;
    end loop;
    drained := drained + drain_peer (peer_fd);
    A.assert_positive
      (reporter, Integer(drained),
       "resource-limit completion is emitted to the peer");
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "resource-limit drain iterations succeed");
    A.assert_equal_natural
      (reporter, RC.pending_output_bytes(connection), 0,
       "resource-limit completion output fully drains");
    A.assert_equal_natural
      (reporter, E.active_count(executor), 0,
       "resource-limit application work is no longer active");
    A.assert_equal_natural
      (reporter, E.pending_count(executor), 0,
       "resource-limit application queue is empty");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "resource-limited request retires after completion output");
    A.assert_true
      (reporter, RC.is_active(connection),
       "classic KEEP_CONN transport remains reusable after limit");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK, "limit connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "limit executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "limit executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "limit peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "limit loop finalizes");
  end stream_input_limits;

  procedure stdin_input_limits
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Limit_Application;
    diagnostics  : aliased Diagnostic_Recorder;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 1_024,
       max_output_bytes => 1_024, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : M.Body_Status;
    empty : P.Byte_Array (1 .. 0);
    below : constant P.Byte_Array := [1, 2, 3];
    exact : constant P.Byte_Array := [1 => 4];
    above : constant P.Byte_Array := [1 => 5];
    input : P.Byte_Array (1 .. 128);
    position : Positive := input'first;
    drained : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "STDIN limit socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "STDIN limit loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 64, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK, "STDIN limit executor initializes");
    status := RC.initialize
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, handler => application'Unchecked_Access,
       executor => executor'Unchecked_Access, request_timeout => 60_000,
       connection_id => 94, diagnostics => diagnostics'Unchecked_Access,
       input_limits => (max_params_bytes => 64, max_stdin_bytes => 4,
                        max_data_bytes => 64));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "STDIN limit connection initializes");
    M.encode_begin_request
      (begin_body, begin_bytes, begin_written, body_status);

    append_record (input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, P.PARAMS_TYPE, empty);
    append_record (input, position, P.STDIN_TYPE, below);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK, "STDIN below-limit input writes");
    for iteration in 1 .. 80 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      exit when status /= Clair.Status.OK or else application.stdin_bytes = 3;
    end loop;
    A.assert_equal_natural
      (reporter, application.stdin_bytes, 3,
       "STDIN below limit is delivered");
    A.assert_equal_natural
      (reporter, diagnostics.count, 0,
       "STDIN below limit is not rejected");

    position := input'first;
    append_record (input, position, P.STDIN_TYPE, exact);
    status := write_all (peer_fd, input(input'first .. position - 1));
    for iteration in 1 .. 80 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      exit when status /= Clair.Status.OK or else application.stdin_bytes = 4;
    end loop;
    A.assert_equal_natural
      (reporter, application.stdin_bytes, 4,
       "STDIN exactly at limit is delivered");
    A.assert_equal_natural
      (reporter, diagnostics.count, 0,
       "STDIN exactly at limit is accepted");

    position := input'first;
    append_record (input, position, P.STDIN_TYPE, above);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK, "STDIN above-limit input writes");
    for iteration in 1 .. 80 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      drained := drained + drain_peer (peer_fd);
      exit when status /= Clair.Status.OK or else diagnostics.count = 1;
    end loop;
    A.assert_equal_natural
      (reporter, diagnostics.count, 1,
       "STDIN immediately above limit is rejected");
    A.assert_true
      (reporter,
       RCT.current_cancellation_reason(connection, 1) = R.Resource_Limit,
       "STDIN limit records Resource_Limit cancellation");

    for iteration in 1 .. 80 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      drained := drained + drain_peer (peer_fd);
      exit when status /= Clair.Status.OK or else
        RC.active_request_count(connection) = 0;
    end loop;
    drained := drained + drain_peer (peer_fd);
    A.assert_positive
      (reporter, Integer(drained), "STDIN limit completion reaches peer");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "STDIN-limited request retires");
    A.assert_true
      (reporter, RC.is_active(connection),
       "STDIN limit preserves KEEP_CONN transport");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK, "STDIN limit connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "STDIN limit executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "STDIN limit executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "STDIN limit peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "STDIN limit loop finalizes");
  end stdin_input_limits;

  procedure data_input_limits
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Limit_Application;
    diagnostics  : aliased Diagnostic_Recorder;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 1_024,
       max_output_bytes => 1_024, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.FILTER_ROLE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : M.Body_Status;
    params : P.Byte_Array (1 .. 64);
    params_position : Positive := params'first;
    empty : P.Byte_Array (1 .. 0);
    below : constant P.Byte_Array := [1, 2, 3];
    exact : constant P.Byte_Array := [1 => 4];
    above : constant P.Byte_Array := [1 => 5];
    input : P.Byte_Array (1 .. 256);
    position : Positive := input'first;
    drained : Natural := 0;
  begin
    append_pair (params, params_position, "FCGI_DATA_LENGTH", "100");
    append_pair (params, params_position, "FCGI_DATA_LAST_MOD", "0");
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "DATA limit socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA limit loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 64, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA limit executor initializes");
    status := RC.initialize
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, handler => application'Unchecked_Access,
       executor => executor'Unchecked_Access, request_timeout => 60_000,
       connection_id => 95, diagnostics => diagnostics'Unchecked_Access,
       input_limits => (max_params_bytes => 64, max_stdin_bytes => 64,
                        max_data_bytes => 4));
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA limit connection initializes");
    M.encode_begin_request
      (begin_body, begin_bytes, begin_written, body_status);

    append_record (input, position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record
      (input, position, P.PARAMS_TYPE,
       params(params'first .. params_position - 1));
    append_record (input, position, P.PARAMS_TYPE, empty);
    append_record (input, position, P.STDIN_TYPE, empty);
    append_record (input, position, P.DATA_TYPE, below);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA below-limit input writes");
    for iteration in 1 .. 120 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      drained := drained + drain_peer (peer_fd);
      exit when status /= Clair.Status.OK or else application.data_bytes = 3;
    end loop;
    A.assert_equal_natural
      (reporter, application.data_bytes, 3,
       "DATA below limit is delivered");
    A.assert_equal_natural
      (reporter, diagnostics.count, 0,
       "DATA below limit is not rejected");

    position := input'first;
    append_record (input, position, P.DATA_TYPE, exact);
    status := write_all (peer_fd, input(input'first .. position - 1));
    for iteration in 1 .. 80 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      drained := drained + drain_peer (peer_fd);
      exit when status /= Clair.Status.OK or else application.data_bytes = 4;
    end loop;
    A.assert_equal_natural
      (reporter, application.data_bytes, 4,
       "DATA exactly at limit is delivered");
    A.assert_equal_natural
      (reporter, diagnostics.count, 0,
       "DATA exactly at limit is accepted");

    position := input'first;
    append_record (input, position, P.DATA_TYPE, above);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA above-limit input writes");
    for iteration in 1 .. 80 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      drained := drained + drain_peer (peer_fd);
      exit when status /= Clair.Status.OK or else diagnostics.count = 1;
    end loop;
    A.assert_equal_natural
      (reporter, diagnostics.count, 1,
       "DATA immediately above limit is rejected");
    A.assert_true
      (reporter,
       RCT.current_cancellation_reason(connection, 1) = R.Resource_Limit,
       "DATA limit records Resource_Limit cancellation");

    for iteration in 1 .. 80 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      drained := drained + drain_peer (peer_fd);
      exit when status /= Clair.Status.OK or else
        RC.active_request_count(connection) = 0;
    end loop;
    drained := drained + drain_peer (peer_fd);
    A.assert_positive
      (reporter, Integer(drained), "DATA limit completion reaches peer");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "DATA-limited request retires");
    A.assert_true
      (reporter, RC.is_active(connection),
       "DATA limit preserves KEEP_CONN transport");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA limit connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA limit executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA limit executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA limit peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA limit loop finalizes");
  end data_input_limits;

  procedure truncated_connection_input
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Test_Application;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1_024,
       max_output_bytes            => 1_024,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    runtime_fd   : Clair.IO.Descriptor;
    peer_fd      : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    partial : constant P.Byte_Array :=
      [P.VERSION_1, P.BEGIN_REQUEST_TYPE, 0, 1];
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "truncated socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "truncated loop initializes");
    status := E.initialize
      (self => executor, event_loop => loop_context'Unchecked_Access,
       worker_count => 1, pending_capacity => 1, max_input_bytes => 64,
       max_output_bytes => 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK, "truncated executor initializes");
    status := RC.initialize
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, handler => application'Unchecked_Access,
       executor => executor'Unchecked_Access, request_timeout => 60_000,
       connection_id => 92);
    A.assert_true
      (reporter, status = Clair.Status.OK, "truncated connection initializes");

    status := write_all (peer_fd, partial);
    A.assert_true
      (reporter, status = Clair.Status.OK, "partial header is written");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "peer closes mid-header");

    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      exit when status /= Clair.Status.OK or else not RC.is_active(connection);
    end loop;
    A.assert_true
      (reporter, status = Clair.Status.OK, "truncated EOF dispatch succeeds");
    A.assert_false
      (reporter, RC.is_active(connection),
       "truncated connection input is connection-fatal");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK, "truncated connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "truncated executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "truncated executor finalizes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "truncated loop finalizes");
  end truncated_connection_input;

  procedure protocol_diagnostic
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Test_Application;
    diagnostics  : aliased Diagnostic_Recorder;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 4_096,
       max_output_bytes            => 4_096,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    runtime_fd   : Clair.IO.Descriptor;
    peer_fd      : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    malformed    : constant P.Byte_Array (1 .. P.HEADER_LENGTH) :=
      [2, P.BEGIN_REQUEST_TYPE, 0, 1, 0, 0, 0, 0];
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "diagnostic socketpair is created");
    if native_error /= 0 then
      return;
    end if;

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "diagnostic event loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => loop_context'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 64,
       max_output_bytes => 4_096);
    A.assert_true
      (reporter, status = Clair.Status.OK, "diagnostic executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => loop_context'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 91,
       diagnostics     => diagnostics'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK, "diagnostic connection initializes");

    status := write_all (peer_fd, malformed);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "malformed FastCGI header is written");

    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      exit when status /= Clair.Status.OK or else not RC.is_active(connection);
    end loop;

    A.assert_true
      (reporter, status = Clair.Status.OK,
       "protocol rejection dispatch succeeds");
    A.assert_false
      (reporter, RC.is_active(connection),
       "protocol error closes the connection");
    A.assert_equal_natural
      (reporter, diagnostics.count, 1, "protocol error emits one diagnostic");
    A.assert_true
      (reporter,
       diagnostics.kind = D.Protocol_Error and then
       diagnostics.status = Clair.Status.INVALID_ARGUMENT,
       "protocol diagnostic preserves category and status");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK, "diagnostic connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "diagnostic executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "diagnostic executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "diagnostic peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "diagnostic event loop finalizes");
  end protocol_diagnostic;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter, "listener lifecycle", listener_lifecycle'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "resource-limit discard timeout",
       resource_limit_discard_timeout'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "stalled output timeout", stalled_output_timeout'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "stream input limits", stream_input_limits'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "STDIN input limits", stdin_input_limits'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "DATA input limits", data_input_limits'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "truncated connection input",
       truncated_connection_input'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "protocol diagnostic", protocol_diagnostic'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "bounded connection backpressure",
       bounded_connection_backpressure'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "application callback failure",
       application_callback_failure'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "request timeout cancellation",
       request_timeout_cancellation'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "runtime shutdown cancellation",
       runtime_shutdown_cancellation'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "peer abort while execution pending",
       peer_abort_while_execution_pending'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "late worker output after timeout",
       late_worker_output_after_timeout'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "bounded graceful shutdown",
       bounded_graceful_shutdown'access);
  end run;

end Tests.Runtime;
