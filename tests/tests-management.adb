-- ============================================================================
-- tests-management.adb
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
with Fasyn.Protocol.Name_Values;
with Fasyn.Request;
with Fasyn.Request.Admission;
with Fasyn.Request.Connection;
with Fasyn.Request.Execution;

package body Tests.Management is

  package A renames Clair.Test.Assertions;
  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package M renames Fasyn.Protocol.Messages;
  package N renames Fasyn.Protocol.Name_Values;
  package R renames Fasyn.Request;
  package RA renames Fasyn.Request.Admission;
  package RC renames Fasyn.Request.Connection;
  package E renames Fasyn.Request.Execution;

  use type Interfaces.C.int;
  use type Clair.IO.Byte_Count;
  use type Clair.Status.Code;
  use type C.Decode_Status;
  use type M.Body_Status;
  use type N.Encode_Status;
  use type N.Feed_Status;
  use type P.Byte;
  use type P.Request_Id_Type;
  use type System.Storage_Elements.Storage_Offset;

  function c_socketpair
    (runtime_fd : access Interfaces.C.int;
     peer_fd    : access Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_socketpair";

  type Null_Application is new R.Application with record
    callback_count : Natural := 0;
  end record;

  overriding procedure on_parameter
    (self    : in out Null_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Null_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Null_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Null_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Null_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (context, name, value);
  begin
    self.callback_count := self.callback_count + 1;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Null_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.callback_count := self.callback_count + 1;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Null_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, data, response);
  begin
    self.callback_count := self.callback_count + 1;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Null_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.callback_count := self.callback_count + 1;
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
    (buffer   : in out P.Byte_Array;
     position : in out Positive;
     name     : String)
  is
    name_bytes : constant P.Byte_Array := to_bytes(name);
    empty      : P.Byte_Array (1 .. 0);
    encoded    : P.Byte_Array
      (1 .. N.encoded_size(name_bytes'length, 0));
    written : Natural;
    status  : N.Encode_Status;
  begin
    N.encode_pair
      (name_bytes, empty, encoded, written, status);

    if status /= N.Encode_Complete or else
       position + written - 1 > buffer'last
    then
      raise Program_Error with "management query pair encoding failed";
    end if;

    for offset in 0 .. written - 1 loop
      buffer(position + offset) := encoded(encoded'first + offset);
    end loop;
    position := position + written;
  end append_pair;

  procedure append_record
    (buffer      : in out P.Byte_Array;
     position    : in out Positive;
     record_type : P.Byte;
     request_id  : P.Request_Id_Type;
     content     : P.Byte_Array)
  is
    header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => request_id,
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

  procedure read_peer
    (fd     : Clair.IO.Descriptor;
     output : in out P.Byte_Array;
     length : in out Natural)
  is
    storage : System.Storage_Elements.Storage_Array (1 .. 1024);
    count   : Clair.IO.Byte_Count;
    status  : Clair.Status.Code;
  begin
    loop
      status := Clair.IO.read (fd, storage, count);
      if status = Clair.Status.OK then
        exit when count = 0;

        if length + Natural(count) > output'length then
          raise Program_Error with "management test output overflow";
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
  end read_peer;

  function pair_matches
    (decoder : N.Decoder;
     name    : String;
     value   : String) return Boolean
  is
  begin
    if N.name_length(decoder) /= name'length or else
       N.value_length(decoder) /= value'length
    then
      return False;
    end if;

    for offset in 0 .. name'length - 1 loop
      if N.name_byte(decoder, offset + 1) /=
           P.Byte(Character'Pos(name(name'first + offset)))
      then
        return False;
      end if;
    end loop;

    for offset in 0 .. value'length - 1 loop
      if N.value_byte(decoder, offset + 1) /=
           P.Byte(Character'Pos(value(value'first + offset)))
      then
        return False;
      end if;
    end loop;

    return True;
  end pair_matches;

  procedure admission_accounting
    (reporter : in out Clair.Test.Reporter.Context)
  is
    admission : RA.Context
      (connection_limit => 1,
       request_limit    => 2);
    accepted : Boolean;
  begin
    RA.try_acquire_connection (admission, accepted);
    A.assert_true (reporter, accepted, "first connection is admitted");
    RA.try_acquire_connection (admission, accepted);
    A.assert_false (reporter, accepted, "connection capacity is bounded");
    A.assert_equal_natural
      (reporter, RA.active_connections(admission), 1,
       "connection accounting reports one active connection");

    RA.try_acquire_request (admission, accepted);
    A.assert_true (reporter, accepted, "first request is admitted");
    RA.try_acquire_request (admission, accepted);
    A.assert_true (reporter, accepted, "second request is admitted");
    RA.try_acquire_request (admission, accepted);
    A.assert_false (reporter, accepted, "global request capacity is bounded");

    RA.release_request (admission);
    RA.release_request (admission);
    RA.release_connection (admission);
    A.assert_equal_natural
      (reporter, RA.active_requests(admission), 0,
       "request accounting returns to zero");
    A.assert_equal_natural
      (reporter, RA.active_connections(admission), 0,
       "connection accounting returns to zero");
  end admission_accounting;

  procedure management_records
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Null_Application;
    admission   : aliased RA.Context
      (connection_limit => 7,
       request_limit    => 11);
    connection  : aliased RC.Context
      (max_requests_per_connection => 4,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1024,
       max_output_bytes            => 1024,
       read_buffer_bytes           => 256,
       write_chunk_bytes           => 256);
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    runtime_fd   : Clair.IO.Descriptor;
    peer_fd      : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    query_body   : P.Byte_Array (1 .. 128);
    query_pos    : Positive := query_body'first;
    input        : P.Byte_Array (1 .. 256);
    input_pos    : Positive := input'first;
    output       : P.Byte_Array (1 .. 512);
    output_len   : Natural := 0;
    header       : P.Header;
    decode_status : C.Decode_Status;
    decoder      : N.Decoder (max_name_bytes => 32, max_value_bytes => 32);
    feed_status  : N.Feed_Status;
    saw_max_conns : Boolean := False;
    saw_max_reqs  : Boolean := False;
    saw_mpxs      : Boolean := False;
    unknown_body  : M.Unknown_Type_Body;
    body_status   : M.Body_Status;
  begin
    append_pair (query_body, query_pos, "FCGI_MAX_CONNS");
    append_pair (query_body, query_pos, "FCGI_MAX_REQS");
    append_pair (query_body, query_pos, "FCGI_MPXS_CONNS");
    append_pair (query_body, query_pos, "FCGI_NOT_A_VALUE");

    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "management socketpair is created");
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "management socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "management event loop initializes");

    status := E.initialize
      (executor,
       event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 256,
       max_output_bytes => 1024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "management executor initializes");

    status := RC.initialize
      (connection,
       event_loop'Unchecked_Access,
       runtime_fd,
       application'Unchecked_Access,
       executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 20,
       admission       => admission'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "management connection initializes");

    append_record
      (input,
       input_pos,
       P.GET_VALUES_TYPE,
       0,
       query_body(query_body'first .. query_pos - 1));

    status := write_all (peer_fd, input(input'first .. input_pos - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "GET_VALUES query is written");

    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      exit when status /= Clair.Status.OK;
      read_peer (peer_fd, output, output_len);
      exit when output_len > 0 and then RC.pending_output_bytes(connection) = 0;
    end loop;

    A.assert_true
      (reporter, status = Clair.Status.OK,
       "GET_VALUES response dispatch succeeds");
    A.assert_true
      (reporter, output_len >= P.HEADER_LENGTH,
       "GET_VALUES_RESULT bytes are produced");

    if output_len >= P.HEADER_LENGTH then
      C.decode_header
        (output(output'first .. output'first + P.HEADER_LENGTH - 1),
         header,
         decode_status);
    else
      decode_status := C.Need_More_Data;
    end if;

    A.assert_true
      (reporter,
       decode_status = C.Complete and then
       header.record_type = P.GET_VALUES_RESULT_TYPE and then
       header.request_id = 0,
       "GET_VALUES_RESULT uses management request id zero");

    N.reset (decoder);
    if decode_status = C.Complete and then
       Natural(header.content_length) > 0 and then
       P.HEADER_LENGTH + Natural(header.content_length) <= output_len
    then
      for offset in 0 .. Natural(header.content_length) - 1 loop
        N.feed
          (decoder,
           output(output'first + P.HEADER_LENGTH + offset),
           feed_status);
        if feed_status = N.Pair_Complete then
          if pair_matches(decoder, "FCGI_MAX_CONNS", "7") then
            saw_max_conns := True;
          elsif pair_matches(decoder, "FCGI_MAX_REQS", "11") then
            saw_max_reqs := True;
          elsif pair_matches(decoder, "FCGI_MPXS_CONNS", "1") then
            saw_mpxs := True;
          end if;
          N.reset (decoder);
        end if;
      end loop;
    end if;

    A.assert_true
      (reporter, saw_max_conns and then saw_max_reqs and then saw_mpxs,
       "advertised management values match effective admission policy");
    A.assert_equal_natural
      (reporter, application.callback_count, 0,
       "management records never reach application callbacks");

    input_pos := input'first;
    output_len := 0;
    declare
      empty : P.Byte_Array (1 .. 0);
    begin
      append_record (input, input_pos, 99, 0, empty);
    end;

    status := write_all (peer_fd, input(input'first .. input_pos - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "unknown management record is written");

    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      exit when status /= Clair.Status.OK;
      read_peer (peer_fd, output, output_len);
      exit when
        output_len >= P.HEADER_LENGTH + M.UNKNOWN_TYPE_BODY_LENGTH and then
        RC.pending_output_bytes(connection) = 0;
    end loop;

    if output_len >= P.HEADER_LENGTH then
      C.decode_header
        (output(output'first .. output'first + P.HEADER_LENGTH - 1),
         header,
         decode_status);
    else
      decode_status := C.Need_More_Data;
    end if;

    A.assert_true
      (reporter,
       decode_status = C.Complete and then
       header.record_type = P.UNKNOWN_TYPE_TYPE and then
       header.request_id = 0,
       "unknown management type produces FCGI_UNKNOWN_TYPE");

    if output_len >= P.HEADER_LENGTH + M.UNKNOWN_TYPE_BODY_LENGTH then
      M.decode_unknown_type
        (output
           (output'first + P.HEADER_LENGTH ..
            output'first + P.HEADER_LENGTH + M.UNKNOWN_TYPE_BODY_LENGTH - 1),
         unknown_body,
         body_status);
    else
      body_status := M.Invalid_Body_Length;
    end if;

    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then unknown_body.record_type = 99,
       "UNKNOWN_TYPE body identifies the rejected type");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "management connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "management executor begins shutdown");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "management executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "management peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "management event loop finalizes");
    A.assert_equal_natural
      (reporter, RA.active_connections(admission), 0,
       "connection finalization releases shared admission");
  end management_records;

  procedure global_overload
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Null_Application;
    admission   : aliased RA.Context
      (connection_limit => 1,
       request_limit    => 1);
    connection  : aliased RC.Context
      (max_requests_per_connection => 2,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1024,
       max_output_bytes            => 1024,
       read_buffer_bytes           => 128,
       write_chunk_bytes           => 128);
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    runtime_fd   : Clair.IO.Descriptor;
    peer_fd      : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    dispatched   : Boolean;
    begin_body   : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE,
       flags     => P.KEEP_CONN);
    begin_bytes  : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : M.Body_Status;
    input         : P.Byte_Array
      (1 .. 2 * (P.HEADER_LENGTH + M.BEGIN_REQUEST_BODY_LENGTH));
    input_pos     : Positive := input'first;
    output        : P.Byte_Array (1 .. 64);
    output_len    : Natural := 0;
    header        : P.Header;
    decode_status : C.Decode_Status;
    end_body      : M.End_Request_Body;
  begin
    M.encode_begin_request
      (begin_body, begin_bytes, begin_written, body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       begin_written = M.BEGIN_REQUEST_BODY_LENGTH,
       "overload BEGIN_REQUEST body encodes");

    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "overload socketpair is created");
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "overload socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "overload event loop initializes");
    status := E.initialize
      (executor,
       event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 128,
       max_output_bytes => 1024);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "overload executor initializes");
    status := RC.initialize
      (connection,
       event_loop'Unchecked_Access,
       runtime_fd,
       application'Unchecked_Access,
       executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 21,
       admission       => admission'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "overload connection initializes");

    append_record (input, input_pos, P.BEGIN_REQUEST_TYPE, 1, begin_bytes);
    append_record (input, input_pos, P.BEGIN_REQUEST_TYPE, 2, begin_bytes);
    status := write_all (peer_fd, input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "two BEGIN_REQUEST records are written");

    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      exit when status /= Clair.Status.OK;
      read_peer (peer_fd, output, output_len);
      exit when
        output_len >= P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH and then
        RC.pending_output_bytes(connection) = 0;
    end loop;

    if output_len >= P.HEADER_LENGTH then
      C.decode_header
        (output(output'first .. output'first + P.HEADER_LENGTH - 1),
         header,
         decode_status);
    else
      decode_status := C.Need_More_Data;
    end if;

    A.assert_true
      (reporter,
       decode_status = C.Complete and then
       header.record_type = P.END_REQUEST_TYPE and then
       header.request_id = 2,
       "global request exhaustion rejects the second request");

    if output_len >= P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH then
      M.decode_end_request
        (output
           (output'first + P.HEADER_LENGTH ..
            output'first + P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH - 1),
         end_body,
         body_status);
    else
      body_status := M.Invalid_Body_Length;
    end if;

    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       end_body.protocol_status_code = P.OVERLOADED_STATUS,
       "global request exhaustion maps to FCGI_OVERLOADED");
    A.assert_equal_natural
      (reporter, RC.active_request_count(connection), 1,
       "first request remains active after overload refusal");
    A.assert_equal_natural
      (reporter, RA.active_requests(admission), 1,
       "global admission retains only the accepted request");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "overload connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "overload executor begins shutdown");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "overload executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "overload peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "overload event loop finalizes");
    A.assert_equal_natural
      (reporter, RA.active_requests(admission), 0,
       "connection close releases admitted requests");
  end global_overload;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "management admission accounting",
       admission_accounting'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "FastCGI management records", management_records'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "global request overload", global_overload'access);
  end run;

end Tests.Management;
