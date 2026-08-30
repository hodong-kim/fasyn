-- ============================================================================
-- tests-multiplexing.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces.C;
with System.Storage_Elements;
with Clair.Event_Loop;
with Clair.IO;
with Clair.IO.Posix;
with Clair.Status;
with Clair.Test.Assertions;
with Fasyn.Protocol;
with Fasyn.Protocol.Codec;
with Fasyn.Protocol.Messages;
with Fasyn.Request;
with Fasyn.Request.Connection;
with Fasyn.Request.Connection.Testing;
with Fasyn.Request.Execution;

package body Tests.Multiplexing is

  package A renames Clair.Test.Assertions;
  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package M renames Fasyn.Protocol.Messages;
  package R renames Fasyn.Request;
  package RC renames Fasyn.Request.Connection;
  package RCT renames Fasyn.Request.Connection.Testing;
  package E renames Fasyn.Request.Execution;

  use type Interfaces.C.int;
  use type Interfaces.Unsigned_8;
  use type Clair.IO.Byte_Count;
  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type C.Decode_Status;
  use type M.Body_Status;
  use type P.Request_Id_Type;
  use type R.Cancellation_Cause;
  use type R.Defer_Status;
  use type R.Deferred_Write_Status;
  use type R.Request_Generation;
  use type R.Request_Identity;
  use type R.Write_Status;

  function c_socketpair
    (runtime_fd : access Interfaces.C.int;
     peer_fd    : access Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_socketpair";

  type Multiplex_Application is new R.Application with record
    completions : Natural := 0;
    write_ok    : Boolean := True;
  end record;

  overriding procedure on_parameter
    (self    : in out Multiplex_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Multiplex_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Multiplex_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Multiplex_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Multiplex_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (self, context, name, value);
  begin
    null;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Multiplex_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin
    null;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Multiplex_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, data, response);
  begin
    null;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Multiplex_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    data          : P.Byte_Array (1 .. 1);
    write_status  : R.Write_Status;
    finish_status : R.Write_Status;
  begin
    self.completions := self.completions + 1;

    if self.completions = 1 then
      data(1) := P.Byte(Character'Pos('2'));
    else
      data(1) := P.Byte(Character'Pos('1'));
    end if;

    R.write_stdout (response, data, write_status);
    R.finish (response, 0, finish_status);
    self.write_ok := self.write_ok and then
      write_status = R.Write_Complete and then
      finish_status = R.Write_Complete;
  end on_stdin_end;

  type Deferred_Application is limited new R.Application with record
    first_handle          : R.Deferred_Request;
    second_handle         : R.Deferred_Request;
    reused_first_handle   : R.Deferred_Request;
    midstream_handle      : R.Deferred_Request;
    terminal_callbacks    : Natural := 0;
    first_generations     : Natural := 0;
    defer_ok              : Boolean := True;
    pre_defer_write_ok    : Boolean := True;
    writer_closed_ok      : Boolean := True;
    midstream_not_allowed : Boolean := True;
    midstream_attempted   : Boolean := False;
  end record;

  overriding procedure on_parameter
    (self    : in out Deferred_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Deferred_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Deferred_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Deferred_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Deferred_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (self, context, name, value);
  begin
    null;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Deferred_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin
    null;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Deferred_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (data);
    defer_status : R.Defer_Status;
  begin
    if not self.midstream_attempted then
      R.defer_response
        (context, response, self.midstream_handle, defer_status);
      self.midstream_attempted := True;
      self.midstream_not_allowed := defer_status = R.Defer_Not_Allowed;
    end if;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Deferred_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    request      : constant R.Request_Identity := R.identity(context);
    defer_status : R.Defer_Status := R.Defer_Not_Ready;
    write_status : R.Write_Status;
    marker       : constant P.Byte_Array := [P.Byte(Character'Pos('x'))];
  begin
    self.terminal_callbacks := self.terminal_callbacks + 1;

    if request.request_id = 1 then
      R.write_stdout (response, marker, write_status);
      self.pre_defer_write_ok := self.pre_defer_write_ok and then
        write_status = R.Write_Complete;
    end if;

    if request.request_id = 1 then
      self.first_generations := self.first_generations + 1;
      if self.first_generations = 1 then
        R.defer_response
          (context, response, self.first_handle, defer_status);
      elsif self.first_generations = 2 then
        R.defer_response
          (context, response, self.reused_first_handle, defer_status);
      end if;
    elsif request.request_id = 2 then
      R.defer_response
        (context, response, self.second_handle, defer_status);
    end if;

    self.defer_ok := self.defer_ok and then defer_status = R.Defer_Complete;

    if defer_status = R.Defer_Complete then
      R.write_stdout (response, marker, write_status);
      self.writer_closed_ok := self.writer_closed_ok and then
        write_status = R.Writer_Closed;
    end if;
  end on_stdin_end;

  procedure append_record
    (buffer      : in out P.Byte_Array;
     position    : in out Positive;
     request_id  : in P.Request_Id_Type;
     record_type : in P.Byte;
     content     : in P.Byte_Array)
  is
    record_header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => request_id,
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

  procedure discard_available (fd : in Clair.IO.Descriptor) is
    ignored : P.Byte_Array (1 .. 8192);
    length  : Natural := 0;
  begin
    read_available (fd, ignored, length);
  end discard_available;

  procedure encode_begin
    (output : out P.Byte_Array;
     flags  : P.Byte := P.KEEP_CONN)
  is
    request_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE,
       flags     => flags);
    written : Natural;
    status  : M.Body_Status;
  begin
    M.encode_begin_request
      (request_body => request_body,
       output       => output,
       written      => written,
       status       => status);

    if status /= M.Body_Complete or else
       written /= M.BEGIN_REQUEST_BODY_LENGTH
    then
      raise Program_Error;
    end if;
  end encode_begin;

  procedure pump
    (reporter   : in out Clair.Test.Reporter.Context;
     event_loop : in out Clair.Event_Loop.Context;
     peer_fd    : in Clair.IO.Descriptor;
     connection : in RC.Context;
     output     : in out P.Byte_Array;
     length     : in out Natural;
     until_idle : in Boolean)
  is
    status     : Clair.Status.Code;
    dispatched : Boolean;
  begin
    for iteration in 1 .. 200 loop
      pragma Unreferenced (iteration);

      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      A.assert_true
        (reporter,
         status = Clair.Status.OK,
         "multiplex event-loop iteration succeeds");
      read_available (peer_fd, output, length);

      exit when
        (if until_idle then
           RC.active_request_count(connection) = 0 and then
           RC.pending_output_bytes(connection) = 0
         else
           RC.active_request_count(connection) > 0);
    end loop;
  end pump;

  procedure inspect_completed_output
    (reporter : in out Clair.Test.Reporter.Context;
     output   : in P.Byte_Array;
     length   : in Natural)
  is
    position : Natural := output'first;
    header_bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    record_header : P.Header;
    status : C.Decode_Status;
    end_count_1 : Natural := 0;
    end_count_2 : Natural := 0;
    stdout_1_ok : Boolean := False;
    stdout_2_ok : Boolean := False;
    record_length : Natural;
  begin
    while position <= output'first + length - 1 loop
      A.assert_true
        (reporter,
         position + P.HEADER_LENGTH - 1 <= output'first + length - 1,
         "multiplex output ends on a record boundary");

      for index in header_bytes'range loop
        header_bytes(index) := output(position + index);
      end loop;

      C.decode_header (header_bytes, record_header, status);
      A.assert_true
        (reporter, status = C.Complete, "multiplex output header decodes");

      record_length :=
        P.HEADER_LENGTH +
        Natural(record_header.content_length) +
        Natural(record_header.padding_length);

      A.assert_true
        (reporter,
         position + record_length - 1 <= output'first + length - 1,
         "multiplex output contains a whole FastCGI record");

      if record_header.record_type = P.STDOUT_TYPE and then
         record_header.content_length = 1
      then
        if record_header.request_id = 2 then
          stdout_2_ok :=
            output(position + P.HEADER_LENGTH) =
              P.Byte(Character'Pos('2'));
        elsif record_header.request_id = 1 then
          stdout_1_ok :=
            output(position + P.HEADER_LENGTH) =
              P.Byte(Character'Pos('1'));
        end if;
      elsif record_header.record_type = P.END_REQUEST_TYPE then
        if record_header.request_id = 1 then
          end_count_1 := end_count_1 + 1;
        elsif record_header.request_id = 2 then
          end_count_2 := end_count_2 + 1;
        end if;
      end if;

      position := position + record_length;
    end loop;

    A.assert_true
      (reporter,
       stdout_1_ok,
       "request 1 output keeps request identity");
    A.assert_true
      (reporter,
       stdout_2_ok,
       "request 2 output keeps request identity");
    A.assert_equal_natural
      (reporter,
       end_count_1,
       1,
       "request 1 has one END_REQUEST");
    A.assert_equal_natural
      (reporter,
       end_count_2,
       1,
       "request 2 has one END_REQUEST");
  end inspect_completed_output;

  function record_count
    (output      : P.Byte_Array;
     length      : Natural;
     request_id  : P.Request_Id_Type;
     record_type : P.Byte) return Natural
  is
    position : Natural := output'first;
    bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    header : P.Header;
    status : C.Decode_Status;
    count : Natural := 0;
    record_length : Natural;
  begin
    while position + P.HEADER_LENGTH - 1 <= output'first + length - 1 loop
      for offset in bytes'range loop
        bytes(offset) := output(position + offset);
      end loop;
      C.decode_header (bytes, header, status);
      exit when status /= C.Complete;
      record_length := P.HEADER_LENGTH + Natural(header.content_length) +
        Natural(header.padding_length);
      exit when position + record_length - 1 > output'first + length - 1;
      if header.request_id = request_id and then
         header.record_type = record_type
      then
        count := count + 1;
      end if;
      position := position + record_length;
    end loop;
    return count;
  end record_count;

  function record_position
    (output      : P.Byte_Array;
     length      : Natural;
     request_id  : P.Request_Id_Type;
     record_type : P.Byte) return Natural
  is
    position      : Natural := output'first;
    bytes         : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    header        : P.Header;
    status        : C.Decode_Status;
    record_length : Natural;
  begin
    while position + P.HEADER_LENGTH - 1 <= output'first + length - 1 loop
      for offset in bytes'range loop
        bytes(offset) := output(position + offset);
      end loop;
      C.decode_header (bytes, header, status);
      exit when status /= C.Complete;
      record_length := P.HEADER_LENGTH + Natural(header.content_length) +
        Natural(header.padding_length);
      exit when position + record_length - 1 > output'first + length - 1;
      if header.request_id = request_id and then
         header.record_type = record_type
      then
        return position;
      end if;
      position := position + record_length;
    end loop;
    return 0;
  end record_position;

  procedure pump_deferred_state
    (reporter           : in out Clair.Test.Reporter.Context;
     event_loop         : in out Clair.Event_Loop.Context;
     peer_fd            : in Clair.IO.Descriptor;
     connection         : in RC.Context;
     executor           : in E.Context;
     application        : in Deferred_Application;
     output             : in out P.Byte_Array;
     output_length      : in out Natural;
     expected_active    : in Natural;
     expected_callbacks : in Natural;
     read_peer          : in Boolean := True)
  is
    status     : Clair.Status.Code := Clair.Status.OK;
    dispatched : Boolean;
  begin
    for iteration in 1 .. 300 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "deferred event-loop iteration succeeds");
      exit when status /= Clair.Status.OK;

      if read_peer then
        read_available (peer_fd, output, output_length);
      end if;

      exit when
        RC.active_request_count(connection) = expected_active and then
        RC.pending_output_bytes(connection) = 0 and then
        application.terminal_callbacks >= expected_callbacks and then
        E.active_count(executor) = 0 and then
        E.pending_count(executor) = 0 and then
        E.completed_count(executor) = 0;
    end loop;

    A.assert_true
      (reporter,
       RC.active_request_count(connection) = expected_active and then
       application.terminal_callbacks >= expected_callbacks and then
       E.active_count(executor) = 0 and then E.pending_count(executor) = 0,
       "deferred fixture reaches expected quiescent state");
  end pump_deferred_state;

  procedure initialize_deferred_fixture
    (reporter        : in out Clair.Test.Reporter.Context;
     event_loop      : not null access Clair.Event_Loop.Context;
     executor        : not null access E.Context;
     connection      : in out RC.Context;
     application     : not null access Deferred_Application;
     runtime_fd            : out Clair.IO.Descriptor;
     peer_fd               : out Clair.IO.Descriptor;
     request_timeout       : in Clair.Event_Loop.Milliseconds := 60_000;
     executor_output_bytes : in Positive := 1_024)
  is
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "deferred socketpair is created");
    if native_error /= 0 then
      runtime_fd := Clair.IO.INVALID_DESCRIPTOR;
      peer_fd := Clair.IO.INVALID_DESCRIPTOR;
      return;
    end if;

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    discard_available (peer_fd);

    status := Clair.Event_Loop.initialize (event_loop.all);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred event loop initializes");

    status := E.initialize
      (self              => executor.all,
       event_loop        => event_loop.all'Unchecked_Access,
       worker_count      => 1,
       pending_capacity  => 4,
       max_input_bytes   => 256,
       max_output_bytes  => executor_output_bytes,
       deferred_capacity => 8);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => event_loop.all'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application.all'Unchecked_Access,
       executor        => executor.all'Unchecked_Access,
       request_timeout => request_timeout,
       connection_id   => 91);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred connection initializes");
  end initialize_deferred_fixture;

  procedure finalize_deferred_fixture
    (reporter   : in out Clair.Test.Reporter.Context;
     event_loop : not null access Clair.Event_Loop.Context;
     executor   : not null access E.Context;
     connection : in out RC.Context;
     peer_fd    : in out Clair.IO.Descriptor)
  is
    status     : Clair.Status.Code;
    dispatched : Boolean;
  begin
    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred connection finalizes");

    status := E.begin_shutdown (executor.all);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred executor shutdown begins");

    for iteration in 1 .. 100 loop
      pragma Unreferenced (iteration);
      exit when E.is_idle(executor.all) and then
        E.completed_count(executor.all) = 0;
      status := Clair.Event_Loop.iterate
        (event_loop.all, 10, dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "deferred shutdown iteration succeeds");
    end loop;

    status := E.finalize (executor.all);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred executor finalizes");

    if peer_fd /= Clair.IO.INVALID_DESCRIPTOR then
      status := Clair.IO.close (peer_fd);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "deferred peer closes");
      peer_fd := Clair.IO.INVALID_DESCRIPTOR;
    end if;

    status := Clair.Event_Loop.finalize (event_loop.all);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred event loop finalizes");
  end finalize_deferred_fixture;

  procedure start_single_deferred_request
    (reporter      : in out Clair.Test.Reporter.Context;
     event_loop    : in out Clair.Event_Loop.Context;
     executor      : in E.Context;
     connection    : in RC.Context;
     application   : in Deferred_Application;
     peer_fd       : in Clair.IO.Descriptor;
     output        : in out P.Byte_Array;
     output_length : in out Natural)
  is
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty       : P.Byte_Array (1 .. 0);
    input       : P.Byte_Array (1 .. 96);
    position    : Positive := input'first;
    status      : Clair.Status.Code;
  begin
    encode_begin (begin_bytes);
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 1, P.PARAMS_TYPE, empty);
    append_record (input, position, 1, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "single deferred request writes");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 1, expected_callbacks => 1);
    A.assert_true
      (reporter, application.defer_ok,
       "single request enters deferred state");
  end start_single_deferred_request;

  procedure deferred_sibling_progress_and_reuse
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Deferred_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 2,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 128,
       max_output_bytes            => 160,
       read_buffer_bytes           => 128,
       write_chunk_bytes           => 64);
    runtime_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    peer_fd    : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    status     : Clair.Status.Code;
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty       : P.Byte_Array (1 .. 0);
    stdin_byte  : constant P.Byte_Array := [P.Byte(Character'Pos('i'))];
    input       : P.Byte_Array (1 .. 256);
    position    : Positive := input'first;
    output      : P.Byte_Array (1 .. 32_768);
    output_length : Natural := 0;
    payload_1   : constant P.Byte_Array (1 .. 80) :=
      [others => P.Byte(Character'Pos('1'))];
    payload_2   : constant P.Byte_Array (1 .. 80) :=
      [others => P.Byte(Character'Pos('2'))];
    one         : constant P.Byte_Array := [P.Byte(Character'Pos('x'))];
    oversized   : constant P.Byte_Array (1 .. 129) := [others => 1];
    deferred_status : R.Deferred_Write_Status;
    old_identity : R.Request_Identity;
    new_identity : R.Request_Identity;
    end_1_position : Natural;
    end_2_position : Natural;
    end_bytes      : P.Byte_Array (0 .. M.END_REQUEST_BODY_LENGTH - 1);
    end_body       : M.End_Request_Body;
    body_status    : M.Body_Status;
  begin
    initialize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, application'Unchecked_Access,
       runtime_fd, peer_fd);

    encode_begin (begin_bytes);
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 2, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 1, P.PARAMS_TYPE, empty);
    append_record (input, position, 2, P.PARAMS_TYPE, empty);
    append_record (input, position, 1, P.STDIN_TYPE, stdin_byte);
    append_record (input, position, 1, P.STDIN_TYPE, empty);
    append_record (input, position, 2, P.STDIN_TYPE, empty);

    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred sibling requests write");

    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 2, expected_callbacks => 2);

    A.assert_true
      (reporter, application.defer_ok,
       "terminal callbacks defer successfully");
    A.assert_true
      (reporter, application.pre_defer_write_ok,
       "synchronous output before defer is preserved");
    A.assert_true
      (reporter, application.writer_closed_ok,
       "successful defer closes callback writer");
    A.assert_true
      (reporter,
       application.midstream_attempted and then
         application.midstream_not_allowed,
       "mid-stream responder callback cannot defer");
    A.assert_equal_natural
      (reporter, E.active_count(executor), 0,
       "deferred requests do not retain executor workers");
    A.assert_equal_natural
      (reporter, E.pending_count(executor), 0,
       "deferred requests do not retain executor queue entries");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 2,
       "deferred requests retain FastCGI admission slots");

    old_identity := R.identity(application.first_handle);
    A.assert_true
      (reporter,
       old_identity = RCT.current_identity(connection, 1),
       "deferred handle retains full current request identity");

    R.write_stdout (application.first_handle, oversized, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Output_Limit_Exceeded,
       "single deferred command larger than request capacity is rejected");

    R.write_stderr (application.second_handle, payload_2, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Write_Complete,
       "first deferred STDERR output is accepted");

    R.write_stdout (application.second_handle, one, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Would_Block,
       "second command on one deferred request backpressures");

    R.write_stdout (application.first_handle, payload_1, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Would_Block,
       "staged sibling output backpressures at the connection budget");

    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 2, expected_callbacks => 2);
    A.assert_true
      (reporter,
       record_position(output, output_length, 2, P.STDERR_TYPE) > 0,
       "deferred STDERR is encoded by the connection output path");

    R.write_stdout (application.first_handle, payload_1, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Write_Complete,
       "deferred producer proceeds after output drain");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 2, expected_callbacks => 2);

    R.finish (application.second_handle, 42, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Write_Complete,
       "request 2 deferred completion is accepted first");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 1, expected_callbacks => 2);

    R.finish (application.first_handle, 0, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Write_Complete,
       "request 1 deferred completion is accepted second");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 0, expected_callbacks => 2);

    end_2_position :=
      record_position (output, output_length, 2, P.END_REQUEST_TYPE);
    end_1_position :=
      record_position (output, output_length, 1, P.END_REQUEST_TYPE);
    A.assert_true
      (reporter,
       end_2_position > 0 and then end_1_position > end_2_position,
       "deferred completion order may differ from admission order");

    if end_2_position > 0 then
      for index in end_bytes'range loop
        end_bytes(index) :=
          output(end_2_position + P.HEADER_LENGTH + index);
      end loop;
      M.decode_end_request (end_bytes, end_body, body_status);
      A.assert_true
        (reporter, body_status = M.Body_Complete,
         "deferred END_REQUEST body decodes");
      A.assert_equal_integer
        (reporter, Integer(end_body.application_status), 42,
         "deferred finish preserves application status");
    else
      A.assert_true
        (reporter, False, "deferred END_REQUEST is available for status check");
    end if;

    status := E.signal_cancellation
      (executor, old_identity, R.Connection_Failure);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "late cancellation signal for completed generation is accepted");
    A.assert_true
      (reporter,
       R.cancellation_reason(application.first_handle) =
         R.Not_Cancelled and then
       not R.cancellation_requested(application.first_handle),
       "completed deferred tombstone ignores later cancellation causes");

    R.write_stdout (application.second_handle, one, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Closed,
       "completed deferred handle rejects late output");

    position := input'first;
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 1, P.PARAMS_TYPE, empty);
    append_record (input, position, 1, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reused request ID writes");

    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 1, expected_callbacks => 3);

    new_identity := R.identity(application.reused_first_handle);
    A.assert_true
      (reporter,
       not R.is_null(new_identity) and then
       new_identity.request_id = old_identity.request_id and then
       new_identity.generation /= old_identity.generation,
       "reused request ID receives a distinct deferred generation");

    R.write_stdout (application.first_handle, one, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Closed,
       "stale deferred generation cannot target reused request ID");

    R.finish (application.reused_first_handle, 0, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Write_Complete,
       "reused generation completes through its own handle");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 0, expected_callbacks => 3);

    finalize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, peer_fd);

    A.assert_true
      (reporter,
       R.cancellation_reason(application.first_handle) =
         R.Not_Cancelled and then
       not R.cancellation_requested(application.first_handle),
       "later executor shutdown does not rewrite a completed tombstone");
  end deferred_sibling_progress_and_reuse;

  procedure deferred_keepalive_sequential_reuse
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Deferred_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 1_024,
       max_output_bytes => 2_048, read_buffer_bytes => 1_024,
       write_chunk_bytes => 128);
    runtime_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    peer_fd    : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty       : P.Byte_Array (1 .. 0);
    params      : P.Byte_Array (1 .. 504);
    input       : P.Byte_Array (1 .. 640);
    position    : Positive := input'first;
    output      : P.Byte_Array (1 .. 65_536);
    output_length : Natural := 0;
    status      : Clair.Status.Code;
    deferred_status : R.Deferred_Write_Status;
    first_identity  : R.Request_Identity;
    reused_identity : R.Request_Identity;
  begin
    for pair in 0 .. 125 loop
      params(pair * 4 + 1) := 1;
      params(pair * 4 + 2) := 1;
      params(pair * 4 + 3) := P.Byte(Character'Pos('N'));
      params(pair * 4 + 4) := P.Byte(Character'Pos('V'));
    end loop;

    initialize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, application'Unchecked_Access, runtime_fd, peer_fd,
       executor_output_bytes => 2_048);
    start_single_deferred_request
      (reporter, event_loop, executor, connection, application, peer_fd,
       output, output_length);
    first_identity := R.identity(application.first_handle);
    R.finish (application.first_handle, 0, deferred_status);
    A.assert_true (reporter, deferred_status = R.Deferred_Write_Complete,
      "first keep-alive deferred finish is accepted");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 0, expected_callbacks => 1);

    encode_begin (begin_bytes);
    position := input'first;
    append_record (input, position, 2, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 2, P.PARAMS_TYPE, params);
    append_record (input, position, 2, P.PARAMS_TYPE, empty);
    append_record (input, position, 2, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true (reporter, status = Clair.Status.OK,
      "second keep-alive request writes");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 1, expected_callbacks => 2);
    A.assert_equal_natural
      (reporter, RC.pending_input_bytes(connection), 0,
       "following keep-alive PARAMS drain completely");
    A.assert_true
      (reporter, R.identity(application.second_handle).request_id = 2,
       "different request ID reaches deferred terminal callback");
    R.finish (application.second_handle, 0, deferred_status);
    A.assert_true (reporter, deferred_status = R.Deferred_Write_Complete,
      "second keep-alive deferred finish is accepted");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 0, expected_callbacks => 2);

    position := input'first;
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 1, P.PARAMS_TYPE, params);
    append_record (input, position, 1, P.PARAMS_TYPE, empty);
    append_record (input, position, 1, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true (reporter, status = Clair.Status.OK,
      "reused keep-alive request ID writes");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 1, expected_callbacks => 3);
    reused_identity := R.identity(application.reused_first_handle);
    A.assert_true
      (reporter, reused_identity.request_id = first_identity.request_id and then
       reused_identity.generation /= first_identity.generation,
       "keep-alive request ID reuse receives a fresh generation");
    R.finish (application.reused_first_handle, 0, deferred_status);
    A.assert_true (reporter, deferred_status = R.Deferred_Write_Complete,
      "reused keep-alive deferred finish is accepted");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 0, expected_callbacks => 3);
    finalize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, peer_fd);
  end deferred_keepalive_sequential_reuse;

  procedure deferred_large_stream_chunking
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Deferred_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 32_768,
       max_output_bytes => 32_768, read_buffer_bytes => 128,
       write_chunk_bytes => 4_096);
    runtime_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    peer_fd    : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    output     : P.Byte_Array (1 .. 65_536);
    output_length : Natural := 0;
    payload : constant P.Byte_Array
      (1 .. E.DEFERRED_OUTPUT_CHUNK_BYTES + 257) := [others => 16#5a#];
    deferred_status : R.Deferred_Write_Status;
    stdout_before : Natural;
  begin
    initialize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, application'Unchecked_Access, runtime_fd, peer_fd,
       executor_output_bytes => 32_768);
    start_single_deferred_request
      (reporter, event_loop, executor, connection, application, peer_fd,
       output, output_length);
    stdout_before := record_count(output, output_length, 1, P.STDOUT_TYPE);

    R.write_stdout (application.first_handle, payload, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Write_Complete,
       "large deferred STDOUT is accepted");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 1, expected_callbacks => 1);
    A.assert_equal_natural
      (reporter,
       record_count(output, output_length, 1, P.STDOUT_TYPE),
       stdout_before + 2,
       "large deferred STDOUT adds two bounded connection-owned records");

    R.finish (application.first_handle, 0, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Write_Complete,
       "large deferred request completes");
    R.write_stdout
      (application.first_handle, payload(payload'first .. payload'first),
       deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Closed,
       "accepted deferred finish closes further production immediately");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 0, expected_callbacks => 1);
    A.assert_equal_natural
      (reporter, record_count(output, output_length, 1, P.END_REQUEST_TYPE), 1,
       "large deferred request has one END_REQUEST");

    finalize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, peer_fd);
  end deferred_large_stream_chunking;

  procedure deferred_abort_cancellation
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Deferred_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 512,
       max_output_bytes => 1_024, read_buffer_bytes => 128,
       write_chunk_bytes => 64);
    runtime_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    peer_fd    : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    output     : P.Byte_Array (1 .. 4_096);
    output_length : Natural := 0;
    empty      : P.Byte_Array (1 .. 0);
    input      : P.Byte_Array (1 .. 32);
    position   : Positive := input'first;
    status     : Clair.Status.Code;
    deferred_status : R.Deferred_Write_Status;
    one        : constant P.Byte_Array := [P.Byte(Character'Pos('a'))];
  begin
    initialize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, application'Unchecked_Access, runtime_fd, peer_fd);
    start_single_deferred_request
      (reporter, event_loop, executor, connection, application,
       peer_fd, output, output_length);

    append_record (input, position, 1, P.ABORT_REQUEST_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "abort record for deferred request writes");
    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 0, expected_callbacks => 1);

    A.assert_true
      (reporter,
       R.cancellation_reason(application.first_handle) = R.Peer_Abort,
       "deferred handle observes peer abort");
    R.write_stdout (application.first_handle, one, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Closed,
       "aborted deferred request rejects late output");
    R.write_stdout (application.first_handle, empty, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Closed,
       "aborted deferred request also rejects empty late output");
    A.assert_equal_natural
      (reporter, record_count(output, output_length, 1, P.END_REQUEST_TYPE), 1,
       "abort emits exactly one END_REQUEST");

    finalize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, peer_fd);
  end deferred_abort_cancellation;

  procedure deferred_timeout_cancellation
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Deferred_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 512,
       max_output_bytes => 1_024, read_buffer_bytes => 128,
       write_chunk_bytes => 64);
    runtime_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    peer_fd    : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    output     : P.Byte_Array (1 .. 4_096);
    output_length : Natural := 0;
    deferred_status : R.Deferred_Write_Status;
    one        : constant P.Byte_Array := [P.Byte(Character'Pos('t'))];
  begin
    initialize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, application'Unchecked_Access, runtime_fd, peer_fd,
       request_timeout => 100);
    start_single_deferred_request
      (reporter, event_loop, executor, connection, application,
       peer_fd, output, output_length);

    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 0, expected_callbacks => 1);

    A.assert_true
      (reporter,
       R.cancellation_reason(application.first_handle) = R.Request_Timeout,
       "deferred handle observes request timeout");
    R.write_stdout (application.first_handle, one, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Closed,
       "timed-out deferred request rejects late output");
    A.assert_equal_natural
      (reporter, record_count(output, output_length, 1, P.END_REQUEST_TYPE), 1,
       "timeout emits exactly one END_REQUEST");

    finalize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, peer_fd);
  end deferred_timeout_cancellation;

  procedure deferred_connection_failure
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Deferred_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 512,
       max_output_bytes => 1_024, read_buffer_bytes => 128,
       write_chunk_bytes => 64);
    runtime_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    peer_fd    : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    output     : P.Byte_Array (1 .. 4_096);
    output_length : Natural := 0;
    status     : Clair.Status.Code;
    deferred_status : R.Deferred_Write_Status;
    one        : constant P.Byte_Array := [P.Byte(Character'Pos('f'))];
  begin
    initialize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, application'Unchecked_Access, runtime_fd, peer_fd);
    start_single_deferred_request
      (reporter, event_loop, executor, connection, application,
       peer_fd, output, output_length);

    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred peer closes to trigger connection failure");
    peer_fd := Clair.IO.INVALID_DESCRIPTOR;

    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 0, expected_callbacks => 1,
       read_peer => False);

    A.assert_false
      (reporter, RC.is_active(connection),
       "peer loss closes deferred FastCGI connection");
    A.assert_true
      (reporter,
       R.cancellation_reason(application.first_handle) = R.Connection_Failure,
       "deferred handle observes connection failure");
    R.write_stdout (application.first_handle, one, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Closed,
       "disconnected deferred request rejects late output");

    finalize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, peer_fd);
  end deferred_connection_failure;

  procedure deferred_shutdown_race
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Deferred_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 512,
       max_output_bytes => 1_024, read_buffer_bytes => 128,
       write_chunk_bytes => 64);
    runtime_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    peer_fd    : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    output     : P.Byte_Array (1 .. 4_096);
    output_length : Natural := 0;
    status     : Clair.Status.Code;
    deferred_status : R.Deferred_Write_Status;
  begin
    initialize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, application'Unchecked_Access, runtime_fd, peer_fd);
    start_single_deferred_request
      (reporter, event_loop, executor, connection, application,
       peer_fd, output, output_length);

    R.finish (application.first_handle, 0, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Write_Complete,
       "deferred completion can stage before shutdown");

    status := RC.begin_shutdown (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "connection shutdown starts with staged completion");
    A.assert_true
      (reporter,
       R.cancellation_reason(application.first_handle) = R.Runtime_Shutdown,
       "shutdown cancellation wins staged completion race");

    R.finish (application.first_handle, 0, deferred_status);
    A.assert_true
      (reporter, deferred_status = R.Deferred_Closed,
       "shutdown rejects late deferred completion");

    pump_deferred_state
      (reporter, event_loop, peer_fd, connection, executor, application,
       output, output_length, expected_active => 0, expected_callbacks => 1);

    A.assert_equal_natural
      (reporter, record_count(output, output_length, 1, P.END_REQUEST_TYPE), 1,
       "completion-versus-shutdown race emits one END_REQUEST");

    finalize_deferred_fixture
      (reporter, event_loop'Unchecked_Access, executor'Unchecked_Access,
       connection, peer_fd);
  end deferred_shutdown_race;

  procedure interleaving_and_generation
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Multiplex_Application;
    connection : aliased RC.Context
      (max_requests_per_connection => 2,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1024,
       max_output_bytes            => 2048,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 16);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    begin_bytes  : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty        : P.Byte_Array (1 .. 0);
    input        : P.Byte_Array (1 .. 256);
    position     : Positive := input'first;
    output       : P.Byte_Array (1 .. 8192);
    output_length : Natural := 0;
    identity_1a  : R.Request_Identity;
    identity_1b  : R.Request_Identity;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "multiplex socketpair is created");

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    discard_available (peer_fd);

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "multiplex loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 2,
       max_input_bytes  => 128,
       max_output_bytes => 1024);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "multiplex executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 1);
    A.assert_true
      (reporter, status = Clair.Status.OK, "multiplex connection initializes");

    encode_begin (begin_bytes);
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 2, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 1, P.PARAMS_TYPE, empty);
    append_record (input, position, 2, P.PARAMS_TYPE, empty);

    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "interleaved request prefixes write");

    pump
      (reporter, event_loop, peer_fd, connection,
       output, output_length, until_idle => False);

    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 2,
       "two request IDs are active on one connection");

    identity_1a := RCT.current_identity (connection, 1);
    A.assert_true
      (reporter,
       not R.is_null(identity_1a),
       "request 1 has a generation identity");
    A.assert_true
      (reporter, RC.request_is_current(connection, identity_1a),
       "request 1 generation is current");

    position := input'first;
    append_record (input, position, 2, P.STDIN_TYPE, empty);
    append_record (input, position, 1, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "out-of-order completion records write");

    pump
      (reporter, event_loop, peer_fd, connection,
       output, output_length, until_idle => True);

    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "both multiplexed requests retire after END_REQUEST drain");
    A.assert_true
      (reporter, application.write_ok, "multiplex application output succeeds");
    inspect_completed_output (reporter, output, output_length);
    A.assert_false
      (reporter, RC.request_is_current(connection, identity_1a),
       "retired generation is no longer current");

    output_length := 0;
    application.completions := 0;
    position := input'first;
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 1, P.PARAMS_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "reused request ID begins");

    pump
      (reporter, event_loop, peer_fd, connection,
       output, output_length, until_idle => False);

    identity_1b := RCT.current_identity (connection, 1);
    A.assert_true
      (reporter,
       not R.is_null(identity_1b),
       "reused request ID has an identity");
    A.assert_true
      (reporter,
       identity_1b.generation /= identity_1a.generation,
       "request ID reuse receives a new generation");
    A.assert_false
      (reporter, RC.request_is_current(connection, identity_1a),
       "stale generation cannot target reused request ID");
    A.assert_true
      (reporter, RC.request_is_current(connection, identity_1b),
       "new generation is current");

    position := input'first;
    append_record (input, position, 1, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "reused request completes");

    pump
      (reporter, event_loop, peer_fd, connection,
       output, output_length, until_idle => True);

    status := RC.finalize (connection);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "multiplex connection finalizes");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "multiplex executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "multiplex executor finalizes");

    status := Clair.IO.close (peer_fd);
    A.assert_true (reporter, status = Clair.Status.OK, "multiplex peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "multiplex loop finalizes");
  end interleaving_and_generation;

  procedure non_keep_conn_waits_for_sibling
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor : aliased E.Context;
    application : aliased Multiplex_Application;
    connection : aliased RC.Context
      (max_requests_per_connection => 2, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 512,
       max_output_bytes => 1_024, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    close_begin : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    keep_begin : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty : P.Byte_Array (1 .. 0);
    input : P.Byte_Array (1 .. 128);
    position : Positive := input'first;
    output : P.Byte_Array (1 .. 1_024);
    output_length : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "close sibling socketpair is created");
    if native_error /= 0 then return; end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    discard_available (peer_fd);
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "close sibling loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 2, 128, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "close sibling executor initializes");
    status := RC.initialize
      (connection, event_loop'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000, 33);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "close sibling connection initializes");

    encode_begin (close_begin, flags => 0);
    encode_begin (keep_begin);
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, close_begin);
    append_record (input, position, 2, P.BEGIN_REQUEST_TYPE, keep_begin);
    append_record (input, position, 1, P.PARAMS_TYPE, empty);
    append_record (input, position, 2, P.PARAMS_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK, "close sibling prefixes write");
    pump
      (reporter, event_loop, peer_fd, connection, output, output_length,
       until_idle => False);
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 2,
       "close sibling fixture has two active requests");

    position := input'first;
    append_record (input, position, 1, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "non-KEEP request completion writes");
    for iteration in 1 .. 120 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (event_loop, 20, dispatched);
      read_available (peer_fd, output, output_length);
      exit when status /= Clair.Status.OK or else
        (RC.active_request_count(connection) = 1 and then
         RC.pending_output_bytes(connection) = 0);
    end loop;
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "non-KEEP completion dispatch succeeds");
    A.assert_true
      (reporter, RC.is_active(connection),
       "non-KEEP completion does not truncate active sibling");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 1,
       "sibling remains active after non-KEEP request completes");
    A.assert_equal_natural
      (reporter, record_count(output, output_length, 1, P.END_REQUEST_TYPE), 1,
       "non-KEEP request completion reaches peer before close");

    position := input'first;
    append_record (input, position, 2, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "remaining sibling completion writes");
    for iteration in 1 .. 120 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (event_loop, 20, dispatched);
      read_available (peer_fd, output, output_length);
      exit when status /= Clair.Status.OK or else not RC.is_active(connection);
    end loop;
    read_available (peer_fd, output, output_length);
    A.assert_false
      (reporter, RC.is_active(connection),
       "transport closes only after final sibling completes and drains");
    A.assert_equal_natural
      (reporter, record_count(output, output_length, 2, P.END_REQUEST_TYPE), 1,
       "remaining sibling is not truncated by close intent");
    A.assert_equal_natural
      (reporter, application.completions, 2,
       "both application requests complete before transport close");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "close sibling connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "close sibling executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "close sibling executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "close sibling peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "close sibling loop finalizes");
  end non_keep_conn_waits_for_sibling;

  procedure resource_limit_preserves_sibling
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor : aliased E.Context;
    application : aliased Multiplex_Application;
    connection : aliased RC.Context
      (max_requests_per_connection => 2, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 512,
       max_output_bytes => 1_024, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty : P.Byte_Array (1 .. 0);
    over_limit : constant P.Byte_Array := [1, 2, 3, 4, 5];
    input : P.Byte_Array (1 .. 160);
    position : Positive := input'first;
    output : P.Byte_Array (1 .. 1_024);
    output_length : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "resource sibling socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    discard_available (peer_fd);
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "resource sibling loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 2, 128, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "resource sibling executor initializes");
    status := RC.initialize
      (self => connection, event_loop => event_loop'Unchecked_Access,
       fd => runtime_fd, handler => application'Unchecked_Access,
       executor => executor'Unchecked_Access, request_timeout => 60_000,
       connection_id => 34,
       input_limits => (max_params_bytes => 4, max_stdin_bytes => 64,
                        max_data_bytes => 64));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "resource sibling connection initializes");

    encode_begin (begin_bytes);
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 2, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 1, P.PARAMS_TYPE, over_limit);
    append_record (input, position, 2, P.PARAMS_TYPE, empty);
    append_record (input, position, 2, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK, "resource sibling input writes");
    pump
      (reporter, event_loop, peer_fd, connection, output, output_length,
       until_idle => True);

    A.assert_equal_natural
      (reporter, application.completions, 1,
       "resource-limited request does not suppress sibling application");
    A.assert_equal_natural
      (reporter, record_count(output, output_length, 1, P.END_REQUEST_TYPE), 1,
       "resource-limited request emits END_REQUEST");
    A.assert_equal_natural
      (reporter, record_count(output, output_length, 2, P.END_REQUEST_TYPE), 1,
       "resource-limit sibling emits END_REQUEST");
    A.assert_positive
      (reporter,
       Integer(record_count(output, output_length, 2, P.STDOUT_TYPE)),
       "resource-limit sibling still emits STDOUT");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "resource-limit and sibling requests retire independently");
    A.assert_true
      (reporter, RC.is_active(connection),
       "resource-limit request preserves KEEP_CONN sibling transport");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "resource sibling connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "resource sibling executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "resource sibling executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "resource sibling peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "resource sibling loop finalizes");
  end resource_limit_preserves_sibling;

  procedure abort_preserves_sibling
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor : aliased E.Context;
    application : aliased Multiplex_Application;
    connection : aliased RC.Context
      (max_requests_per_connection => 2, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 512,
       max_output_bytes => 1_024, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty : P.Byte_Array (1 .. 0);
    input : P.Byte_Array (1 .. 128);
    position : Positive := input'first;
    output : P.Byte_Array (1 .. 1_024);
    output_length : Natural := 0;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "abort sibling socketpair is created");
    if native_error /= 0 then return; end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    discard_available (peer_fd);
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "abort sibling loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 2, 128, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "abort sibling executor initializes");
    status := RC.initialize
      (connection, event_loop'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000, 32);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "abort sibling connection initializes");

    encode_begin (begin_bytes);
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 2, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 1, P.PARAMS_TYPE, empty);
    append_record (input, position, 2, P.PARAMS_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK, "abort sibling prefixes write");
    pump
      (reporter, event_loop, peer_fd, connection, output, output_length,
       until_idle => False);
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 2,
       "abort sibling fixture has two active requests");

    position := input'first;
    append_record (input, position, 1, P.ABORT_REQUEST_TYPE, empty);
    append_record (input, position, 2, P.STDIN_TYPE, empty);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "abort and sibling completion write");
    pump
      (reporter, event_loop, peer_fd, connection, output, output_length,
       until_idle => True);

    A.assert_equal_natural
      (reporter, application.completions, 1,
       "aborting one request does not suppress sibling application work");
    A.assert_equal_natural
      (reporter, record_count(output, output_length, 1, P.END_REQUEST_TYPE), 1,
       "aborted request emits one END_REQUEST");
    A.assert_equal_natural
      (reporter, record_count(output, output_length, 2, P.END_REQUEST_TYPE), 1,
       "sibling request emits one END_REQUEST");
    A.assert_positive
      (reporter,
       Integer(record_count(output, output_length, 2, P.STDOUT_TYPE)),
       "sibling request still emits STDOUT");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "abort and sibling completion retire independently");
    A.assert_true
      (reporter, RC.is_active(connection),
       "KEEP_CONN transport survives one-request abort");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "abort sibling connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "abort sibling executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "abort sibling executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "abort sibling peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "abort sibling loop finalizes");
  end abort_preserves_sibling;

  procedure connection_fatal_terminates_siblings
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Multiplex_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 2, max_name_bytes => 64,
       max_value_bytes => 64, max_request_output_bytes => 512,
       max_output_bytes => 1_024, read_buffer_bytes => 64,
       write_chunk_bytes => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    input : P.Byte_Array (1 .. 64);
    position : Positive := input'first;
    malformed : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "fatal socketpair is created");
    if native_error /= 0 then return; end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    discard_available (peer_fd);
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "fatal loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 2, 128, 1_024);
    A.assert_true
      (reporter, status = Clair.Status.OK, "fatal executor initializes");
    status := RC.initialize
      (connection, event_loop'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000, 31);
    A.assert_true
      (reporter, status = Clair.Status.OK, "fatal connection initializes");
    encode_begin (begin_bytes);
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 2, P.BEGIN_REQUEST_TYPE, begin_bytes);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true (reporter, status = Clair.Status.OK, "siblings begin");
    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (event_loop, 20, dispatched);
      exit when status /= Clair.Status.OK or else
        RC.active_request_count(connection) = 2;
    end loop;
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 2,
       "two siblings are active before connection-fatal input");
    C.encode_header
      ((version => 2, record_type => P.PARAMS_TYPE, request_id => 1,
        content_length => 0, padding_length => 0, reserved => 0), malformed);
    status := write_all (peer_fd, malformed);
    A.assert_true
      (reporter, status = Clair.Status.OK, "fatal header writes");
    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (event_loop, 20, dispatched);
      exit when status /= Clair.Status.OK or else not RC.is_active(connection);
    end loop;
    A.assert_false
      (reporter, RC.is_active(connection),
       "protocol framing failure closes transport");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 0,
       "connection-fatal failure retires every sibling");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK, "fatal connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "fatal executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "fatal executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK, "fatal peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "fatal loop finalizes");
  end connection_fatal_terminates_siblings;

  procedure capacity_refusal
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Multiplex_Application;
    connection : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 512,
       max_output_bytes            => 1024,
       read_buffer_bytes           => 64,
       write_chunk_bytes           => 64);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw    : aliased Interfaces.C.int := -1;
    runtime_fd  : Clair.IO.Descriptor;
    peer_fd     : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    begin_bytes  : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    input        : P.Byte_Array (1 .. 128);
    position     : Positive := input'first;
    output       : P.Byte_Array (1 .. 1024);
    output_length : Natural := 0;
    header_bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    record_header : P.Header;
    decode_status : C.Decode_Status;
    end_bytes : P.Byte_Array (0 .. M.END_REQUEST_BODY_LENGTH - 1);
    end_body : M.End_Request_Body;
    body_status : M.Body_Status;
  begin
    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0, "capacity socketpair is created");

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    discard_available (peer_fd);

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "capacity loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 2,
       max_input_bytes  => 128,
       max_output_bytes => 1024);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "capacity executor initializes");

    status := RC.initialize
      (self            => connection,
       event_loop      => event_loop'Unchecked_Access,
       fd              => runtime_fd,
       handler         => application'Unchecked_Access,
       executor        => executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 2);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity connection initializes");

    encode_begin (begin_bytes);
    append_record (input, position, 1, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record (input, position, 2, P.BEGIN_REQUEST_TYPE, begin_bytes);
    status := write_all (peer_fd, input(input'first .. position - 1));
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "over-capacity BEGIN_REQUEST writes");

    for iteration in 1 .. 50 loop
      declare
        dispatched : Boolean;
      begin
        status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
        A.assert_true
          (reporter,
           status = Clair.Status.OK,
           "capacity event-loop iteration succeeds");
        read_available (peer_fd, output, output_length);
        exit when output_length >= P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH;
      end;
    end loop;

    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 1,
       "per-connection request limit is enforced");
    A.assert_true
      (reporter,
       output_length >= P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH,
       "multiplex refusal emits END_REQUEST");

    for index in header_bytes'range loop
      header_bytes(index) := output(output'first + index);
    end loop;
    C.decode_header (header_bytes, record_header, decode_status);

    A.assert_true
      (reporter, decode_status = C.Complete, "refusal header decodes");
    A.assert_equal_integer
      (reporter, Integer(record_header.request_id), 2,
       "refusal targets rejected request ID");
    A.assert_equal_integer
      (reporter,
       Integer(record_header.record_type),
       Integer(P.END_REQUEST_TYPE),
       "refusal uses END_REQUEST");

    for index in end_bytes'range loop
      end_bytes(index) := output(output'first + P.HEADER_LENGTH + index);
    end loop;
    M.decode_end_request (end_bytes, end_body, body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete,
       "refusal body decodes");
    A.assert_equal_integer
      (reporter,
       Integer(end_body.protocol_status_code),
       Integer(P.CANT_MPX_CONN_STATUS),
       "refusal reports CANT_MPX_CONN");

    status := RC.finalize (connection);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "capacity connection finalizes");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "capacity executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "capacity executor finalizes");

    status := Clair.IO.close (peer_fd);
    A.assert_true (reporter, status = Clair.Status.OK, "capacity peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "capacity loop finalizes");
  end capacity_refusal;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred sibling progress and generation reuse",
       deferred_sibling_progress_and_reuse'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred keep-alive sequential reuse",
       deferred_keepalive_sequential_reuse'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred large stream chunking",
       deferred_large_stream_chunking'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred abort cancellation",
       deferred_abort_cancellation'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred timeout cancellation",
       deferred_timeout_cancellation'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred connection failure",
       deferred_connection_failure'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred shutdown completion race",
       deferred_shutdown_race'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "interleaving and request generation",
       interleaving_and_generation'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "non-KEEP connection waits for sibling",
       non_keep_conn_waits_for_sibling'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "resource limit preserves sibling",
       resource_limit_preserves_sibling'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "abort preserves sibling",
       abort_preserves_sibling'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "connection-fatal failure terminates siblings",
       connection_fatal_terminates_siblings'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "multiplex capacity refusal",
       capacity_refusal'access);
  end run;

end Tests.Multiplexing;
