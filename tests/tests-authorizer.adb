-- ============================================================================
-- tests-authorizer.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Characters.Latin_1;
with Interfaces;
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
with Fasyn.Protocol.Name_Values;
with Fasyn.Request;
with Fasyn.Request.Connection;
with Fasyn.Request.Execution;
with Fasyn.Request.Testing;

package body Tests.Authorizer is

  package L1 renames Ada.Characters.Latin_1;
  package A renames Clair.Test.Assertions;
  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package M renames Fasyn.Protocol.Messages;
  package N renames Fasyn.Protocol.Name_Values;
  package R renames Fasyn.Request;
  package RC renames Fasyn.Request.Connection;
  package E renames Fasyn.Request.Execution;
  package RT renames Fasyn.Request.Testing;

  use type Interfaces.C.int;
  use type Interfaces.Unsigned_8;
  use type Interfaces.Unsigned_16;
  use type Interfaces.Unsigned_32;
  use type Clair.IO.Byte_Count;
  use type Clair.Status.Code;
  use type C.Decode_Status;
  use type M.Body_Status;
  use type N.Encode_Status;
  use type P.Role;
  use type R.Input_Status;
  use type R.Write_Status;
  use type System.Storage_Elements.Storage_Offset;

  function c_socketpair
    (runtime_fd : access Interfaces.C.int;
     peer_fd    : access Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_socketpair";

  function to_bytes (text : String) return P.Byte_Array is
    result : P.Byte_Array (1 .. text'length);
  begin
    for offset in 0 .. text'length - 1 loop
      result(offset + 1) :=
        P.Byte(Character'Pos(text(text'first + offset)));
    end loop;
    return result;
  end to_bytes;

  AUTHORIZED_RESPONSE : constant P.Byte_Array :=
    to_bytes
      ("Status: 200 OK" & L1.CR & L1.LF &
       "Variable-AUTH_METHOD: database lookup" & L1.CR & L1.LF &
       L1.CR & L1.LF);

  type Authorizer_Application is new R.Application with record
    parameter_count      : Natural := 0;
    params_end_seen      : Boolean := False;
    stdin_seen           : Boolean := False;
    role_seen            : P.Role := P.Responder;
    finish_on_params_end : Boolean := True;
    application_status   : Interfaces.Unsigned_32 := 0;
    output_ok            : Boolean := True;
  end record;

  overriding procedure on_parameter
    (self    : in out Authorizer_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Authorizer_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Authorizer_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Authorizer_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Authorizer_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (name, value);
  begin
    self.parameter_count := self.parameter_count + 1;
    self.role_seen := R.request_role(context);
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Authorizer_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    write_status  : R.Write_Status;
    finish_status : R.Write_Status;
  begin
    self.params_end_seen := True;
    self.role_seen := R.request_role(context);

    if not self.finish_on_params_end then
      return;
    end if;

    R.write_stdout (response, AUTHORIZED_RESPONSE, write_status);
    R.finish (response, self.application_status, finish_status);
    self.output_ok :=
      write_status = R.Write_Complete and then
      finish_status = R.Write_Complete;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Authorizer_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, data, response);
  begin
    self.stdin_seen := True;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Authorizer_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.stdin_seen := True;
  end on_stdin_end;

  procedure encode_begin
    (role_code : Interfaces.Unsigned_16;
     output    : out P.Byte_Array)
  is
    request_body : constant M.Begin_Request_Body :=
      (role_code => role_code,
       flags     => P.KEEP_CONN);
    written : Natural;
    status  : M.Body_Status;
  begin
    M.encode_begin_request
      (request_body, output, written, status);

    if status /= M.Body_Complete or else
       written /= M.BEGIN_REQUEST_BODY_LENGTH
    then
      raise Program_Error with "Authorizer BEGIN_REQUEST encoding failed";
    end if;
  end encode_begin;

  procedure encode_parameter
    (output  : out P.Byte_Array;
     written : out Natural)
  is
    name   : constant P.Byte_Array := to_bytes ("REMOTE_USER");
    value  : constant P.Byte_Array := to_bytes ("alice");
    status : N.Encode_Status;
  begin
    N.encode_pair (name, value, output, written, status);
    if status /= N.Encode_Complete then
      raise Program_Error with "Authorizer PARAMS encoding failed";
    end if;
  end encode_parameter;

  procedure drive_record
    (exchange    : in out R.Exchange;
     application : in out Authorizer_Application;
     response    : in out R.Writer;
     record_type : P.Byte;
     content     : P.Byte_Array;
     status      : out R.Input_Status)
  is
    header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => 1,
       content_length => P.Content_Length_Type(content'length),
       padding_length => 0,
       reserved       => 0);
  begin
    R.begin_record (exchange, header, response, status);
    if status /= R.Input_Progress then
      return;
    end if;

    if content'length > 0 then
      R.feed_content
        (exchange, content, application, response, status);
      if status /= R.Input_Progress then
        return;
      end if;
    end if;

    R.end_record (exchange, application, response, status);
  end drive_record;

  procedure append_record
    (buffer      : in out P.Byte_Array;
     position    : in out Positive;
     record_type : P.Byte;
     content     : P.Byte_Array)
  is
    header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => 1,
       content_length => P.Content_Length_Type(content'length),
       padding_length => 0,
       reserved       => 0);
    bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
  begin
    C.encode_header (header, bytes);

    for index in bytes'range loop
      buffer(position) := bytes(index);
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

  function drain_peer (fd : Clair.IO.Descriptor) return Natural is
    storage : System.Storage_Elements.Storage_Array (1 .. 8192);
    count   : Clair.IO.Byte_Count;
    status  : Clair.Status.Code;
    total   : Natural := 0;
  begin
    loop
      status := Clair.IO.read (fd, storage, count);
      if status = Clair.Status.OK then
        exit when count = 0;
        total := total + Natural(count);
      elsif Clair.IO.Posix.is_would_block(status) then
        exit;
      else
        exit;
      end if;
    end loop;

    return total;
  end drain_peer;

  procedure read_available
    (fd     : Clair.IO.Descriptor;
     output : in out P.Byte_Array;
     length : in out Natural)
  is
    storage : System.Storage_Elements.Storage_Array (1 .. 2048);
    count   : Clair.IO.Byte_Count;
    status  : Clair.Status.Code;
  begin
    loop
      status := Clair.IO.read (fd, storage, count);
      if status = Clair.Status.OK then
        exit when count = 0;

        if length + Natural(count) > output'length then
          raise Program_Error with "Authorizer output buffer overflow";
        end if;

        for offset in 0 .. Natural(count) - 1 loop
          length := length + 1;
          output(output'first + length - 1) :=
            P.Byte
              (storage
                 (storage'first +
                  System.Storage_Elements.Storage_Offset(offset)));
        end loop;
      elsif Clair.IO.Posix.is_would_block(status) then
        exit;
      else
        exit;
      end if;
    end loop;
  end read_available;

  procedure decode_header_at
    (output        : P.Byte_Array;
     length        : Natural;
     position      : Natural;
     header        : out P.Header;
     decode_status : out C.Decode_Status)
  is
    bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
  begin
    if position + P.HEADER_LENGTH - 1 >
         output'first + length - 1
    then
      decode_status := C.Need_More_Data;
      return;
    end if;

    for offset in bytes'range loop
      bytes(offset) := output(position + offset);
    end loop;
    C.decode_header (bytes, header, decode_status);
  end decode_header_at;

  procedure runtime_authorizer_success
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Authorizer_Application;
    connection  : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 512,
       max_output_bytes            => 512,
       read_buffer_bytes           => 128,
       write_chunk_bytes           => 128);
    runtime_raw   : aliased Interfaces.C.int := -1;
    peer_raw      : aliased Interfaces.C.int := -1;
    runtime_fd    : Clair.IO.Descriptor;
    peer_fd       : Clair.IO.Descriptor;
    native_error  : Interfaces.C.int;
    status        : Clair.Status.Code;
    dispatched    : Boolean;
    begin_bytes   : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    params        : P.Byte_Array (1 .. 64);
    params_written : Natural;
    empty         : P.Byte_Array (1 .. 0);
    input         : P.Byte_Array (1 .. 128);
    input_position : Positive := input'first;
    output        : P.Byte_Array (1 .. 512);
    output_length : Natural := 0;
    position      : Natural;
    header        : P.Header;
    decode_status : C.Decode_Status;
    body_bytes    : P.Byte_Array (0 .. M.END_REQUEST_BODY_LENGTH - 1);
    end_body      : M.End_Request_Body;
    body_status   : M.Body_Status;
    content_ok    : Boolean := True;
  begin
    encode_begin (P.AUTHORIZER_ROLE, begin_bytes);
    encode_parameter (params, params_written);

    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "Authorizer socketpair is created");

    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_true
      (reporter, drain_peer(peer_fd) > 0,
       "Authorizer socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Authorizer event loop initializes");

    status := E.initialize
      (executor,
       event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 128,
       max_output_bytes => 512);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Authorizer executor initializes");

    status := RC.initialize
      (connection,
       event_loop'Unchecked_Access,
       runtime_fd,
       application'Unchecked_Access,
       executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 30);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Authorizer connection initializes");

    append_record
      (input, input_position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record
      (input,
       input_position,
       P.PARAMS_TYPE,
       params(params'first .. params'first + params_written - 1));
    append_record
      (input, input_position, P.PARAMS_TYPE, empty);

    status := write_all
      (peer_fd, input(input'first .. input_position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Authorizer request is written");

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      exit when status /= Clair.Status.OK;
      read_available (peer_fd, output, output_length);
      exit when
        RC.active_request_count(connection) = 0 and then
        RC.pending_output_bytes(connection) = 0 and then
        output_length > 0;
    end loop;

    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Authorizer runtime dispatch succeeds");
    A.assert_equal_natural
      (reporter, application.parameter_count, 1,
       "Authorizer receives PARAMS");
    A.assert_true
      (reporter, application.params_end_seen,
       "Authorizer receives PARAMS EOF");
    A.assert_true
      (reporter, application.role_seen = P.Authorizer,
       "Authorizer callback context exposes role");
    A.assert_false
      (reporter, application.stdin_seen,
       "Authorizer does not receive STDIN callbacks");
    A.assert_true
      (reporter, application.output_ok,
       "Authorizer output finalizes");

    position := output'first;
    decode_header_at
      (output, output_length, position, header, decode_status);
    A.assert_true
      (reporter,
       decode_status = C.Complete and then
       header.record_type = P.STDOUT_TYPE and then
       Natural(header.content_length) = AUTHORIZED_RESPONSE'length,
       "Authorizer emits CGI response on STDOUT");

    if decode_status = C.Complete and then
       Natural(header.content_length) = AUTHORIZED_RESPONSE'length and then
       position + P.HEADER_LENGTH + AUTHORIZED_RESPONSE'length - 1 <=
         output'first + output_length - 1
    then
      for offset in 0 .. AUTHORIZED_RESPONSE'length - 1 loop
        if output(position + P.HEADER_LENGTH + offset) /=
             AUTHORIZED_RESPONSE(AUTHORIZED_RESPONSE'first + offset)
        then
          content_ok := False;
        end if;
      end loop;
    else
      content_ok := False;
    end if;

    A.assert_true
      (reporter, content_ok,
       "Authorizer CGI response bytes are preserved");
    position :=
      position + P.HEADER_LENGTH + AUTHORIZED_RESPONSE'length;

    decode_header_at
      (output, output_length, position, header, decode_status);
    A.assert_true
      (reporter,
       decode_status = C.Complete and then
       header.record_type = P.STDOUT_TYPE and then
       header.content_length = 0,
       "Authorizer finish emits STDOUT EOF");
    position := position + P.HEADER_LENGTH;

    decode_header_at
      (output, output_length, position, header, decode_status);
    A.assert_true
      (reporter,
       decode_status = C.Complete and then
       header.record_type = P.STDERR_TYPE and then
       header.content_length = 0,
       "Authorizer finish emits STDERR EOF");
    position := position + P.HEADER_LENGTH;

    decode_header_at
      (output, output_length, position, header, decode_status);
    A.assert_true
      (reporter,
       decode_status = C.Complete and then
       header.record_type = P.END_REQUEST_TYPE and then
       Natural(header.content_length) = M.END_REQUEST_BODY_LENGTH,
       "Authorizer finish emits END_REQUEST");

    if decode_status = C.Complete and then
       position + P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH - 1 <=
         output'first + output_length - 1
    then
      for offset in body_bytes'range loop
        body_bytes(offset) :=
          output(position + P.HEADER_LENGTH + offset);
      end loop;
      M.decode_end_request (body_bytes, end_body, body_status);
    else
      body_status := M.Invalid_Body_Length;
    end if;

    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       end_body.application_status = 0 and then
       end_body.protocol_status_code = P.REQUEST_COMPLETE_STATUS,
       "Authorizer completes with REQUEST_COMPLETE");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Authorizer connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Authorizer executor begins shutdown");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Authorizer executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Authorizer peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Authorizer event loop finalizes");
  end runtime_authorizer_success;

  procedure authorizer_rejects_stdin
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange
      (max_name_bytes => 64, max_value_bytes => 64);
    application : Authorizer_Application;
    response : R.Writer (max_output_bytes => 256);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty : P.Byte_Array (1 .. 0);
    status : R.Input_Status;
  begin
    application.finish_on_params_end := False;
    encode_begin (P.AUTHORIZER_ROLE, begin_bytes);

    drive_record
      (exchange, application, response,
       P.BEGIN_REQUEST_TYPE, begin_bytes, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "Authorizer BEGIN_REQUEST is accepted");

    drive_record
      (exchange, application, response,
       P.PARAMS_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "Authorizer PARAMS EOF completes input");
    A.assert_true
      (reporter, application.role_seen = P.Authorizer,
       "direct Authorizer callback exposes role");

    drive_record
      (exchange, application, response,
       P.STDIN_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Invalid_Record_Type,
       "Authorizer rejects FCGI_STDIN");
    A.assert_false
      (reporter, application.stdin_seen,
       "rejected Authorizer STDIN is not delivered");
  end authorizer_rejects_stdin;

  procedure authorizer_application_status
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange
      (max_name_bytes => 64, max_value_bytes => 64);
    application : Authorizer_Application;
    response : R.Writer (max_output_bytes => 256);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty : P.Byte_Array (1 .. 0);
    status : R.Input_Status;
  begin
    application.application_status := 9;
    encode_begin (P.AUTHORIZER_ROLE, begin_bytes);

    drive_record
      (exchange, application, response,
       P.BEGIN_REQUEST_TYPE, begin_bytes, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "application-status Authorizer begins");

    drive_record
      (exchange, application, response,
       P.PARAMS_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Request_Complete,
       "Authorizer may complete at PARAMS EOF");

    declare
      output : P.Byte_Array (1 .. RT.output_length(response));
      position : Natural := 1;
      bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
      header : P.Header;
      decode_status : C.Decode_Status;
      body_bytes : P.Byte_Array (0 .. M.END_REQUEST_BODY_LENGTH - 1);
      end_body : M.End_Request_Body;
      body_status : M.Body_Status;
      end_seen : Boolean := False;
    begin
      for index in output'range loop
        output(index) := RT.output_byte (response, index);
      end loop;

      while position <= output'last loop
        for offset in bytes'range loop
          bytes(offset) := output(position + offset);
        end loop;
        C.decode_header (bytes, header, decode_status);
        A.assert_true
          (reporter, decode_status = C.Complete,
           "Authorizer direct output header decodes");

        if decode_status /= C.Complete then
          exit;
        end if;

        if header.record_type = P.END_REQUEST_TYPE then
          for offset in body_bytes'range loop
            body_bytes(offset) :=
              output(position + P.HEADER_LENGTH + offset);
          end loop;
          M.decode_end_request (body_bytes, end_body, body_status);
          end_seen :=
            body_status = M.Body_Complete and then
            end_body.application_status = 9 and then
            end_body.protocol_status_code = P.REQUEST_COMPLETE_STATUS;
          exit;
        end if;

        position :=
          position + P.HEADER_LENGTH +
          Natural(header.content_length) +
          Natural(header.padding_length);
      end loop;

      A.assert_true
        (reporter, end_seen,
         "Authorizer application status is preserved");
    end;
  end authorizer_application_status;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "runtime Authorizer success",
       runtime_authorizer_success'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "Authorizer rejects STDIN",
       authorizer_rejects_stdin'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "Authorizer application status",
       authorizer_application_status'access);
  end run;

end Tests.Authorizer;
