-- ============================================================================
-- tests-runtime.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Synchronous_Task_Control;
with Interfaces.C;
with System;
with System.Storage_Elements;
with Clair.Event_Loop;
with Clair.IO;
with Clair.IO.Posix;
with Clair.Status;
with Clair.Test.Assertions;
with Fasyn.Listener;
with Fasyn.Listener.Testing;
with Fasyn.Admission;
with Fasyn.Diagnostics;
with Fasyn.Protocol;
with Fasyn.Protocol.Codec;
with Fasyn.Protocol.Bodies;
with Fasyn.Protocol.Name_Values;
with Fasyn.Request;
with Fasyn.Request.Connection;
with Fasyn.Request.Connection.Testing;
with Fasyn.Request.Execution;
with Fasyn.Request.Execution.Testing;
with Fasyn.Request.Execution.Internal;
with Fasyn.Shutdown;

package body Tests.Runtime is

  package STC renames Ada.Synchronous_Task_Control;
  package A renames Clair.Test.Assertions;
  package AD renames Fasyn.Admission;
  package LT renames Fasyn.Listener.Testing;
  package D renames Fasyn.Diagnostics;
  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package B renames Fasyn.Protocol.Bodies;
  package N renames Fasyn.Protocol.Name_Values;
  package R renames Fasyn.Request;
  package RC renames Fasyn.Request.Connection;
  package RCT renames Fasyn.Request.Connection.Testing;
  package E renames Fasyn.Request.Execution;
  package ET renames Fasyn.Request.Execution.Testing;
  package EI renames Fasyn.Request.Execution.Internal;
  package S renames Fasyn.Shutdown;

  use type Interfaces.C.int;
  use type Interfaces.Unsigned_32;
  use type Clair.IO.Byte_Count;
  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type C.Decode_Status;
  use type D.Category;
  use type B.Body_Status;
  use type N.Encode_Status;
  use type R.Cancellation_Cause;
  use type R.Connection_Identity;
  use type R.Generation;
  use type R.Write_Status;
  use type RC.Initialization_Outcome;
  use type S.Outcome;

  function c_socketpair
    (runtime_fd : access Interfaces.C.int;
     peer_fd    : access Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_socketpair";

  function noop_watch_callback
    (source  : access constant Clair.Event_Loop.Source_Handle;
     fd      : Clair.IO.Descriptor;
     events  : Clair.Event_Loop.Event_Mask;
     context : System.Address) return Clair.Status.Code
  with Convention => C;

  function noop_watch_callback
    (source  : access constant Clair.Event_Loop.Source_Handle;
     fd      : Clair.IO.Descriptor;
     events  : Clair.Event_Loop.Event_Mask;
     context : System.Address) return Clair.Status.Code
  is
    pragma Unreferenced (source, fd, events, context);
  begin
    return Clair.Status.OK;
  end noop_watch_callback;

  function c_listener_pair
    (listener_fd : access Interfaces.C.int;
     client_fd   : access Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_listener_pair";

  type C_Int_Array is array (Positive range <>) of aliased Interfaces.C.int
  with convention => c;

  function c_listener_storm
    (listener_fd : access Interfaces.C.int;
     client_fds  : access Interfaces.C.int;
     count       : Interfaces.C.size_t) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_listener_storm";

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

  type Raising_Accept_Handler is new Fasyn.Listener.Accept_Handler with record
    count       : Natural := 0;
    accepted_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  end record;

  overriding function on_accept
    (handler : in out Raising_Accept_Handler;
     fd      : Clair.IO.Descriptor) return Clair.Status.Code;

  overriding function on_accept
    (handler : in out Raising_Accept_Handler;
     fd      : Clair.IO.Descriptor) return Clair.Status.Code
  is
  begin
    handler.count := handler.count + 1;
    handler.accepted_fd := fd;
    if handler.count > 0 then
      raise Program_Error with "test accept callback failure";
    end if;
    return Clair.Status.OK;
  end on_accept;

  type Rejecting_Accept_Handler is new Fasyn.Listener.Accept_Handler with record
    count       : Natural := 0;
    accepted_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  end record;

  overriding function on_accept
    (handler : in out Rejecting_Accept_Handler;
     fd      : Clair.IO.Descriptor) return Clair.Status.Code;

  overriding function on_accept
    (handler : in out Rejecting_Accept_Handler;
     fd      : Clair.IO.Descriptor) return Clair.Status.Code
  is
  begin
    handler.count := handler.count + 1;
    handler.accepted_fd := fd;
    return Clair.Status.INVALID_ARGUMENT;
  end on_accept;

  type Diagnostic_Recorder is new D.Reporter with record
    count           : Natural := 0;
    kind            : D.Category := D.Protocol_Error;
    status          : Clair.Status.Code := Clair.Status.OK;
    raise_on_report : Boolean := False;
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
    if self.raise_on_report then
      raise Program_Error with "test diagnostic reporter failure";
    end if;
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
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Test_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Test_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Test_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Test_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (context, name, value);
  begin
    self.parameter_count := self.parameter_count + 1;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Test_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    data   : constant P.Byte_Array (1 .. 60_000) := [others => 16#58#];
    status : R.Write_Status;
  begin
    self.params_end_seen := True;
    status := R.write_stdout (response, data);
    self.large_write_ok := status = R.Write_Complete;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Test_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, data, response);
  begin
    null;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Test_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    status : R.Write_Status;
  begin
    self.stdin_end_seen := True;
    status := R.finish (response, 0);
    self.finish_ok := status = R.Write_Complete;
  end on_stdin_end;

  type Fairness_Application is new Test_Application with null record;

  overriding procedure on_params_end
    (self     : in out Fairness_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    data   : constant P.Byte_Array (1 .. 16_384) := [others => 16#59#];
    status : R.Write_Status := R.Write_Complete;
  begin
    self.params_end_seen := True;
    for chunk in 1 .. 13 loop
      pragma Unreferenced (chunk);
      status := R.write_stdout (response, data);
      exit when status /= R.Write_Complete;
    end loop;
    self.large_write_ok := status = R.Write_Complete;
  end on_params_end;

  type Limit_Application is new R.Application with record
    parameter_count      : Natural := 0;
    stdin_bytes          : Natural := 0;
    data_bytes           : Natural := 0;
    finish_on_stdin_end  : Boolean := False;
    finish_ok            : Boolean := False;
  end record;

  overriding procedure on_parameter
    (self : in out Limit_Application; context : in R.Context;
     name : in P.Byte_Array; value : in P.Byte_Array);
  overriding procedure on_params_end
    (self : in out Limit_Application; context : in R.Context;
     response : in out R.Writer);
  overriding procedure on_stdin
    (self : in out Limit_Application; context : in R.Context;
     data : in P.Byte_Array; response : in out R.Writer);
  overriding procedure on_stdin_end
    (self : in out Limit_Application; context : in R.Context;
     response : in out R.Writer);
  overriding procedure on_data
    (self : in out Limit_Application; context : in R.Context;
     data : in P.Byte_Array; response : in out R.Writer);

  overriding procedure on_parameter
    (self : in out Limit_Application; context : in R.Context;
     name : in P.Byte_Array; value : in P.Byte_Array)
  is
    pragma Unreferenced (context, name, value);
  begin
    self.parameter_count := self.parameter_count + 1;
  end on_parameter;

  overriding procedure on_params_end
    (self : in out Limit_Application; context : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin null; end on_params_end;

  overriding procedure on_stdin
    (self : in out Limit_Application; context : in R.Context;
     data : in P.Byte_Array; response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.stdin_bytes := self.stdin_bytes + data'length;
  end on_stdin;

  overriding procedure on_stdin_end
    (self : in out Limit_Application; context : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    status : R.Write_Status;
  begin
    if self.finish_on_stdin_end then
      status := R.finish (response, 0);
      self.finish_ok := status = R.Write_Complete;
    end if;
  end on_stdin_end;

  overriding procedure on_data
    (self : in out Limit_Application; context : in R.Context;
     data : in P.Byte_Array; response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.data_bytes := self.data_bytes + data'length;
  end on_data;

  type Runtime_Failure_Application is new Limit_Application with null record;

  overriding procedure on_stdin_end
    (self     : in out Runtime_Failure_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Runtime_Failure_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context);
    data   : constant P.Byte_Array := [1 => 16#58#];
    status : R.Write_Status;
  begin
    status := R.write_stdout (response, data);
    if status /= R.Write_Complete then
      raise Program_Error with "runtime failure fixture write failed";
    end if;
    raise Program_Error with "runtime callback failure fixture";
  end on_stdin_end;

  TINY_BATCH_ITEM_COUNT : constant Positive := 64;

  type Tiny_Batch_Application is limited new R.Application with record
    first_started : STC.Suspension_Object;
    release_gate  : STC.Suspension_Object;
    all_seen      : STC.Suspension_Object;
    stdin_started : STC.Suspension_Object;
    stdin_release : STC.Suspension_Object;
    stdin_end_seen : STC.Suspension_Object;
    parameter_count      : Natural := 0;
    stdin_callback_count : Natural := 0;
    stdin_bytes          : Natural := 0;
    finish_ok            : Boolean := False;
  end record;

  overriding procedure on_parameter
    (self    : in out Tiny_Batch_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Tiny_Batch_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Tiny_Batch_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Tiny_Batch_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Tiny_Batch_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (context, name, value);
  begin
    self.parameter_count := self.parameter_count + 1;
    if self.parameter_count = 1 then
      STC.Set_True (self.first_started);
      STC.Suspend_Until_True (self.release_gate);
    end if;

    if self.parameter_count = TINY_BATCH_ITEM_COUNT then
      STC.Set_True (self.all_seen);
    end if;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Tiny_Batch_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin
    null;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Tiny_Batch_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.stdin_callback_count := self.stdin_callback_count + 1;
    self.stdin_bytes := self.stdin_bytes + data'length;
    if self.stdin_callback_count = 1 then
      STC.Set_True (self.stdin_started);
      STC.Suspend_Until_True (self.stdin_release);
    end if;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Tiny_Batch_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    write_status : R.Write_Status;
  begin
    STC.Set_True (self.stdin_end_seen);
    write_status := R.finish (response, 0);
    self.finish_ok := write_status = R.Write_Complete;
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
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Blocking_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Blocking_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Blocking_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Blocking_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (self, context, name, value);
  begin
    null;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Blocking_Application;
     context  : in R.Context;
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

    write_status := R.write_stdout (response, data);
    if write_status = R.Write_Complete and then self.finish_after_release then
      finish_status := R.finish (response, 0);
      if finish_status /= R.Write_Complete then
        raise Program_Error with "blocking application finish failed";
      end if;
    end if;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Blocking_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, data, response);
  begin
    null;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Blocking_Application;
     context  : in R.Context;
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
    status := N.encode_pair
      (name_bytes, value_bytes, encoded, written);
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
       content_length => P.Content_Length(content'length),
       padding_length => 0);
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
        (fd            => fd,
         buffer        => data(position)'address,
         count         => Clair.IO.Byte_Count(data'last - position + 1),
         bytes_written => written);

      if status /= Clair.Status.OK then
        return status;
      end if;

      if written = 0 then
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

  procedure listener_callback_exception_is_contained
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    listener     : aliased Fasyn.Listener.Context;
    recorder     : aliased Raising_Accept_Handler;
    listener_raw : aliased Interfaces.C.int := -1;
    client_raw   : aliased Interfaces.C.int := -1;
    listener_fd  : Clair.IO.Descriptor;
    client_fd    : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    close_status : Clair.Status.Code;
    dispatched   : Boolean;
  begin
    native_error := c_listener_pair (listener_raw'access, client_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "raising-listener fixture is created");
    if native_error /= 0 then
      return;
    end if;

    listener_fd := Clair.IO.Descriptor(listener_raw);
    client_fd := Clair.IO.Descriptor(client_raw);
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "raising-listener event loop initializes");
    status := Fasyn.Listener.initialize
      (self       => listener,
       event_loop => loop_context'Unchecked_Access,
       fd         => listener_fd,
       handler    => recorder'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "raising-listener initializes");

    status := Clair.Event_Loop.iterate (loop_context, 100, dispatched);
    A.assert_true
      (reporter, status = Clair.Status.CALLBACK_FAILED,
       "accept callback exception is contained as CALLBACK_FAILED");
    A.assert_true
      (reporter, dispatched,
       "raising accept callback is reported as dispatched");
    A.assert_equal_natural
      (reporter, recorder.count, 1,
       "raising accept handler runs exactly once");
    A.assert_true
      (reporter, recorder.accepted_fd /= Clair.IO.INVALID_DESCRIPTOR,
       "raising accept handler observes the accepted descriptor");

    close_status := Clair.IO.close (recorder.accepted_fd);
    A.assert_true
      (reporter, close_status /= Clair.Status.OK,
       "listener reclaims accepted descriptor after callback exception");
    A.assert_true
      (reporter, Fasyn.Listener.is_active(listener),
       "callback failure does not destroy listener ownership state");

    status := Fasyn.Listener.finalize (listener);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "raising-listener finalizes after callback failure");
    status := Clair.IO.close (client_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "raising-listener client closes");
    status := Clair.IO.close (listener_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "raising-listener descriptor remains caller-owned");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "raising-listener event loop finalizes");
  end listener_callback_exception_is_contained;

  procedure listener_callback_rejection_reclaims_descriptor
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    listener     : aliased Fasyn.Listener.Context;
    recorder     : aliased Rejecting_Accept_Handler;
    listener_raw : aliased Interfaces.C.int := -1;
    client_raw   : aliased Interfaces.C.int := -1;
    listener_fd  : Clair.IO.Descriptor;
    client_fd    : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    close_status : Clair.Status.Code;
  begin
    native_error := c_listener_pair (listener_raw'access, client_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "rejecting-listener fixture is created");
    if native_error /= 0 then
      return;
    end if;

    listener_fd := Clair.IO.Descriptor(listener_raw);
    client_fd := Clair.IO.Descriptor(client_raw);
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "rejecting-listener event loop initializes");
    status := Fasyn.Listener.initialize
      (listener, loop_context'Unchecked_Access, listener_fd,
       recorder'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "rejecting-listener initializes");

    status := LT.dispatch_io
      (listener, listener_fd, Clair.Event_Loop.EVENT_INPUT);
    A.assert_true
      (reporter, status = Clair.Status.INVALID_ARGUMENT,
       "non-OK accept callback status propagates after descriptor cleanup");
    A.assert_equal_natural
      (reporter, recorder.count, 1,
       "rejecting accept callback runs exactly once");
    close_status := Clair.IO.close (recorder.accepted_fd);
    A.assert_true
      (reporter, close_status /= Clair.Status.OK,
       "listener reclaims descriptor after non-OK callback return");
    A.assert_true
      (reporter, Fasyn.Listener.is_active(listener),
       "callback rejection preserves listener ownership state");

    status := Fasyn.Listener.finalize (listener);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "rejecting-listener finalizes");
    status := Clair.IO.close (client_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "rejecting-listener client closes");
    status := Clair.IO.close (listener_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "rejecting-listener descriptor remains caller-owned");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "rejecting-listener event loop finalizes");
  end listener_callback_rejection_reclaims_descriptor;

  procedure listener_accept_storm_is_bounded
    (reporter : in out Clair.Test.Reporter.Context)
  is
    client_count : constant Positive := LT.accept_budget + 1;
    loop_context : aliased Clair.Event_Loop.Context;
    listener     : aliased Fasyn.Listener.Context;
    recorder     : aliased Accept_Recorder;
    listener_raw : aliased Interfaces.C.int := -1;
    clients_raw  : C_Int_Array (1 .. client_count) := [others => -1];
    listener_fd  : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
  begin
    native_error := c_listener_storm
      (listener_raw'access, clients_raw(clients_raw'first)'access,
       Interfaces.C.size_t(client_count));
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "listener accept-storm fixture is created");
    if native_error /= 0 then
      return;
    end if;

    listener_fd := Clair.IO.Descriptor(listener_raw);
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "accept-storm event loop initializes");
    status := Fasyn.Listener.initialize
      (listener, loop_context'Unchecked_Access, listener_fd,
       recorder'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "accept-storm listener initializes");

    status := LT.dispatch_io
      (listener, listener_fd, Clair.Event_Loop.EVENT_INPUT);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "first accept-storm dispatch succeeds");
    A.assert_equal_natural
      (reporter, recorder.count, LT.accept_budget,
       "one listener callback accepts only its fixed storm budget");

    status := LT.dispatch_io
      (listener, listener_fd, Clair.Event_Loop.EVENT_INPUT);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "second accept-storm dispatch succeeds");
    A.assert_equal_natural
      (reporter, recorder.count, client_count,
       "remaining queued connection progresses on the next dispatch");

    status := LT.dispatch_io
      (listener, listener_fd, Clair.Event_Loop.EVENT_INPUT);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "empty accept-storm dispatch stops at would-block");
    A.assert_equal_natural
      (reporter, recorder.count, client_count,
       "would-block dispatch creates no extra accepted descriptors");

    status := Fasyn.Listener.finalize (listener);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "accept-storm listener finalizes");
    for index in clients_raw'range loop
      status := Clair.IO.close (Clair.IO.Descriptor(clients_raw(index)));
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "accept-storm client descriptor closes");
    end loop;
    status := Clair.IO.close (listener_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "accept-storm listener descriptor remains caller-owned");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "accept-storm event loop finalizes");
  end listener_accept_storm_is_bounded;

  procedure admitted_initialization_failure_releases_capacity
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Test_Application;
    admission    : aliased AD.Context
      (max_connections => 1, max_requests => 1);
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 128,
       max_connection_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    outcome      : RC.Initialization_Outcome;
    identity     : R.Connection_Identity;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "admitted-failure socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "admitted-failure socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "admitted-failure event loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "admitted-failure executor initializes");
    ET.seed_next_connection_identity
      (executor, R.Connection_Identity'Last);
    status := EI.issue_connection_identity (executor, identity);
    A.assert_true
      (reporter, status = Clair.Status.OK and then
       identity = R.Connection_Identity'Last,
       "admitted-failure fixture consumes the final connection identity");

    status := RC.initialize
      (connection, loop_context'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000,
       admission => admission'Unchecked_Access, outcome => outcome);
    A.assert_true
      (reporter, status = Clair.Status.RANGE_ERROR and then
       outcome = RC.Failed_Releasable,
       "post-admission identity failure is immediately releasable");
    A.assert_equal_natural
      (reporter, AD.active_connections(admission), 0,
       "failed initialization releases its acquired connection admission");
    A.assert_false
      (reporter, RC.is_active(connection),
       "failed admitted initialization leaves connection uninitialized");
    status := Clair.IO.close (runtime_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "failed initialization leaves descriptor caller-owned");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "admitted-failure executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "admitted-failure executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "admitted-failure peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "admitted-failure event loop finalizes");
  end admitted_initialization_failure_releases_capacity;

  procedure watch_initialization_failure_rolls_back_timer
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Test_Application;
    admission    : aliased AD.Context
      (max_connections => 1, max_requests => 1);
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 128,
       max_connection_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw   : aliased Interfaces.C.int := -1;
    peer_raw      : aliased Interfaces.C.int := -1;
    runtime_fd    : Clair.IO.Descriptor;
    peer_fd       : Clair.IO.Descriptor;
    blocker_watch : Clair.Event_Loop.Source_Handle :=
                      Clair.Event_Loop.NULL_SOURCE;
    native_error  : Interfaces.C.int;
    status        : Clair.Status.Code;
    outcome       : RC.Initialization_Outcome;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "watch-failure socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "watch-failure socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "watch-failure event loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "watch-failure executor initializes");
    status := Clair.Event_Loop.add_watch
      (self             => loop_context,
       fd               => runtime_fd,
       events           => Clair.Event_Loop.EVENT_INPUT,
       callback         => noop_watch_callback'Access,
       callback_context => System.Null_Address,
       source           => blocker_watch);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "watch-failure fixture occupies descriptor watch");

    status := RC.initialize
      (connection, loop_context'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000,
       admission => admission'Unchecked_Access, outcome => outcome);
    A.assert_true
      (reporter, status /= Clair.Status.OK and then
       outcome = RC.Failed_Releasable,
       "ordinary watch registration failure is immediately releasable");
    A.assert_equal_natural
      (reporter, AD.active_connections(admission), 0,
       "watch failure releases acquired connection admission");
    A.assert_false
      (reporter, RC.is_active(connection),
       "watch failure leaves connection inactive");
    A.assert_false
      (reporter, RCT.idle_timer_active(connection),
       "watch failure rolls back the prepared idle timer");
    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "watch-failed connection finalizes cleanly");
    status := Clair.Event_Loop.remove (loop_context, blocker_watch);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "watch-failure fixture releases descriptor watch");
    status := Clair.IO.close (runtime_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "watch failure leaves descriptor caller-owned");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "watch-failure executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "watch-failure executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "watch-failure peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "watch-failure event loop finalizes");
  end watch_initialization_failure_rolls_back_timer;

  procedure connection_requires_finalize_before_reinitialize
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Test_Application;
    admission    : aliased AD.Context
      (max_connections => 1, max_requests => 1);
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 128,
       max_connection_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    first_runtime_raw  : aliased Interfaces.C.int := -1;
    first_peer_raw     : aliased Interfaces.C.int := -1;
    second_runtime_raw : aliased Interfaces.C.int := -1;
    second_peer_raw    : aliased Interfaces.C.int := -1;
    first_runtime_fd   : Clair.IO.Descriptor;
    first_peer_fd      : Clair.IO.Descriptor;
    second_runtime_fd  : Clair.IO.Descriptor;
    second_peer_fd     : Clair.IO.Descriptor;
    native_error       : Interfaces.C.int;
    status             : Clair.Status.Code;
    outcome            : RC.Initialization_Outcome;
    dispatched         : Boolean;
  begin
    native_error := c_socketpair
      (first_runtime_raw'access, first_peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "lifecycle first socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    first_runtime_fd := Clair.IO.Descriptor(first_runtime_raw);
    first_peer_fd := Clair.IO.Descriptor(first_peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(first_peer_fd)),
       "lifecycle first socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "lifecycle event loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "lifecycle executor initializes");

    status := RC.initialize
      (connection, loop_context'Unchecked_Access, first_runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000,
       admission => admission'Unchecked_Access, outcome => outcome);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then outcome = RC.Activated,
       "lifecycle first connection activates");

    status := Clair.IO.close (first_peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "lifecycle first peer closes");
    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      exit when status /= Clair.Status.OK or else not RC.is_active(connection);
    end loop;
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then not RC.is_active(connection) and then
       RCT.finalization_required(connection),
       "closed connection requires finalization before reuse");

    native_error := c_socketpair
      (second_runtime_raw'access, second_peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "lifecycle second socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    second_runtime_fd := Clair.IO.Descriptor(second_runtime_raw);
    second_peer_fd := Clair.IO.Descriptor(second_peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(second_peer_fd)),
       "lifecycle second socket fixture prefill is discarded");

    status := RC.initialize
      (connection, loop_context'Unchecked_Access, second_runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000,
       admission => admission'Unchecked_Access, outcome => outcome);
    A.assert_true
      (reporter,
       status = Clair.Status.INVALID_STATE and then
       outcome = RC.Failed_Releasable and then
       RCT.finalization_required(connection),
       "reinitialization is rejected until finalize succeeds");

    status := RC.finalize (connection);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then
       not RCT.finalization_required(connection),
       "finalize makes the connection context reusable");

    status := RC.initialize
      (connection, loop_context'Unchecked_Access, second_runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000,
       admission => admission'Unchecked_Access, outcome => outcome);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then outcome = RC.Activated,
       "finalized connection context reactivates");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reactivated connection finalizes");
    status := Clair.IO.close (second_peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "lifecycle second peer closes");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "lifecycle executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "lifecycle executor finalizes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "lifecycle event loop finalizes");
  end connection_requires_finalize_before_reinitialize;

  procedure repeated_connection_lifecycle_reuse
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Test_Application;
    admission    : aliased AD.Context
      (max_connections => 1, max_requests => 1);
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 128,
       max_connection_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    runtime_fd   : Clair.IO.Descriptor;
    peer_fd      : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    outcome      : RC.Initialization_Outcome;
    CYCLES       : constant Positive := 64;
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reuse event loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reuse executor initializes");

    for cycle in 1 .. CYCLES loop
      runtime_raw := -1;
      peer_raw := -1;
      native_error := c_socketpair (runtime_raw'access, peer_raw'access);
      A.assert_equal_integer
        (reporter, Integer(native_error), 0,
         "reuse socketpair is created");
      exit when native_error /= 0;

      runtime_fd := Clair.IO.Descriptor(runtime_raw);
      peer_fd := Clair.IO.Descriptor(peer_raw);
      A.assert_positive
        (reporter, Integer(drain_peer(peer_fd)),
         "reuse socket fixture prefill is discarded");

      status := RC.initialize
        (connection, loop_context'Unchecked_Access, runtime_fd,
         application'Unchecked_Access, executor'Unchecked_Access, 60_000,
         admission => admission'Unchecked_Access, outcome => outcome);
      A.assert_true
        (reporter,
         status = Clair.Status.OK and then outcome = RC.Activated and then
         RC.is_active(connection) and then
         AD.active_connections(admission) = 1,
         "reuse cycle activates one bounded connection");

      status := RC.finalize (connection);
      A.assert_true
        (reporter,
         status = Clair.Status.OK and then
         not RC.is_active(connection) and then
         not RCT.finalization_required(connection) and then
         not RCT.idle_timer_active(connection) and then
         AD.active_connections(admission) = 0 and then
         AD.active_requests(admission) = 0,
         "reuse cycle returns lifecycle and admission to baseline");

      status := Clair.IO.close (peer_fd);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "reuse peer closes");

      pragma Unreferenced (cycle);
    end loop;

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reuse executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reuse executor finalizes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reuse event loop finalizes");
  end repeated_connection_lifecycle_reuse;

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
       max_connection_output_bytes => 65_536,
       read_buffer_bytes => 5,
       write_chunk_bytes => 4_096);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE,
       flags     => 0);
    begin_bytes : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
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

    status := RCT.initialize_without_shared_admission
      (self            => connection,
       event_loop      => loop_context'Unchecked_Access,
       fd              => runtime_fd,
       application => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "connection watch initializes");

    for iteration in 1 .. 16 loop
      pragma Unreferenced (iteration);
      status := RCT.dispatch_io
        (connection, Clair.Event_Loop.NULL_SOURCE, runtime_fd,
         Clair.Event_Loop.EVENT_INPUT);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "spurious readable dispatch returns without failure");
      A.assert_equal_natural
        (reporter, RCT.input_dispatch_bytes(connection), 0,
         "spurious readable dispatch consumes no input bytes");
    end loop;

    body_status := B.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    append_record (input, position, P.PARAMS, empty);
    append_record (input, position, P.STDIN, empty);
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
      (reporter, RCT.output_accounting_consistent(connection),
       "bounded backpressure aggregate matches full slot scan");
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

    for iteration in 1 .. 16 loop
      pragma Unreferenced (iteration);
      status := RCT.dispatch_io
        (connection, Clair.Event_Loop.NULL_SOURCE, runtime_fd,
         Clair.Event_Loop.EVENT_OUTPUT);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "spurious writable dispatch returns without failure");
      A.assert_equal_natural
        (reporter, RCT.output_dispatch_bytes(connection), 0,
         "stalled writable dispatch sends no bytes");
      A.assert_equal_natural
        (reporter, RC.pending_output_bytes(connection), stalled_pending,
         "spurious writable dispatch does not grow or consume queued output");
    end loop;

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
    A.assert_false
      (reporter, RC.is_active(connection),
       "finalized connection remains inactive");
    A.assert_false
      (reporter, RC.is_read_paused(connection),
       "finalized connection is not read-paused");
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 0,
       "finalized connection has no active requests");
    A.assert_equal_natural
      (reporter, RC.pending_input_bytes(connection), 0,
       "finalized connection has no pending input");
    A.assert_equal_natural
      (reporter, RC.pending_output_bytes(connection), 0,
       "finalized connection has no pending output");
    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "connection finalize is idempotent after successful cleanup");

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
       max_connection_output_bytes => 1024,
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
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array
      (1 .. 3 * P.HEADER_LENGTH + B.BEGIN_REQUEST_BODY_LENGTH);
    input_position : Positive := input'first;
    output         : P.Byte_Array (1 .. 64);
    output_length  : Natural := 0;
    header_bytes   : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    record_header  : P.Header;
    decode_status  : C.Decode_Status;
    end_bytes      : P.Byte_Array (0 .. B.END_REQUEST_BODY_LENGTH - 1);
    end_body       : B.End_Request_Body;
    end_status     : B.Body_Status;
    output_position : Positive := output'first;
    expected_length : constant Natural :=
      3 * P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH;

    procedure decode_next_header is
    begin
      for index in header_bytes'range loop
        header_bytes(index) := output(output_position + index);
      end loop;
      decode_status := C.decode_header (header_bytes, record_header);
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

    status := RCT.initialize_without_shared_admission
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       application => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "callback-failure connection initializes");

    body_status := B.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "callback-failure BEGIN_REQUEST body encodes");

    append_record (input, input_position, P.BEGIN_REQUEST, begin_bytes);
    append_record (input, input_position, P.PARAMS, empty);
    append_record (input, input_position, P.STDIN, empty);
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
        RC.active_requests(connection) = 0 and then
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
      (reporter, RC.active_requests(connection), 0,
       "callback failure retires only its request");
    A.assert_true
      (reporter, RC.is_active(connection),
       "KEEP_CONN transport survives callback failure");
    A.assert_true
      (reporter, RCT.output_accounting_consistent(connection),
       "callback-failure aggregate matches full slot scan");

    decode_next_header;
    A.assert_true
      (reporter, decode_status = C.Complete,
       "callback-failure STDOUT header decodes");
    A.assert_equal_integer
      (reporter, Integer(record_header.record_type), Integer(P.STDOUT),
       "callback failure closes STDOUT");
    A.assert_equal_integer
      (reporter, Integer(record_header.content_length), 0,
       "callback failure does not commit STDOUT payload");

    decode_next_header;
    A.assert_true
      (reporter, decode_status = C.Complete,
       "callback-failure STDERR header decodes");
    A.assert_equal_integer
      (reporter, Integer(record_header.record_type), Integer(P.STDERR),
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
       Integer(P.END_REQUEST),
       "callback failure emits END_REQUEST");
    A.assert_equal_integer
      (reporter, Integer(record_header.content_length),
       B.END_REQUEST_BODY_LENGTH,
       "callback failure emits complete END_REQUEST body");

    for index in end_bytes'range loop
      end_bytes(index) :=
        output(output_position - B.END_REQUEST_BODY_LENGTH + index);
    end loop;
    end_status := B.decode_end_request (end_bytes, end_body);
    A.assert_true
      (reporter, end_status = B.Body_Complete,
       "callback-failure END_REQUEST body decodes");
    A.assert_true
      (reporter, end_body.application_status = 1,
       "callback failure maps to appStatus 1");
    A.assert_equal_integer
      (reporter, Integer(end_body.protocol_status_code),
       Integer(P.REQUEST_COMPLETE),
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

  procedure request_generation_exhaustion
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Limit_Application;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 128,
       max_connection_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    begin_body : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : B.Body_Status;
    empty : P.Byte_Array (1 .. 0);
    begin_input : P.Byte_Array
      (1 .. P.HEADER_LENGTH + B.BEGIN_REQUEST_BODY_LENGTH);
    begin_position : Positive := begin_input'first;
    finish_input : P.Byte_Array (1 .. 2 * P.HEADER_LENGTH);
    finish_position : Positive := finish_input'first;
    identity : R.Identity;
    discarded : Natural;
  begin
    application.finish_on_stdin_end := True;
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "generation-exhaustion socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    discarded := drain_peer (peer_fd);

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "generation-exhaustion loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "generation-exhaustion executor initializes");
    status := RCT.initialize_without_shared_admission
      (connection, loop_context'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "generation-exhaustion connection initializes");
    RCT.seed_next_generation (connection, R.Generation'Last);

    body_status := B.encode_begin_request
      (begin_body, begin_bytes, begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "generation-exhaustion BEGIN_REQUEST fixture encodes");
    append_record (begin_input, begin_position, P.BEGIN_REQUEST, begin_bytes);
    status := write_all (peer_fd, begin_input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "last-generation BEGIN_REQUEST writes");

    for attempt in 1 .. 20 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      exit when status /= Clair.Status.OK or else
        RC.active_requests(connection) = 1;
    end loop;
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 1,
       "last generation request becomes active");
    identity := RCT.current_identity (connection, 1);
    A.assert_true
      (reporter, identity.generation = R.Generation'Last,
       "last request generation is issued exactly once");

    append_record (finish_input, finish_position, P.PARAMS, empty);
    append_record (finish_input, finish_position, P.STDIN, empty);
    status := write_all (peer_fd, finish_input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "last-generation request completion writes");
    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      discarded := discarded + drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      exit when status /= Clair.Status.OK or else
        RC.active_requests(connection) = 0;
    end loop;
    A.assert_true
      (reporter, application.finish_ok and then
       RC.active_requests(connection) = 0 and then RC.is_active(connection),
       "last generation retires while KEEP_CONN transport remains reusable");

    begin_position := begin_input'first;
    append_record (begin_input, begin_position, P.BEGIN_REQUEST, begin_bytes);
    status := write_all (peer_fd, begin_input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "post-exhaustion BEGIN_REQUEST reaches runtime");
    status := RCT.dispatch_io
      (connection, Clair.Event_Loop.NULL_SOURCE, runtime_fd,
       Clair.Event_Loop.EVENT_INPUT);
    A.assert_true
      (reporter, status = Clair.Status.RANGE_ERROR,
       "request generation exhaustion reports range error instead of wrapping");
    A.assert_false
      (reporter, RC.is_active(connection),
       "request generation exhaustion closes the connection fail-closed");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "generation-exhaustion connection finalizes after fail-closed cleanup");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "generation-exhaustion executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "generation-exhaustion executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "generation-exhaustion peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "generation-exhaustion loop finalizes");
  end request_generation_exhaustion;

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
       max_connection_output_bytes => 1024,
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
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    input         : P.Byte_Array
      (1 .. P.HEADER_LENGTH + B.BEGIN_REQUEST_BODY_LENGTH);
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

    status := RCT.initialize_without_shared_admission
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       application => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_lifetime_timeout => 20);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "timeout connection initializes");

    body_status := B.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "timeout BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
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
    A.assert_true
      (reporter, RCT.output_accounting_consistent(connection),
       "timeout aggregate matches full slot scan");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      drained := drained + drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when RC.active_requests(connection) = 0;
    end loop;

    drained := drained + drain_peer (peer_fd);
    A.assert_true (reporter, loop_ok, "timeout drain iterations succeed");
    A.assert_positive
      (reporter,
       Integer(drained),
       "timeout emits FastCGI completion output");
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 0,
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
       max_connection_output_bytes => 1024,
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
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    input         : P.Byte_Array
      (1 .. P.HEADER_LENGTH + B.BEGIN_REQUEST_BODY_LENGTH);
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

    status := RCT.initialize_without_shared_admission
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       application => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "shutdown connection initializes");

    body_status := B.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "shutdown BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
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
      exit when RC.active_requests(connection) = 1;
    end loop;

    A.assert_true (reporter, loop_ok, "shutdown admission iterations succeed");
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 1,
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
       max_connection_output_bytes => 1024,
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
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array
      (1 .. 2 * P.HEADER_LENGTH + B.BEGIN_REQUEST_BODY_LENGTH);
    abort_input   : P.Byte_Array (1 .. P.HEADER_LENGTH);
    position      : Positive := input'first;
    abort_position : Positive := abort_input'first;
    drained       : Natural := 0;
    abort_seen_while_running : Boolean := False;
    expected_bytes : constant Natural :=
      3 * P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH;
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

    status := RCT.initialize_without_shared_admission
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       application => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "pending-abort connection initializes");

    body_status := B.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "pending-abort BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    append_record (input, position, P.PARAMS, empty);
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

    append_record (abort_input, abort_position, P.ABORT_REQUEST, empty);
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
        RC.active_requests(connection) = 0 and then
        E.active_count(executor) = 0 and then
        E.completed_count(executor) = 0;
    end loop;

    drained := drained + drain_peer (peer_fd);
    A.assert_true
      (reporter, loop_ok,
       "pending-abort completion iterations succeed");
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 0,
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
       max_connection_output_bytes => 1024,
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
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array
      (1 .. 2 * P.HEADER_LENGTH + B.BEGIN_REQUEST_BODY_LENGTH);
    position      : Positive := input'first;
    drained       : Natural := 0;
    cancellation_bytes : constant Natural :=
      3 * P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH;
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

    status := RCT.initialize_without_shared_admission
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       application => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_lifetime_timeout => 100);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late-output connection initializes");

    body_status := B.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "late-output BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    append_record (input, position, P.PARAMS, empty);
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
        RC.active_requests(connection) = 0 and then
        E.active_count(executor) = 0 and then
        E.completed_count(executor) = 0;
    end loop;

    drained := drained + drain_peer (peer_fd);
    A.assert_true
      (reporter, loop_ok,
       "late-output completion iterations succeed");
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 0,
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

  procedure shutdown_rejects_uninitialized_executor
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 1,
       max_value_bytes             => 1,
       max_request_output_bytes    => 64,
       max_connection_output_bytes => 64,
       read_buffer_bytes           => 1,
       write_chunk_bytes           => 1);
    connections  : constant S.Connection_Array (1 .. 1) :=
      [1 => connection'Unchecked_Access];
    outcome      : S.Outcome;
    status       : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "fresh-executor shutdown loop initializes");
    A.assert_false
      (reporter, E.is_initialized(executor),
       "fresh executor reports uninitialized lifecycle state");

    status := S.drain
      (event_loop   => loop_context,
       executor     => executor,
       connections  => connections,
       grace_period => 1_000,
       result       => outcome);
    A.assert_true
      (reporter, status = Clair.Status.INVALID_STATE,
       "shutdown rejects an uninitialized executor instead of grace expiry");

    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "fresh-executor shutdown loop finalizes");
  end shutdown_rejects_uninitialized_executor;

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
       max_connection_output_bytes => 1024,
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
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array
      (1 .. 2 * P.HEADER_LENGTH + B.BEGIN_REQUEST_BODY_LENGTH);
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

    status := RCT.initialize_without_shared_admission
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       application => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "graceful-shutdown connection initializes");

    body_status := B.encode_begin_request
      (request_body => begin_request,
       output       => begin_bytes,
       written      => begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "graceful-shutdown BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    append_record (input, position, P.PARAMS, empty);
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
       max_connection_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_body : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : B.Body_Status;
    begin_input : P.Byte_Array
      (1 .. P.HEADER_LENGTH + B.BEGIN_REQUEST_BODY_LENGTH);
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
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "discard-timeout executor initializes");
    status := RCT.initialize_without_shared_admission
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, application => application'Unchecked_Access,
       executor => executor'Unchecked_Access,
       request_lifetime_timeout => 100,
       diagnostics => diagnostics'Unchecked_Access,
       input_limits => (max_params_bytes => 4, max_stdin_bytes => 64,
                        max_data_bytes => 64));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "discard-timeout connection initializes");

    body_status := B.encode_begin_request
      (begin_body, begin_bytes, begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "discard-timeout BEGIN_REQUEST fixture encodes");
    append_record
      (begin_input, position, P.BEGIN_REQUEST, begin_bytes);
    status := write_all (peer_fd, begin_input);
    A.assert_true
      (reporter, status = Clair.Status.OK, "discard-timeout BEGIN writes");
    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      exit when status /= Clair.Status.OK or else
        RC.active_requests(connection) = 1;
    end loop;
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 1,
       "discard-timeout request becomes active");

    C.encode_header
      ((version => P.VERSION_1, record_type => P.PARAMS,
        request_id => 1, content_length => 5, padding_length => 0),
       limit_header);
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
      (reporter, RC.active_requests(connection), 1,
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
       max_connection_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_body : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : B.Body_Status;
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
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "stalled-output executor initializes");
    status := RCT.initialize_without_shared_admission
      (connection, loop_context'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 200);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "stalled-output connection initializes");

    body_status := B.encode_begin_request
      (begin_body, begin_bytes, begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "stalled-output BEGIN_REQUEST fixture encodes");
    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    append_record (input, position, P.PARAMS, empty);
    append_record (input, position, P.STDIN, empty);
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
       max_connection_output_bytes => 1_024, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_body : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : B.Body_Status;
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
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK, "limit executor initializes");
    status := RCT.initialize_without_shared_admission
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, application => application'Unchecked_Access,
       executor => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000,
       input_limits => (max_params_bytes => 4, max_stdin_bytes => 4,
                        max_data_bytes => 4),
       diagnostics => diagnostics'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK, "limit connection initializes");
    body_status := B.encode_begin_request
      (begin_body, begin_bytes, begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "PARAMS-limit BEGIN_REQUEST fixture encodes");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    append_record (input, position, P.PARAMS, first_three);
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
    append_record (input, position, P.PARAMS, last_one);
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
    append_record (input, position, P.PARAMS, over_one);
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
        RC.active_requests(connection) = 0;
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
      (reporter, RC.active_requests(connection), 0,
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
       max_connection_output_bytes => 1_024, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_body : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : B.Body_Status;
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
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK, "STDIN limit executor initializes");
    status := RCT.initialize_without_shared_admission
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, application => application'Unchecked_Access,
       executor => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000,
       diagnostics => diagnostics'Unchecked_Access,
       input_limits => (max_params_bytes => 64, max_stdin_bytes => 4,
                        max_data_bytes => 64));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "STDIN limit connection initializes");
    body_status := B.encode_begin_request
      (begin_body, begin_bytes, begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "STDIN-limit BEGIN_REQUEST fixture encodes");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    append_record (input, position, P.PARAMS, empty);
    append_record (input, position, P.STDIN, below);
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
    append_record (input, position, P.STDIN, exact);
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
    append_record (input, position, P.STDIN, above);
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
        RC.active_requests(connection) = 0;
    end loop;
    drained := drained + drain_peer (peer_fd);
    A.assert_positive
      (reporter, Integer(drained), "STDIN limit completion reaches peer");
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 0,
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
       max_connection_output_bytes => 1_024, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_body : constant B.Begin_Request_Body :=
      (role_code => P.FILTER_CODE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : B.Body_Status;
    params : P.Byte_Array (1 .. 64);
    params_position : Positive := params'first;
    empty : P.Byte_Array (1 .. 0);
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
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA limit executor initializes");
    status := RCT.initialize_without_shared_admission
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, application => application'Unchecked_Access,
       executor => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000,
       diagnostics => diagnostics'Unchecked_Access,
       input_limits => (max_params_bytes => 64, max_stdin_bytes => 64,
                        max_data_bytes => 0));
    A.assert_true
      (reporter, status = Clair.Status.OK, "DATA limit connection initializes");
    body_status := B.encode_begin_request
      (begin_body, begin_bytes, begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "DATA-limit BEGIN_REQUEST fixture encodes");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    append_record
      (input, position, P.PARAMS,
       params(params'first .. params_position - 1));
    append_record (input, position, P.PARAMS, empty);
    append_record (input, position, P.STDIN, empty);
    append_record (input, position, P.DATA, above);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "DATA zero-limit non-empty input writes");
    for iteration in 1 .. 80 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      drained := drained + drain_peer (peer_fd);
      exit when status /= Clair.Status.OK or else diagnostics.count = 1;
    end loop;
    A.assert_equal_natural
      (reporter, application.data_bytes, 0,
       "DATA zero limit delivers no content bytes");
    A.assert_equal_natural
      (reporter, diagnostics.count, 1,
       "DATA zero limit rejects the first non-empty record");
    A.assert_true
      (reporter,
       RCT.current_cancellation_reason(connection, 1) = R.Resource_Limit,
       "DATA limit records Resource_Limit cancellation");

    for iteration in 1 .. 80 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 20, dispatched);
      drained := drained + drain_peer (peer_fd);
      exit when status /= Clair.Status.OK or else
        RC.active_requests(connection) = 0;
    end loop;
    drained := drained + drain_peer (peer_fd);
    A.assert_positive
      (reporter, Integer(drained), "DATA limit completion reaches peer");
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 0,
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

  procedure idle_connection_deadline_resists_trickle
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Limit_Application;
    admission    : aliased AD.Context
      (max_connections => 1, max_requests => 1);
    connection   : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1_024,
       max_connection_output_bytes => 1_024,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    runtime_fd   : Clair.IO.Descriptor;
    peer_fd      : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    outcome      : RC.Initialization_Outcome;
    loop_ok      : Boolean := True;
    first_byte   : constant P.Byte_Array := [P.VERSION_1];
    second_byte  : constant P.Byte_Array := [P.BEGIN_REQUEST];
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "idle-deadline socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline loop initializes");
    status := E.initialize
      (self => executor, event_loop => loop_context'Unchecked_Access,
       worker_count => 1, pending_capacity => 1, max_input_bytes => 128,
       max_output_bytes => 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline executor initializes");
    status := RC.initialize
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, application => application'Unchecked_Access,
       executor => executor'Unchecked_Access, request_lifetime_timeout => 1_000,
       idle_connection_timeout => 0, admission => admission'Unchecked_Access,
       outcome => outcome);
    A.assert_true
      (reporter,
       status = Clair.Status.INVALID_ARGUMENT and then
       outcome = RC.Failed_Releasable and then
       not RC.is_active(connection) and then
       AD.active_connections(admission) = 0,
       "zero idle timeout is rejected before admission or descriptor ownership");

    status := RC.initialize
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, application => application'Unchecked_Access,
       executor => executor'Unchecked_Access, request_lifetime_timeout => 1_000,
       idle_connection_timeout => 200, admission => admission'Unchecked_Access,
       outcome => outcome);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then outcome = RC.Activated and then
       AD.active_connections(admission) = 1,
       "idle-deadline connection acquires one admission slot");

    status := write_all (peer_fd, first_byte);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline first partial header byte writes");
    status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline first partial byte is processed");

    delay 0.12;
    status := write_all (peer_fd, second_byte);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline second partial header byte writes");
    status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline second partial byte is processed");

    delay 0.12;
    for attempt in 1 .. 8 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 0, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when not RC.is_active(connection);
    end loop;

    A.assert_true
      (reporter, loop_ok, "idle-deadline event-loop dispatch succeeds");
    A.assert_false
      (reporter, RC.is_active(connection),
       "partial-byte trickle does not refresh zero-request deadline");
    A.assert_equal_natural
      (reporter, AD.active_connections(admission), 0,
       "idle deadline releases the shared connection admission slot");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline closed connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-deadline loop finalizes");
  end idle_connection_deadline_resists_trickle;

  procedure idle_connection_deadline_handoff
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Limit_Application;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1_024,
       max_connection_output_bytes => 1_024,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    runtime_fd   : Clair.IO.Descriptor;
    peer_fd      : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    loop_ok      : Boolean := True;
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE,
       flags     => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    begin_input   : P.Byte_Array
      (1 .. P.HEADER_LENGTH + B.BEGIN_REQUEST_BODY_LENGTH);
    begin_position : Positive := begin_input'first;
    empty         : P.Byte_Array (1 .. 0);
    finish_input  : P.Byte_Array (1 .. 2 * P.HEADER_LENGTH);
    finish_position : Positive := finish_input'first;
    drained       : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "idle-handoff socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    application.finish_on_stdin_end := True;

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-handoff loop initializes");
    status := E.initialize
      (self => executor, event_loop => loop_context'Unchecked_Access,
       worker_count => 1, pending_capacity => 1, max_input_bytes => 128,
       max_output_bytes => 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-handoff executor initializes");
    status := RCT.initialize_without_shared_admission
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, application => application'Unchecked_Access,
       executor => executor'Unchecked_Access, request_lifetime_timeout => 1_000,
       idle_connection_timeout => 100);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-handoff connection initializes");

    body_status := B.encode_begin_request
      (request_body => begin_request, output => begin_bytes,
       written => begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "idle-handoff BEGIN_REQUEST body encodes");
    append_record (begin_input, begin_position, P.BEGIN_REQUEST, begin_bytes);
    status := write_all (peer_fd, begin_input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-handoff BEGIN_REQUEST writes");

    for attempt in 1 .. 20 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when RC.active_requests(connection) = 1;
    end loop;
    A.assert_true
      (reporter, loop_ok and then RC.active_requests(connection) = 1,
       "accepted request takes ownership from idle deadline");

    delay 0.15;
    for attempt in 1 .. 4 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 0, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
    end loop;
    A.assert_true
      (reporter,
       loop_ok and then RC.is_active(connection) and then
       RC.active_requests(connection) = 1,
       "active request is not closed by zero-request deadline");

    append_record (finish_input, finish_position, P.PARAMS, empty);
    append_record (finish_input, finish_position, P.STDIN, empty);
    status := write_all (peer_fd, finish_input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-handoff request terminators write");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      drained := drained + drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when RC.active_requests(connection) = 0;
    end loop;
    drained := drained + drain_peer (peer_fd);
    A.assert_true
      (reporter,
       loop_ok and then RC.active_requests(connection) = 0 and then
       RC.is_active(connection),
       "KEEP_CONN request retires before idle deadline restarts");
    A.assert_positive
      (reporter, Integer(drained),
       "idle-handoff request completion output drains");

    delay 0.15;
    for attempt in 1 .. 8 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 0, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when not RC.is_active(connection);
    end loop;
    A.assert_true
      (reporter, loop_ok, "rearmed idle deadline dispatch succeeds");
    A.assert_false
      (reporter, RC.is_active(connection),
       "last request retirement rearms idle connection deadline");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-handoff closed connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-handoff executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-handoff executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-handoff peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle-handoff loop finalizes");
  end idle_connection_deadline_handoff;

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
       max_connection_output_bytes => 1_024,
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
      [P.VERSION_1, P.BEGIN_REQUEST, 0, 1];
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
       worker_count => 1, pending_capacity => 1, max_input_bytes => 128,
       max_output_bytes => 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK, "truncated executor initializes");
    status := RCT.initialize_without_shared_admission
      (self => connection, event_loop => loop_context'Unchecked_Access,
       fd => runtime_fd, application => application'Unchecked_Access,
       executor => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000);
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

  procedure executor_loop_affinity
    (reporter : in out Clair.Test.Reporter.Context)
  is
    executor_loop : aliased Clair.Event_Loop.Context;
    foreign_loop  : aliased Clair.Event_Loop.Context;
    executor      : aliased E.Context;
    application   : aliased Test_Application;
    connection    : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 128,
       max_connection_output_bytes => 128,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "loop-affinity socketpair is created");
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);

    status := Clair.Event_Loop.initialize (executor_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "executor event loop initializes");
    status := Clair.Event_Loop.initialize (foreign_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "foreign event loop initializes");

    status := E.initialize
      (executor, executor_loop'Unchecked_Access,
       worker_count => 1, pending_capacity => 1,
       max_input_bytes => 128, max_output_bytes => 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "loop-affinity executor initializes");
    A.assert_true
      (reporter,
       EI.uses_event_loop(executor, executor_loop'Unchecked_Access),
       "executor reports its owning event loop");
    A.assert_false
      (reporter, EI.uses_event_loop(executor, foreign_loop'Unchecked_Access),
       "executor rejects a foreign event loop identity");

    status := RCT.initialize_without_shared_admission
      (connection, foreign_loop'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access,
       request_lifetime_timeout => 60_000);
    A.assert_true
      (reporter, status = Clair.Status.INVALID_ARGUMENT,
       "connection rejects executor on a different event loop");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "rejected loop-affinity connection finalizes cleanly");
    status := Clair.IO.close (runtime_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "rejected connection leaves runtime descriptor caller-owned");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "loop-affinity peer closes");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "loop-affinity executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "loop-affinity executor finalizes");
    status := Clair.Event_Loop.finalize (foreign_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "foreign event loop finalizes");
    status := Clair.Event_Loop.finalize (executor_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "executor event loop finalizes");
  end executor_loop_affinity;

  procedure saturation_wait_is_event_driven
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    blocker      : aliased Blocking_Application;
    second_app   : aliased Limit_Application;
    third_app    : aliased Limit_Application;
    first_connection  : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 128,
       max_connection_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    second_connection : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 128,
       max_connection_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    third_connection  : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 128,
       max_connection_output_bytes => 128, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    first_raw  : aliased Interfaces.C.int := -1;
    first_peer_raw : aliased Interfaces.C.int := -1;
    second_raw : aliased Interfaces.C.int := -1;
    second_peer_raw : aliased Interfaces.C.int := -1;
    third_raw  : aliased Interfaces.C.int := -1;
    third_peer_raw : aliased Interfaces.C.int := -1;
    first_fd   : Clair.IO.Descriptor;
    first_peer : Clair.IO.Descriptor;
    second_fd  : Clair.IO.Descriptor;
    second_peer : Clair.IO.Descriptor;
    third_fd   : Clair.IO.Descriptor;
    third_peer : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status : B.Body_Status;
    empty : P.Byte_Array (1 .. 0);
    pair_bytes : P.Byte_Array (1 .. 8);
    pair_position : Positive := pair_bytes'first;
    blocked_input : P.Byte_Array (1 .. 64);
    blocked_position : Positive := blocked_input'first;
    pair_input : P.Byte_Array (1 .. 64);
    pair_input_position : Positive := pair_input'first;
    loop_ok : Boolean := True;
  begin
    blocker.finish_after_release := False;

    native_error := c_socketpair (first_raw'access, first_peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "saturation first socketpair is created");
    native_error := c_socketpair (second_raw'access, second_peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "saturation second socketpair is created");
    native_error := c_socketpair (third_raw'access, third_peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "saturation third socketpair is created");

    first_fd := Clair.IO.Descriptor(first_raw);
    first_peer := Clair.IO.Descriptor(first_peer_raw);
    second_fd := Clair.IO.Descriptor(second_raw);
    second_peer := Clair.IO.Descriptor(second_peer_raw);
    third_fd := Clair.IO.Descriptor(third_raw);
    third_peer := Clair.IO.Descriptor(third_peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(first_peer)),
       "saturation first socket prefill is discarded");
    A.assert_positive
      (reporter, Integer(drain_peer(second_peer)),
       "saturation second socket prefill is discarded");
    A.assert_positive
      (reporter, Integer(drain_peer(third_peer)),
       "saturation third socket prefill is discarded");

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation event loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 128, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation executor initializes");

    status := RCT.initialize_without_shared_admission
      (first_connection, loop_context'Unchecked_Access, first_fd,
       blocker'Unchecked_Access, executor'Unchecked_Access, 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation first connection initializes");
    status := RCT.initialize_without_shared_admission
      (second_connection, loop_context'Unchecked_Access, second_fd,
       second_app'Unchecked_Access, executor'Unchecked_Access, 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation second connection initializes");
    status := RCT.initialize_without_shared_admission
      (third_connection, loop_context'Unchecked_Access, third_fd,
       third_app'Unchecked_Access, executor'Unchecked_Access, 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation third connection initializes");

    body_status := B.encode_begin_request
      (begin_request, begin_bytes, begin_written);
    A.assert_true
      (reporter, body_status = B.Body_Complete,
       "saturation BEGIN_REQUEST body encodes");
    append_record
      (blocked_input, blocked_position, P.BEGIN_REQUEST, begin_bytes);
    append_record (blocked_input, blocked_position, P.PARAMS, empty);

    append_pair (pair_bytes, pair_position, "A", "B");
    append_record
      (pair_input, pair_input_position, P.BEGIN_REQUEST, begin_bytes);
    append_record
      (pair_input, pair_input_position, P.PARAMS,
       pair_bytes(pair_bytes'first .. pair_position - 1));

    status := write_all
      (first_peer, blocked_input(blocked_input'first .. blocked_position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation blocking request is written");
    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when STC.Current_State(blocker.started);
    end loop;
    A.assert_true
      (reporter, loop_ok and then STC.Current_State(blocker.started),
       "saturation worker is occupied by blocking request");

    status := write_all
      (second_peer, pair_input(pair_input'first .. pair_input_position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation pending request is written");
    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      exit when status /= Clair.Status.OK or else E.pending_count(executor) = 1;
    end loop;
    A.assert_true
      (reporter, status = Clair.Status.OK and then
       E.pending_count(executor) = 1,
       "saturation executor pending queue is full");

    status := write_all
      (third_peer, pair_input(pair_input'first .. pair_input_position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation waiting request is written");
    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      exit when status /= Clair.Status.OK or else
        RC.is_read_paused(third_connection);
    end loop;
    A.assert_true
      (reporter, status = Clair.Status.OK and then
       RC.is_read_paused(third_connection) and then
       third_app.parameter_count = 0,
       "saturation third connection waits for executor capacity");

    status := Clair.Event_Loop.iterate
      (loop_context, timeout => 20, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK and then not dispatched,
       "saturation wait has no periodic retry dispatch");

    STC.Set_True (blocker.release_gate);
    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when second_app.parameter_count = 1 and then
        third_app.parameter_count = 1 and then E.is_idle(executor) and then
        E.completed_count(executor) = 0;
    end loop;
    A.assert_true
      (reporter, loop_ok and then second_app.parameter_count = 1 and then
       third_app.parameter_count = 1,
       "released capacity wakes and progresses the waiting connection");

    status := RC.finalize (first_connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation first connection finalizes");
    status := RC.finalize (second_connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation second connection finalizes");
    status := RC.finalize (third_connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation third connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation executor finalizes");
    status := Clair.IO.close (first_peer);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation first peer closes");
    status := Clair.IO.close (second_peer);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation second peer closes");
    status := Clair.IO.close (third_peer);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation third peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "saturation event loop finalizes");
  end saturation_wait_is_event_driven;

  procedure executor_limit_compatibility
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Test_Application;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 128,
       max_connection_output_bytes => 128,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    runtime_fd   : Clair.IO.Descriptor;
    peer_fd      : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "limit-compatibility socketpair is created");
    if native_error /= 0 then
      return;
    end if;

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "limit-compatibility loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => loop_context'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 64,
       max_output_bytes => 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "limit-compatibility executor initializes");

    status := RCT.initialize_without_shared_admission
      (self            => connection,
       event_loop      => loop_context'Unchecked_Access,
       fd              => runtime_fd,
       application => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000);
    A.assert_true
      (reporter, status = Clair.Status.INVALID_ARGUMENT,
       "connection rejects executor with smaller input capacity");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "rejected limit-compatibility connection finalizes");
    status := Clair.IO.close (runtime_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "rejected connection leaves runtime descriptor caller-owned");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "limit-compatibility peer closes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "limit-compatibility executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "limit-compatibility executor finalizes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "limit-compatibility loop finalizes");
  end executor_limit_compatibility;

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
       max_connection_output_bytes => 4_096,
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
      [2, P.BEGIN_REQUEST, 0, 1, 0, 0, 0, 0];
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
       max_input_bytes  => 128,
       max_output_bytes => 4_096);
    A.assert_true
      (reporter, status = Clair.Status.OK, "diagnostic executor initializes");

    status := RCT.initialize_without_shared_admission
      (self            => connection,
       event_loop      => loop_context'Unchecked_Access,
       fd              => runtime_fd,
       application => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_lifetime_timeout => 60_000,
       diagnostics     => diagnostics'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK, "diagnostic connection initializes");

    diagnostics.raise_on_report := True;
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
       "reporter exception does not escape protocol rejection dispatch");
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

  procedure tiny_parameter_records_batch
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Tiny_Batch_Application;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes => 64, max_value_bytes => 64,
       max_request_output_bytes => 256, max_connection_output_bytes => 256,
       read_buffer_bytes => 1_024, write_chunk_bytes => 256);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    loop_ok      : Boolean := True;
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    pair_bytes    : P.Byte_Array (1 .. 8);
    pair_position : Positive := pair_bytes'first;
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array (1 .. 1_024);
    position      : Positive := input'first;
    drained       : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "tiny-PARAMS socketpair is created");
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "tiny-PARAMS socket prefill is discarded");

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-PARAMS event loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 1_024, 256);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-PARAMS executor initializes");
    status := RCT.initialize_without_shared_admission
      (connection, loop_context'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-PARAMS connection initializes");

    body_status := B.encode_begin_request
      (begin_request, begin_bytes, begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "tiny-PARAMS BEGIN_REQUEST body encodes");
    append_pair (pair_bytes, pair_position, "A", "B");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    for pair_index in 1 .. TINY_BATCH_ITEM_COUNT loop
      pragma Unreferenced (pair_index);
      append_record
        (input, position, P.PARAMS,
         pair_bytes(pair_bytes'first .. pair_position - 1));
    end loop;
    append_record (input, position, P.PARAMS, empty);
    append_record (input, position, P.STDIN, empty);

    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "64 tiny PARAMS records are written");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when STC.Current_State(application.first_started);
    end loop;
    A.assert_true
      (reporter, loop_ok and then
       STC.Current_State(application.first_started),
       "first tiny parameter callback starts");

    STC.Set_True (application.release_gate);
    for attempt in 1 .. 1_000 loop
      pragma Unreferenced (attempt);
      exit when STC.Current_State(application.all_seen);
      delay 0.001;
    end loop;

    A.assert_true
      (reporter, STC.Current_State(application.all_seen),
       "all 64 callbacks run without Event Loop re-entry");
    A.assert_equal_natural
      (reporter, application.parameter_count, TINY_BATCH_ITEM_COUNT,
       "64 tiny records preserve all parameter callbacks");

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      drained := drained + drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when RC.active_requests(connection) = 0 and then
        E.is_idle(executor) and then E.completed_count(executor) = 0;
    end loop;
    drained := drained + drain_peer (peer_fd);
    pragma Unreferenced (drained);

    A.assert_true
      (reporter, loop_ok and then application.finish_ok and then
       RC.active_requests(connection) = 0,
       "tiny-PARAMS request completes normally");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-PARAMS connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-PARAMS executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-PARAMS executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-PARAMS peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-PARAMS event loop finalizes");
  end tiny_parameter_records_batch;

  procedure tiny_stdin_records_batch
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Tiny_Batch_Application;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes => 64, max_value_bytes => 64,
       max_request_output_bytes => 256, max_connection_output_bytes => 256,
       read_buffer_bytes => 1_024, write_chunk_bytes => 256);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    loop_ok      : Boolean := True;
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    one_byte      : constant P.Byte_Array := [1 => 16#5A#];
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array (1 .. 1_024);
    position      : Positive := input'first;
    drained       : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "tiny-STDIN socketpair is created");
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "tiny-STDIN socket prefill is discarded");

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-STDIN event loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 1_024, 256);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-STDIN executor initializes");
    status := RCT.initialize_without_shared_admission
      (connection, loop_context'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-STDIN connection initializes");

    body_status := B.encode_begin_request
      (begin_request, begin_bytes, begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "tiny-STDIN BEGIN_REQUEST body encodes");

    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    append_record (input, position, P.PARAMS, empty);
    for record_index in 1 .. TINY_BATCH_ITEM_COUNT loop
      pragma Unreferenced (record_index);
      append_record (input, position, P.STDIN, one_byte);
    end loop;
    append_record (input, position, P.STDIN, empty);

    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "64 tiny STDIN records are written");

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when STC.Current_State(application.stdin_started);
    end loop;
    A.assert_true
      (reporter, loop_ok and then STC.Current_State(application.stdin_started),
       "coalesced tiny STDIN callback starts");

    STC.Set_True (application.stdin_release);
    for attempt in 1 .. 1_000 loop
      pragma Unreferenced (attempt);
      exit when STC.Current_State(application.stdin_end_seen);
      delay 0.001;
    end loop;

    A.assert_true
      (reporter, STC.Current_State(application.stdin_end_seen),
       "STDIN terminal callback runs without Event Loop re-entry");
    A.assert_equal_natural
      (reporter, application.stdin_callback_count, 1,
       "64 tiny STDIN records coalesce into one application callback");
    A.assert_equal_natural
      (reporter, application.stdin_bytes, TINY_BATCH_ITEM_COUNT,
       "tiny STDIN batching preserves every payload byte");

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      drained := drained + drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate (loop_context, 10, dispatched);
      if status /= Clair.Status.OK then
        loop_ok := False;
        exit;
      end if;
      exit when RC.active_requests(connection) = 0 and then
        E.is_idle(executor) and then E.completed_count(executor) = 0;
    end loop;
    drained := drained + drain_peer (peer_fd);
    pragma Unreferenced (drained);

    A.assert_true
      (reporter, loop_ok and then application.finish_ok and then
       RC.active_requests(connection) = 0,
       "tiny-STDIN request completes normally");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-STDIN connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-STDIN executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-STDIN executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-STDIN peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "tiny-STDIN event loop finalizes");
  end tiny_stdin_records_batch;

  procedure input_dispatch_byte_budget
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Test_Application;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 1_024,
       max_connection_output_bytes => 2_048, read_buffer_bytes => 70_000,
       write_chunk_bytes => 4_096);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    header : constant P.Header :=
      (version => P.VERSION_1, record_type => 99, request_id => 0,
       content_length => P.Content_Length'Last, padding_length => 0);
    header_bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    input : P.Byte_Array
      (1 .. P.HEADER_LENGTH + Natural(P.Content_Length'Last)) :=
        [others => 0];
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "input-budget socketpair is created");
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    declare
      discarded_prefill : constant Natural := drain_peer(peer_fd);
    begin
      pragma Unreferenced (discarded_prefill);
    end;

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "input-budget loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 70_000, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK, "input-budget executor initializes");
    status := RCT.initialize_without_shared_admission
      (connection, loop_context'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "input-budget connection initializes");

    C.encode_header (header, header_bytes);
    for index in header_bytes'range loop
      input(index + 1) := header_bytes(index);
    end loop;
    RCT.seed_pending_input (connection, input);

    status := RCT.dispatch_io
      (connection, Clair.Event_Loop.NULL_SOURCE, runtime_fd,
       Clair.Event_Loop.Event_Mask(0));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "input-budget first owner dispatch succeeds");
    A.assert_equal_natural
      (reporter, RCT.input_dispatch_bytes(connection),
       RCT.input_dispatch_budget,
       "one owner dispatch consumes exactly the input byte budget");
    A.assert_equal_natural
      (reporter, RC.pending_input_bytes(connection),
       input'length - RCT.input_dispatch_budget,
       "bytes beyond the input budget remain buffered");

    status := RCT.dispatch_io
      (connection, Clair.Event_Loop.NULL_SOURCE, runtime_fd,
       Clair.Event_Loop.Event_Mask(0));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "input-budget second owner dispatch succeeds");
    A.assert_equal_natural
      (reporter, RCT.input_dispatch_bytes(connection),
       input'length - RCT.input_dispatch_budget,
       "next owner dispatch consumes the buffered remainder");
    A.assert_equal_natural
      (reporter, RC.pending_input_bytes(connection), 0,
       "second owner dispatch drains the seeded record");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK, "input-budget connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "input-budget executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "input-budget executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "input-budget peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "input-budget loop finalizes");
  end input_dispatch_byte_budget;

  procedure output_dispatch_byte_budget
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    executor     : aliased E.Context;
    application  : aliased Fairness_Application;
    connection   : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 262_144,
       max_connection_output_bytes => 262_144, read_buffer_bytes => 4_096,
       write_chunk_bytes => 131_072);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    begin_request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    empty : P.Byte_Array (1 .. 0);
    input : P.Byte_Array (1 .. 24);
    position : Positive := input'first;
    pending_before : Natural;
    discarded : Natural;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "output-budget socketpair is created");
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    declare
      discarded_prefill : constant Natural := drain_peer(peer_fd);
    begin
      pragma Unreferenced (discarded_prefill);
    end;

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "output-budget loop initializes");
    status := E.initialize
      (executor, loop_context'Unchecked_Access, 1, 1, 4_096, 262_144);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "output-budget executor initializes");
    status := RCT.initialize_without_shared_admission
      (connection, loop_context'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "output-budget connection initializes");

    body_status := B.encode_begin_request
      (begin_request, begin_bytes, begin_written);
    A.assert_true
      (reporter, body_status = B.Body_Complete,
       "output-budget BEGIN_REQUEST body encodes");
    append_record (input, position, P.BEGIN_REQUEST, begin_bytes);
    append_record (input, position, P.PARAMS, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "output-budget request prefix writes");

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate
        (loop_context, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "output-budget setup dispatch succeeds");
      exit when application.params_end_seen and then
        RC.pending_output_bytes(connection) > RCT.output_dispatch_budget;
    end loop;

    A.assert_true
      (reporter, application.large_write_ok,
       "large fairness response is accepted");
    A.assert_true
      (reporter,
       RC.pending_output_bytes(connection) > RCT.output_dispatch_budget,
       "large fairness response exceeds one output dispatch budget");
    discarded := drain_peer (peer_fd);
    pragma Unreferenced (discarded);
    pending_before := RC.pending_output_bytes(connection);

    status := RCT.dispatch_io
      (connection, Clair.Event_Loop.NULL_SOURCE, runtime_fd,
       Clair.Event_Loop.EVENT_OUTPUT);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "output-budget direct writable dispatch succeeds");
    A.assert_positive
      (reporter, Integer(RCT.output_dispatch_bytes(connection)),
       "writable dispatch makes bounded output progress");
    A.assert_true
      (reporter, RCT.output_dispatch_bytes(connection) <=
         RCT.output_dispatch_budget,
       "one writable dispatch never exceeds the output byte budget");
    A.assert_equal_natural
      (reporter, RC.pending_output_bytes(connection),
       pending_before - RCT.output_dispatch_bytes(connection),
       "queued output decreases by exactly the bytes actually sent");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when E.completed_count(executor) = 0;
      discarded := drain_peer (peer_fd);
      status := Clair.Event_Loop.iterate
        (loop_context, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "output-budget completion slices continue to drain");
    end loop;
    A.assert_equal_natural
      (reporter, E.completed_count(executor), 0,
       "output-budget completion delivery reaches its final slice");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "output-budget connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "output-budget executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "output-budget executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "output-budget peer closes");
    status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "output-budget loop finalizes");
  end output_dispatch_byte_budget;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter, "listener lifecycle", listener_lifecycle'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "listener callback exception containment",
       listener_callback_exception_is_contained'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "listener callback rejection cleanup",
       listener_callback_rejection_reclaims_descriptor'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "listener accept storm is bounded",
       listener_accept_storm_is_bounded'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "admitted initialization failure releases capacity",
       admitted_initialization_failure_releases_capacity'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "watch initialization failure rolls back timer",
       watch_initialization_failure_rolls_back_timer'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "connection requires finalize before reinitialize",
       connection_requires_finalize_before_reinitialize'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "repeated connection lifecycle reuse",
       repeated_connection_lifecycle_reuse'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "resource-limit discard timeout",
       resource_limit_discard_timeout'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "stalled output timeout", stalled_output_timeout'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "input dispatch byte budget",
       input_dispatch_byte_budget'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "output dispatch byte budget",
       output_dispatch_byte_budget'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "stream input limits", stream_input_limits'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "STDIN input limits", stdin_input_limits'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "DATA input limits", data_input_limits'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "idle connection deadline resists trickle",
       idle_connection_deadline_resists_trickle'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "idle connection deadline handoff",
       idle_connection_deadline_handoff'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "truncated connection input",
       truncated_connection_input'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "executor event-loop affinity",
       executor_loop_affinity'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "executor saturation wait is event driven",
       saturation_wait_is_event_driven'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "tiny parameter records batch",
       tiny_parameter_records_batch'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "tiny STDIN records batch",
       tiny_stdin_records_batch'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "executor limit compatibility",
       executor_limit_compatibility'access);
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
       "request generation exhaustion",
       request_generation_exhaustion'access);
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
       "shutdown rejects uninitialized executor",
       shutdown_rejects_uninitialized_executor'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "bounded graceful shutdown",
       bounded_graceful_shutdown'access);
  end run;

end Tests.Runtime;
