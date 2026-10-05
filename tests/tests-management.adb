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
with Fasyn.Protocol.Bodies;
with Fasyn.Protocol.Name_Values;
with Fasyn.Protocol.Management;
with Fasyn.Request;
with Fasyn.Admission;
with Fasyn.Request.Connection;
with Fasyn.Request.Execution;

package body Tests.Management is

  package A renames Clair.Test.Assertions;
  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package B renames Fasyn.Protocol.Bodies;
  package N renames Fasyn.Protocol.Name_Values;
  package PM renames Fasyn.Protocol.Management;
  package R renames Fasyn.Request;
  package RA renames Fasyn.Admission;
  package RC renames Fasyn.Request.Connection;
  package E renames Fasyn.Request.Execution;

  use type Interfaces.C.int;
  use type Clair.IO.Byte_Count;
  use type Clair.Status.Code;
  use type C.Decode_Status;
  use type B.Body_Status;
  use type N.Encode_Status;
  use type N.Feed_Status;
  use type P.Byte;
  use type P.Request_Id;
  use type RC.Initialization_Outcome;
  use type System.Storage_Elements.Storage_Offset;

  procedure noncanonical_query_lengths
    (reporter : in out Clair.Test.Reporter.Context)
  is
    query : PM.Query;
  begin
    PM.feed (query, 16#80#);
    PM.feed (query, 0);
    PM.feed (query, 0);
    PM.feed (query, 1);
    A.assert_false
      (reporter, PM.at_pair_boundary(query),
       "GET_VALUES rejects four-byte name length below 128");

    PM.reset (query);
    PM.feed (query, 0);
    PM.feed (query, 16#80#);
    PM.feed (query, 0);
    PM.feed (query, 0);
    PM.feed (query, 1);
    A.assert_false
      (reporter, PM.at_pair_boundary(query),
       "GET_VALUES rejects four-byte value length below 128");

    PM.reset (query);
    PM.feed (query, 16#80#);
    PM.feed (query, 0);
    PM.feed (query, 0);
    A.assert_false
      (reporter, PM.at_pair_boundary(query),
       "truncated four-byte GET_VALUES length remains incomplete");

    PM.reset (query);
    PM.feed (query, 0);
    PM.feed (query, 0);
    A.assert_true
      (reporter, PM.at_pair_boundary(query),
       "canonical empty GET_VALUES pair remains accepted");
  end noncanonical_query_lengths;

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
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Null_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Null_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Null_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Null_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (context, name, value);
  begin
    self.callback_count := self.callback_count + 1;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Null_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.callback_count := self.callback_count + 1;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Null_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, data, response);
  begin
    self.callback_count := self.callback_count + 1;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Null_Application;
     context  : in R.Context;
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
    status := N.encode_pair
      (name_bytes, empty, encoded, written);

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
     request_id  : P.Request_Id;
     content     : P.Byte_Array)
  is
    header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => request_id,
       content_length => P.Content_Length(content'length),
       padding_length => 0);
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
      (max_connections => 1,
       max_requests    => 2);
    accepted : Boolean;
    underflow_rejected : Boolean := False;
  begin
    accepted := RA.try_acquire_connection (admission);
    A.assert_true (reporter, accepted, "first connection is admitted");
    accepted := RA.try_acquire_connection (admission);
    A.assert_false (reporter, accepted, "connection capacity is bounded");
    A.assert_equal_natural
      (reporter, RA.active_connections(admission), 1,
       "connection accounting reports one active connection");

    accepted := RA.try_acquire_request (admission);
    A.assert_true (reporter, accepted, "first request is admitted");
    accepted := RA.try_acquire_request (admission);
    A.assert_true (reporter, accepted, "second request is admitted");
    accepted := RA.try_acquire_request (admission);
    A.assert_false (reporter, accepted, "global request capacity is bounded");

    RA.release_request (admission);
    RA.release_request (admission);
    begin
      RA.release_request (admission);
    exception
      when Program_Error =>
        underflow_rejected := True;
    end;
    A.assert_true
      (reporter, underflow_rejected,
       "unmatched request release is rejected");

    RA.release_connection (admission);
    underflow_rejected := False;
    begin
      RA.release_connection (admission);
    exception
      when Program_Error =>
        underflow_rejected := True;
    end;
    A.assert_true
      (reporter, underflow_rejected,
       "unmatched connection release is rejected");
    A.assert_equal_natural
      (reporter, RA.active_requests(admission), 0,
       "request accounting returns to zero");
    A.assert_equal_natural
      (reporter, RA.active_connections(admission), 0,
       "connection accounting returns to zero");

    declare
      no_connections : RA.Context
        (max_connections => 0, max_requests => 1);
      no_requests : RA.Context
        (max_connections => 1, max_requests => 0);
    begin
      A.assert_false
        (reporter, RA.try_acquire_connection(no_connections),
         "zero connection quota refuses every acquisition");
      A.assert_true
        (reporter, RA.try_acquire_connection(no_requests),
         "zero request quota still permits a connection");
      A.assert_false
        (reporter, RA.try_acquire_request(no_requests),
         "zero request quota refuses every application request");
      A.assert_equal_natural
        (reporter, RA.max_connections(no_connections), 0,
         "zero connection quota remains observable");
      A.assert_equal_natural
        (reporter, RA.max_requests(no_requests), 0,
         "zero request quota remains observable");
      RA.release_connection (no_requests);
    end;
  end admission_accounting;

  procedure management_records
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Null_Application;
    admission   : aliased RA.Context
      (max_connections => 7,
       max_requests    => 11);
    connection  : aliased RC.Context
      (max_requests_per_connection => 4,
       max_name_bytes              => 0,
       max_value_bytes             => 0,
       max_request_output_bytes    => 1024,
       max_connection_output_bytes => 1024,
       read_buffer_bytes           => 256,
       write_chunk_bytes           => 256);
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    runtime_fd   : Clair.IO.Descriptor;
    peer_fd      : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    outcome      : RC.Initialization_Outcome;
    dispatched   : Boolean;
    query_body   : P.Byte_Array (1 .. 256);
    query_pos    : Positive := query_body'first;
    long_unknown : constant String (1 .. 130) := (others => 'X');
    input        : P.Byte_Array (1 .. 512);
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
    unknown_body  : B.Unknown_Type_Body;
    body_status   : B.Body_Status;
    empty_query_burst_count : constant Positive := 40;
    unknown_burst_count     : constant Positive := 20;
  begin
    append_pair (query_body, query_pos, "FCGI_MAX_CONNS");
    append_pair (query_body, query_pos, long_unknown);
    append_pair (query_body, query_pos, "FCGI_MAX_REQS");
    append_pair (query_body, query_pos, "FCGI_MPXS_CONNS");

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
       request_lifetime_timeout => 60_000,
       admission       => admission'Unchecked_Access,
       outcome          => outcome);
    A.assert_true
      (reporter, status = Clair.Status.OK and then outcome = RC.Activated,
       "management connection initializes with admission");

    append_record
      (input,
       input_pos,
       P.GET_VALUES,
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
      decode_status := C.decode_header
        (output(output'first .. output'first + P.HEADER_LENGTH - 1),
         header);
    else
      decode_status := C.Need_More_Data;
    end if;

    A.assert_true
      (reporter,
       decode_status = C.Complete and then
       header.record_type = P.GET_VALUES_RESULT and then
       header.request_id = 0,
       "GET_VALUES_RESULT uses management request id zero");

    N.reset (decoder);
    if decode_status = C.Complete and then
       Natural(header.content_length) > 0 and then
       P.HEADER_LENGTH + Natural(header.content_length) <= output_len
    then
      for offset in 0 .. Natural(header.content_length) - 1 loop
        feed_status := N.feed
          (decoder, output(output'first + P.HEADER_LENGTH + offset));
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
       "long unknown GET_VALUES name is skipped between recognized names");
    A.assert_true
      (reporter, RC.is_active(connection),
       "long unknown GET_VALUES name preserves the connection");
    A.assert_equal_natural
      (reporter, application.callback_count, 0,
       "management records never reach application callbacks");

    input_pos := input'first;
    output_len := 0;
    declare
      empty : P.Byte_Array (1 .. 0);
    begin
      for index in 1 .. empty_query_burst_count loop
        pragma Unreferenced (index);
        append_record (input, input_pos, P.GET_VALUES, 0, empty);
      end loop;
    end;

    status := write_all (peer_fd, input(input'first .. input_pos - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "empty GET_VALUES burst is written");

    for attempt in 1 .. 150 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      exit when status /= Clair.Status.OK;
      read_peer (peer_fd, output, output_len);
      exit when
        output_len = empty_query_burst_count * P.HEADER_LENGTH and then
        RC.pending_output_bytes(connection) = 0;
    end loop;

    A.assert_equal_natural
      (reporter, output_len, empty_query_burst_count * P.HEADER_LENGTH,
       "GET_VALUES backpressure preserves every empty result");
    A.assert_true
      (reporter, RC.is_active(connection),
       "GET_VALUES control burst preserves the FastCGI connection");

    input_pos := input'first;
    output_len := 0;
    declare
      empty : P.Byte_Array (1 .. 0);
    begin
      for index in 1 .. unknown_burst_count loop
        pragma Unreferenced (index);
        append_record (input, input_pos, 99, 0, empty);
      end loop;
    end;

    status := write_all (peer_fd, input(input'first .. input_pos - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "unknown management burst is written");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      exit when status /= Clair.Status.OK;
      read_peer (peer_fd, output, output_len);
      exit when
        output_len = unknown_burst_count *
          (P.HEADER_LENGTH + B.UNKNOWN_TYPE_BODY_LENGTH) and then
        RC.pending_output_bytes(connection) = 0;
    end loop;

    A.assert_equal_natural
      (reporter, output_len,
       unknown_burst_count *
         (P.HEADER_LENGTH + B.UNKNOWN_TYPE_BODY_LENGTH),
       "control backpressure preserves every UNKNOWN_TYPE response");
    A.assert_true
      (reporter, RC.is_active(connection),
       "control-output burst preserves the FastCGI connection");

    if output_len >= P.HEADER_LENGTH then
      decode_status := C.decode_header
        (output(output'first .. output'first + P.HEADER_LENGTH - 1),
         header);
    else
      decode_status := C.Need_More_Data;
    end if;

    A.assert_true
      (reporter,
       decode_status = C.Complete and then
       header.record_type = P.UNKNOWN_TYPE and then
       header.request_id = 0,
       "unknown management type produces FCGI_UNKNOWN_TYPE");

    if output_len >= P.HEADER_LENGTH + B.UNKNOWN_TYPE_BODY_LENGTH then
      body_status := B.decode_unknown_type
        (output
           (output'first + P.HEADER_LENGTH ..
            output'first + P.HEADER_LENGTH + B.UNKNOWN_TYPE_BODY_LENGTH - 1),
         unknown_body);
    else
      body_status := B.Invalid_Body_Length;
    end if;

    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then unknown_body.record_type = 99,
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

  procedure zero_request_quota_connection
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Null_Application;
    admission   : aliased RA.Context
      (max_connections => 1,
       max_requests    => 0);
    connection  : aliased RC.Context
      (max_requests_per_connection => 2,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 256,
       max_connection_output_bytes => 512,
       read_buffer_bytes           => 128,
       write_chunk_bytes           => 128);
    runtime_raw   : aliased Interfaces.C.int := -1;
    peer_raw      : aliased Interfaces.C.int := -1;
    runtime_fd    : Clair.IO.Descriptor;
    peer_fd       : Clair.IO.Descriptor;
    native_error  : Interfaces.C.int;
    status        : Clair.Status.Code;
    outcome       : RC.Initialization_Outcome;
    dispatched    : Boolean;
    query_body    : P.Byte_Array (1 .. 96);
    query_pos     : Positive := query_body'first;
    input         : P.Byte_Array (1 .. 192);
    input_pos     : Positive := input'first;
    output        : P.Byte_Array (1 .. 256);
    output_len    : Natural := 0;
    header        : P.Header;
    decode_status : C.Decode_Status;
    decoder       : N.Decoder (max_name_bytes => 32, max_value_bytes => 8);
    feed_status   : N.Feed_Status;
    saw_max_reqs  : Boolean := False;
    saw_mpxs      : Boolean := False;
    begin_body    : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    begin_bytes   : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    end_body      : B.End_Request_Body;
  begin
    append_pair (query_body, query_pos, "FCGI_MAX_REQS");
    append_pair (query_body, query_pos, "FCGI_MPXS_CONNS");
    body_status := B.encode_begin_request
      (begin_body, begin_bytes, begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
       "zero-request BEGIN_REQUEST body encodes");

    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "zero-request socketpair is created");
    if native_error /= 0 then
      return;
    end if;
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_positive
      (reporter, Integer(drain_peer(peer_fd)),
       "zero-request socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "zero-request event loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 128, 256);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "zero-request executor initializes");

    status := RC.initialize
      (connection, event_loop'Unchecked_Access, runtime_fd,
       application'Unchecked_Access, executor'Unchecked_Access, 60_000,
       admission => admission'Unchecked_Access, outcome => outcome);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then outcome = RC.Activated,
       "zero-request connection is admitted");

    append_record
      (input, input_pos, P.GET_VALUES, 0,
       query_body(query_body'first .. query_pos - 1));
    status := write_all (peer_fd, input(input'first .. input_pos - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "zero-request GET_VALUES query is written");

    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      exit when status /= Clair.Status.OK;
      read_peer (peer_fd, output, output_len);
      exit when output_len > 0 and then RC.pending_output_bytes(connection) = 0;
    end loop;

    if output_len >= P.HEADER_LENGTH then
      decode_status := C.decode_header
        (output(output'first .. output'first + P.HEADER_LENGTH - 1),
         header);
    else
      decode_status := C.Need_More_Data;
    end if;
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then
       decode_status = C.Complete and then
       header.record_type = P.GET_VALUES_RESULT,
       "zero-request management query returns GET_VALUES_RESULT");

    N.reset (decoder);
    if decode_status = C.Complete and then
       Natural(header.content_length) > 0 and then
       P.HEADER_LENGTH + Natural(header.content_length) <= output_len
    then
      for offset in 0 .. Natural(header.content_length) - 1 loop
        feed_status := N.feed
          (decoder, output(output'first + P.HEADER_LENGTH + offset));
        if feed_status = N.Pair_Complete then
          if pair_matches(decoder, "FCGI_MAX_REQS", "0") then
            saw_max_reqs := True;
          elsif pair_matches(decoder, "FCGI_MPXS_CONNS", "0") then
            saw_mpxs := True;
          end if;
          N.reset (decoder);
        end if;
      end loop;
    end if;
    A.assert_true
      (reporter, saw_max_reqs and then saw_mpxs,
       "zero request quota is advertised without multiplexing");

    input_pos := input'first;
    output_len := 0;
    append_record (input, input_pos, P.BEGIN_REQUEST, 1, begin_bytes);
    status := write_all (peer_fd, input(input'first .. input_pos - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "zero-request BEGIN_REQUEST is written");

    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      exit when status /= Clair.Status.OK;
      read_peer (peer_fd, output, output_len);
      exit when
        output_len >= P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH and then
        RC.pending_output_bytes(connection) = 0;
    end loop;

    if output_len >= P.HEADER_LENGTH then
      decode_status := C.decode_header
        (output(output'first .. output'first + P.HEADER_LENGTH - 1),
         header);
    else
      decode_status := C.Need_More_Data;
    end if;
    if decode_status = C.Complete and then
       output_len >= P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH
    then
      body_status := B.decode_end_request
        (output
           (output'first + P.HEADER_LENGTH ..
            output'first + P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH - 1),
         end_body);
    else
      body_status := B.Invalid_Body_Length;
    end if;
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then
       decode_status = C.Complete and then
       header.record_type = P.END_REQUEST and then
       header.request_id = 1 and then
       body_status = B.Body_Complete and then
       end_body.protocol_status_code = P.OVERLOADED,
       "zero request quota maps BEGIN_REQUEST to FCGI_OVERLOADED");
    A.assert_equal_natural
      (reporter, application.callback_count, 0,
       "zero request quota never invokes the application");
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 0,
       "zero request quota admits no connection request slot");
    A.assert_equal_natural
      (reporter, RA.active_requests(admission), 0,
       "zero request quota retains no shared request admission");
    A.assert_true
      (reporter, RC.is_active(connection),
       "overload refusal preserves the connection");

    input_pos := input'first;
    output_len := 0;
    declare
      empty : P.Byte_Array (1 .. 0);
    begin
      append_record (input, input_pos, P.GET_VALUES, 0, empty);
    end;
    status := write_all (peer_fd, input(input'first .. input_pos - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "post-overload management query is written");

    for attempt in 1 .. 50 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      exit when status /= Clair.Status.OK;
      read_peer (peer_fd, output, output_len);
      exit when output_len >= P.HEADER_LENGTH;
    end loop;
    if output_len >= P.HEADER_LENGTH then
      decode_status := C.decode_header
        (output(output'first .. output'first + P.HEADER_LENGTH - 1),
         header);
    else
      decode_status := C.Need_More_Data;
    end if;
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then
       decode_status = C.Complete and then
       header.record_type = P.GET_VALUES_RESULT and then
       RC.is_active(connection),
       "management traffic remains usable after overload refusal");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "zero-request connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "zero-request executor begins shutdown");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "zero-request executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "zero-request peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "zero-request event loop finalizes");
  end zero_request_quota_connection;

  procedure global_overload
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    application : aliased Null_Application;
    admission   : aliased RA.Context
      (max_connections => 1,
       max_requests    => 1);
    connection  : aliased RC.Context
      (max_requests_per_connection => 2,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 1024,
       max_connection_output_bytes => 1024,
       read_buffer_bytes           => 128,
       write_chunk_bytes           => 128);
    runtime_raw  : aliased Interfaces.C.int := -1;
    peer_raw     : aliased Interfaces.C.int := -1;
    runtime_fd   : Clair.IO.Descriptor;
    peer_fd      : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    accepted     : Boolean;
    outcome      : RC.Initialization_Outcome;
    dispatched   : Boolean;
    begin_body   : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE,
       flags     => P.KEEP_CONN);
    begin_bytes  : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status   : B.Body_Status;
    overload_burst_count : constant Positive := 20;
    input         : P.Byte_Array
      (1 .. (overload_burst_count + 1) *
        (P.HEADER_LENGTH + B.BEGIN_REQUEST_BODY_LENGTH));
    input_pos     : Positive := input'first;
    output        : P.Byte_Array (1 .. 512);
    output_len    : Natural := 0;
    header        : P.Header;
    decode_status : C.Decode_Status;
    end_body      : B.End_Request_Body;
  begin
    body_status := B.encode_begin_request
      (begin_body, begin_bytes, begin_written);
    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       begin_written = B.BEGIN_REQUEST_BODY_LENGTH,
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
    accepted := RA.try_acquire_connection (admission);
    A.assert_true
      (reporter, accepted, "overload fixture occupies connection admission");
    status := RC.initialize
      (connection,
       event_loop'Unchecked_Access,
       runtime_fd,
       application'Unchecked_Access,
       executor'Unchecked_Access,
       request_lifetime_timeout => 60_000,
       admission       => admission'Unchecked_Access,
       outcome          => outcome);
    A.assert_true
      (reporter, status = Clair.Status.OK and then
       outcome = RC.Capacity_Refused,
       "connection admission saturation is a non-error refusal");
    A.assert_false
      (reporter, RC.is_active(connection),
       "admission refusal leaves connection uninitialized");
    RA.release_connection (admission);

    status := RC.initialize
      (connection,
       event_loop'Unchecked_Access,
       runtime_fd,
       application'Unchecked_Access,
       executor'Unchecked_Access,
       request_lifetime_timeout => 60_000,
       admission       => admission'Unchecked_Access,
       outcome          => outcome);
    A.assert_true
      (reporter, status = Clair.Status.OK and then outcome = RC.Activated,
       "overload connection initializes with admission");

    append_record (input, input_pos, P.BEGIN_REQUEST, 1, begin_bytes);
    for request_id in 2 .. overload_burst_count + 1 loop
      append_record
        (input, input_pos, P.BEGIN_REQUEST,
         P.Request_Id(request_id), begin_bytes);
    end loop;
    status := write_all (peer_fd, input);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "overload BEGIN_REQUEST burst is written");

    for attempt in 1 .. 150 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate (event_loop, 10, dispatched);
      exit when status /= Clair.Status.OK;
      read_peer (peer_fd, output, output_len);
      exit when
        output_len = overload_burst_count *
          (P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH) and then
        RC.pending_output_bytes(connection) = 0;
    end loop;

    A.assert_equal_natural
      (reporter, output_len,
       overload_burst_count *
         (P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH),
       "OVERLOADED backpressure preserves every refusal response");
    A.assert_true
      (reporter, RC.is_active(connection),
       "OVERLOADED control burst preserves the FastCGI connection");

    if output_len >= P.HEADER_LENGTH then
      decode_status := C.decode_header
        (output(output'first .. output'first + P.HEADER_LENGTH - 1),
         header);
    else
      decode_status := C.Need_More_Data;
    end if;

    A.assert_true
      (reporter,
       decode_status = C.Complete and then
       header.record_type = P.END_REQUEST and then
       header.request_id = 2,
       "global request exhaustion rejects the second request");

    if output_len >= P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH then
      body_status := B.decode_end_request
        (output
           (output'first + P.HEADER_LENGTH ..
            output'first + P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH - 1),
         end_body);
    else
      body_status := B.Invalid_Body_Length;
    end if;

    A.assert_true
      (reporter,
       body_status = B.Body_Complete and then
       end_body.protocol_status_code = P.OVERLOADED,
       "global request exhaustion maps to FCGI_OVERLOADED");
    A.assert_equal_natural
      (reporter, RC.active_requests(connection), 1,
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
      (reporter, "noncanonical query lengths", noncanonical_query_lengths'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "management admission accounting",
       admission_accounting'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "FastCGI management records", management_records'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "zero request quota connection",
       zero_request_quota_connection'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "global request overload", global_overload'access);
  end run;

end Tests.Management;
