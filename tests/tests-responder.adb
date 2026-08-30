-- ============================================================================
-- tests-responder.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces;
with Clair.Test.Assertions;
with Fasyn.Protocol;
with Fasyn.Protocol.Codec;
with Fasyn.Protocol.Messages;
with Fasyn.Protocol.Name_Values;
with Fasyn.Request;
with Fasyn.Request.Testing;

package body Tests.Responder is

  package A renames Clair.Test.Assertions;
  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package M renames Fasyn.Protocol.Messages;
  package N renames Fasyn.Protocol.Name_Values;
  package R renames Fasyn.Request;
  package RT renames Fasyn.Request.Testing;

  use type Interfaces.Unsigned_32;
  use type C.Decode_Status;
  use type M.Body_Status;
  use type N.Encode_Status;
  use type R.Cancellation_Cause;
  use type R.Input_Status;
  use type R.Write_Status;

  function to_bytes (text : String) return P.Byte_Array is
    result : P.Byte_Array (1 .. text'length);
    target : Natural := result'first;
  begin
    for index in text'range loop
      result(target) := P.Byte(Character'Pos(text(index)));
      target := target + 1;
    end loop;

    return result;
  end to_bytes;

  type Test_Application is new R.Application with record
    parameter_count        : Natural := 0;
    parameter_name_length  : Natural := 0;
    parameter_value_length : Natural := 0;
    params_end_seen        : Boolean := False;
    stdin_bytes            : Natural := 0;
    stdin_end_seen         : Boolean := False;
    early_write_ok         : Boolean := False;
    final_write_ok         : Boolean := False;
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
    pragma Unreferenced (context);
  begin
    self.parameter_count := self.parameter_count + 1;
    self.parameter_name_length := name'length;
    self.parameter_value_length := value'length;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    data   : constant P.Byte_Array := to_bytes ("H");
    status : R.Write_Status;
  begin
    self.params_end_seen := True;
    R.write_stdout (response, data, status);
    self.early_write_ok := status = R.Write_Complete;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.stdin_bytes := self.stdin_bytes + data'length;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    stdout_data : constant P.Byte_Array := to_bytes ("O");
    stderr_data : constant P.Byte_Array := to_bytes ("E");
    stdout_status : R.Write_Status;
    stderr_status : R.Write_Status;
    finish_status : R.Write_Status;
  begin
    self.stdin_end_seen := True;
    R.write_stdout (response, stdout_data, stdout_status);
    R.write_stderr (response, stderr_data, stderr_status);
    R.finish (response, 17, finish_status);

    self.final_write_ok :=
      stdout_status = R.Write_Complete and then
      stderr_status = R.Write_Complete and then
      finish_status = R.Write_Complete;
  end on_stdin_end;

  Direct_Callback_Failure : exception;

  type Failing_Application is new Test_Application with null record;

  overriding procedure on_params_end
    (self     : in out Failing_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_params_end
    (self     : in out Failing_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin
    raise Direct_Callback_Failure;
  end on_params_end;

  procedure drive_record
    (exchange    : in out R.Exchange;
     handler     : in out R.Application'Class;
     response    : in out R.Writer;
     record_type : in P.Byte;
     content     : in P.Byte_Array;
     status      : out R.Input_Status)
  is
    record_header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => 1,
       content_length => P.Content_Length_Type(content'length),
       padding_length => 0,
       reserved       => 0);
  begin
    R.begin_record (exchange, record_header, response, status);

    if status /= R.Input_Progress then
      return;
    end if;

    if content'length > 0 then
      R.feed_content (exchange, content, handler, response, status);

      if status /= R.Input_Progress then
        return;
      end if;
    end if;

    R.end_record (exchange, handler, response, status);
  end drive_record;

  procedure decode_next_header
    (reporter      : in out Clair.Test.Reporter.Context;
     bytes         : in P.Byte_Array;
     position      : in out Natural;
     record_header : out P.Header)
  is
    header_bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    status       : C.Decode_Status;
  begin
    A.assert_true
      (reporter,
       position + P.HEADER_LENGTH - 1 <= bytes'last,
       "output contains a complete record header");

    for offset in header_bytes'range loop
      header_bytes(offset) := bytes(position + offset);
    end loop;

    C.decode_header (header_bytes, record_header, status);
    A.assert_true
      (reporter, status = C.Complete, "response record header decodes");
    A.assert_equal_integer
      (reporter,
       Integer(record_header.request_id),
       1,
       "response record keeps request id");
    position := position + P.HEADER_LENGTH;
  end decode_next_header;

  procedure complete_exchange
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange
      (max_name_bytes  => 64,
       max_value_bytes => 64);
    handler  : Test_Application;
    response : R.Writer (max_output_bytes => 256);

    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE,
       flags     => P.KEEP_CONN);
    begin_bytes  : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    begin_written : Natural;
    body_status  : M.Body_Status;

    name  : constant P.Byte_Array := to_bytes ("REQUEST_METHOD");
    value : constant P.Byte_Array := to_bytes ("POST");
    params_size : constant Natural
                := N.encoded_size (name'length, value'length);
    params      : P.Byte_Array (0 .. params_size - 1);
    params_written : Natural;
    encode_status  : N.Encode_Status;

    stdin_data : constant P.Byte_Array := to_bytes ("abc");
    empty      : P.Byte_Array (1 .. 0);
    status     : R.Input_Status;
  begin
    M.encode_begin_request
      (request_body => begin_body,
       output       => begin_bytes,
       written      => begin_written,
       status       => body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       begin_written = M.BEGIN_REQUEST_BODY_LENGTH,
       "BEGIN_REQUEST body encodes");

    drive_record
      (exchange, handler, response, P.BEGIN_REQUEST_TYPE, begin_bytes, status);
    A.assert_true
      (reporter, status = R.Record_Complete, "BEGIN_REQUEST is accepted");
    A.assert_true
      (reporter, R.keep_connection(exchange), "KEEP_CONN is preserved");

    N.encode_pair
      (name    => name,
       value   => value,
       output  => params,
       written => params_written,
       status  => encode_status);
    A.assert_true
      (reporter,
       encode_status = N.Encode_Complete and then params_written = params_size,
       "PARAMS pair encodes");

    drive_record
      (exchange,
       handler,
       response,
       P.PARAMS_TYPE,
       params(params'first .. params'first + 2),
       status);
    A.assert_true
      (reporter,
       status = R.Record_Complete,
       "fragmented PARAMS first record completes");

    drive_record
      (exchange,
       handler,
       response,
       P.PARAMS_TYPE,
       params(params'first + 3 .. params'last),
       status);
    A.assert_true
      (reporter,
       status = R.Record_Complete,
       "fragmented PARAMS second record completes");

    drive_record
      (exchange, handler, response, P.PARAMS_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Record_Complete, "PARAMS EOF completes stream");
    A.assert_equal_natural
      (reporter, handler.parameter_count, 1, "one parameter is delivered");
    A.assert_equal_natural
      (reporter,
       handler.parameter_name_length,
       name'length,
       "parameter name length is preserved");
    A.assert_equal_natural
      (reporter,
       handler.parameter_value_length,
       value'length,
       "parameter value length is preserved");
    A.assert_true
      (reporter, handler.params_end_seen, "application receives PARAMS EOF");
    A.assert_true
      (reporter,
       handler.early_write_ok,
       "application can write after PARAMS EOF before STDIN EOF");

    drive_record
      (exchange, handler, response, P.STDIN_TYPE, stdin_data, status);
    A.assert_true
      (reporter, status = R.Record_Complete, "STDIN content is accepted");
    A.assert_equal_natural
      (reporter, handler.stdin_bytes, 3, "STDIN is delivered incrementally");

    drive_record
      (exchange, handler, response, P.STDIN_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Request_Complete, "STDIN EOF completes request");
    A.assert_true
      (reporter, handler.stdin_end_seen, "application receives STDIN EOF");
    A.assert_true
      (reporter, handler.final_write_ok, "application finalization succeeds");
    A.assert_true
      (reporter,
       R.is_complete(exchange),
       "exchange is complete after END_REQUEST");

    declare
      output : P.Byte_Array (1 .. RT.output_length(response));
      position : Natural := output'first;
      record_header : P.Header;
      end_body_bytes : P.Byte_Array (0 .. M.END_REQUEST_BODY_LENGTH - 1);
      end_body : M.End_Request_Body;
      end_status : M.Body_Status;
    begin
      for index in output'range loop
        output(index) := RT.output_byte (response, index);
      end loop;

      decode_next_header (reporter, output, position, record_header);
      A.assert_equal_integer
        (reporter, Integer(record_header.record_type), Integer(P.STDOUT_TYPE),
         "PARAMS callback emits STDOUT");
      A.assert_equal_integer
        (reporter, Integer(record_header.content_length), 1,
         "early STDOUT has one content byte");
      A.assert_equal_integer
        (reporter, Integer(output(position)), Character'Pos('H'),
         "early STDOUT content is preserved");
      position := position + 1;

      decode_next_header (reporter, output, position, record_header);
      A.assert_equal_integer
        (reporter, Integer(record_header.record_type), Integer(P.STDOUT_TYPE),
         "final callback emits STDOUT");
      A.assert_equal_integer
        (reporter, Integer(record_header.content_length), 1,
         "final STDOUT has one content byte");
      A.assert_equal_integer
        (reporter, Integer(output(position)), Character'Pos('O'),
         "final STDOUT content is preserved");
      position := position + 1;

      decode_next_header (reporter, output, position, record_header);
      A.assert_equal_integer
        (reporter, Integer(record_header.record_type), Integer(P.STDERR_TYPE),
         "final callback emits STDERR");
      A.assert_equal_integer
        (reporter, Integer(record_header.content_length), 1,
         "STDERR has one content byte");
      A.assert_equal_integer
        (reporter, Integer(output(position)), Character'Pos('E'),
         "STDERR content is preserved");
      position := position + 1;

      decode_next_header (reporter, output, position, record_header);
      A.assert_equal_integer
        (reporter, Integer(record_header.record_type), Integer(P.STDOUT_TYPE),
         "finish emits STDOUT EOF");
      A.assert_equal_integer
        (reporter, Integer(record_header.content_length), 0,
         "STDOUT EOF is zero length");

      decode_next_header (reporter, output, position, record_header);
      A.assert_equal_integer
        (reporter, Integer(record_header.record_type), Integer(P.STDERR_TYPE),
         "finish emits STDERR EOF");
      A.assert_equal_integer
        (reporter, Integer(record_header.content_length), 0,
         "STDERR EOF is zero length");

      decode_next_header (reporter, output, position, record_header);
      A.assert_equal_integer
        (reporter,
         Integer(record_header.record_type),
         Integer(P.END_REQUEST_TYPE),
         "finish emits END_REQUEST");
      A.assert_equal_integer
        (reporter,
         Integer(record_header.content_length),
         M.END_REQUEST_BODY_LENGTH,
         "END_REQUEST body has required length");

      for offset in end_body_bytes'range loop
        end_body_bytes(offset) := output(position + offset);
      end loop;
      position := position + M.END_REQUEST_BODY_LENGTH;

      M.decode_end_request (end_body_bytes, end_body, end_status);
      A.assert_true
        (reporter, end_status = M.Body_Complete, "END_REQUEST body decodes");
      A.assert_equal_integer
        (reporter,
         Integer(end_body.application_status),
         17,
         "application status is preserved");
      A.assert_equal_integer
        (reporter,
         Integer(end_body.protocol_status_code),
         Integer(P.REQUEST_COMPLETE_STATUS),
         "protocol status is REQUEST_COMPLETE");
      A.assert_equal_natural
        (reporter,
         position,
         output'last + 1,
         "response output contains only expected FastCGI records");
    end;
  end complete_exchange;

  procedure partial_params_rejected_at_eof
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange
      (max_name_bytes  => 64,
       max_value_bytes => 64);
    handler  : Test_Application;
    response : R.Writer (max_output_bytes => 128);
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE,
       flags     => 0);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    written     : Natural;
    body_status : M.Body_Status;
    partial     : constant P.Byte_Array := [0 => 3];
    empty       : P.Byte_Array (1 .. 0);
    status      : R.Input_Status;
  begin
    M.encode_begin_request
      (begin_body, begin_bytes, written, body_status);
    drive_record
      (exchange, handler, response, P.BEGIN_REQUEST_TYPE, begin_bytes, status);
    A.assert_true
      (reporter, status = R.Record_Complete, "BEGIN_REQUEST is accepted");

    drive_record
      (exchange, handler, response, P.PARAMS_TYPE, partial, status);
    A.assert_true
      (reporter,
       status = R.Record_Complete,
       "partial PARAMS record is accepted");

    drive_record
      (exchange, handler, response, P.PARAMS_TYPE, empty, status);
    A.assert_true
      (reporter,
       status = R.Malformed_Params,
       "PARAMS EOF rejects a name-value pair that ended mid-length sequence");
  end partial_params_rejected_at_eof;

  procedure unknown_role_result
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange (max_name_bytes => 64, max_value_bytes => 64);
    handler  : Test_Application;
    response : R.Writer (max_output_bytes => 128);
    begin_body : constant M.Begin_Request_Body :=
      (role_code => 99, flags => P.KEEP_CONN);
    bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    written : Natural;
    body_status : M.Body_Status;
    status : R.Input_Status;
  begin
    M.encode_begin_request (begin_body, bytes, written, body_status);
    A.assert_true
      (reporter, body_status = M.Body_Complete,
       "unknown-role BEGIN_REQUEST encodes");
    drive_record
      (exchange, handler, response, P.BEGIN_REQUEST_TYPE, bytes, status);
    A.assert_true
      (reporter, status = R.Request_Complete,
       "unknown role completes without entering an application role");
    A.assert_true
      (reporter, R.is_complete(exchange), "unknown-role request retires");

    declare
      output : P.Byte_Array (1 .. RT.output_length(response));
      position : Natural := output'first;
      record_header : P.Header;
      body_bytes : P.Byte_Array (0 .. M.END_REQUEST_BODY_LENGTH - 1);
      end_body : M.End_Request_Body;
    begin
      for index in output'range loop
        output(index) := RT.output_byte (response, index);
      end loop;
      decode_next_header (reporter, output, position, record_header);
      A.assert_equal_integer
        (reporter, Integer(record_header.record_type),
         Integer(P.END_REQUEST_TYPE), "unknown role emits END_REQUEST");
      for offset in body_bytes'range loop
        body_bytes(offset) := output(position + offset);
      end loop;
      M.decode_end_request (body_bytes, end_body, body_status);
      A.assert_true
        (reporter, body_status = M.Body_Complete,
         "unknown-role END_REQUEST decodes");
      A.assert_equal_integer
        (reporter, Integer(end_body.protocol_status_code),
         Integer(P.UNKNOWN_ROLE_STATUS),
         "unknown role reports FCGI_UNKNOWN_ROLE");
    end;
  end unknown_role_result;

  procedure inactive_records_are_ignored
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange (max_name_bytes => 64, max_value_bytes => 64);
    handler : Test_Application;
    response : R.Writer (max_output_bytes => 128);
    empty : P.Byte_Array (1 .. 0);
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => 0);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    written : Natural;
    body_status : M.Body_Status;
    status : R.Input_Status;
  begin
    drive_record (exchange, handler, response, P.PARAMS_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Ignored_Inactive,
       "PARAMS for an inactive request is ignored");
    drive_record (exchange, handler, response, P.STDIN_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Ignored_Inactive,
       "STDIN for an inactive request is ignored");
    drive_record
      (exchange, handler, response, P.ABORT_REQUEST_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Ignored_Inactive,
       "ABORT_REQUEST for an inactive request is ignored");

    M.encode_begin_request (begin_body, begin_bytes, written, body_status);
    drive_record
      (exchange, handler, response, P.BEGIN_REQUEST_TYPE, begin_bytes, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "ignored inactive records do not poison later request reuse");
  end inactive_records_are_ignored;

  procedure writer_boundaries
    (reporter : in out Clair.Test.Reporter.Context)
  is
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => 0);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    one_byte : constant P.Byte_Array := [1 => 16#41#];
    written : Natural;
    body_status : M.Body_Status;
    input_status : R.Input_Status;
    write_status : R.Write_Status;
  begin
    M.encode_begin_request
      (begin_body, begin_bytes, written, body_status);

    declare
      exchange : R.Exchange (max_name_bytes => 1, max_value_bytes => 1);
      handler  : Test_Application;
      response : R.Writer (max_output_bytes => 9);
    begin
      drive_record
        (exchange, handler, response, P.BEGIN_REQUEST_TYPE,
         begin_bytes, input_status);
      R.write_stdout (response, one_byte, write_status);
      A.assert_true
        (reporter, write_status = R.Write_Complete,
         "writer accepts output exactly at its byte limit");
      A.assert_equal_natural
        (reporter, RT.output_length(response), 9,
         "exact-limit output accounts for record framing");
      R.write_stdout (response, one_byte, write_status);
      A.assert_true
        (reporter, write_status = R.Output_Limit_Exceeded,
         "writer rejects output immediately above its limit");
    end;

    declare
      exchange : R.Exchange (max_name_bytes => 1, max_value_bytes => 1);
      handler  : Test_Application;
      response : R.Writer (max_output_bytes => 32);
    begin
      drive_record
        (exchange, handler, response, P.BEGIN_REQUEST_TYPE,
         begin_bytes, input_status);
      R.finish (response, 0, write_status);
      A.assert_true
        (reporter, write_status = R.Write_Complete,
         "request finalization fits exactly in 32 bytes");
      A.assert_equal_natural
        (reporter, RT.output_length(response), 32,
         "finalization emits two EOF headers plus END_REQUEST");
    end;
  end writer_boundaries;

  procedure params_fragmentation_sweep
    (reporter : in out Clair.Test.Reporter.Context)
  is
    name : constant P.Byte_Array (1 .. 128) :=
      [for index in 1 .. 128 => P.Byte(index mod 256)];
    value : constant P.Byte_Array (1 .. 129) :=
      [for index in 1 .. 129 => P.Byte((index * 3) mod 256)];
    size : constant Natural := N.encoded_size(name'length, value'length);
    encoded : P.Byte_Array (0 .. size - 1);
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => 0);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty : P.Byte_Array (1 .. 0);
    written : Natural;
    encode_status : N.Encode_Status;
    body_status : M.Body_Status;
    status : R.Input_Status;
  begin
    N.encode_pair (name, value, encoded, written, encode_status);
    A.assert_true
      (reporter, encode_status = N.Encode_Complete and then written = size,
       "four-byte-length PARAMS fixture encodes");
    M.encode_begin_request
      (begin_body, begin_bytes, written, body_status);

    for split in 1 .. encoded'length - 1 loop
      declare
        exchange : R.Exchange (max_name_bytes => 128, max_value_bytes => 129);
        handler  : Test_Application;
        response : R.Writer (max_output_bytes => 128);
      begin
        drive_record
          (exchange, handler, response, P.BEGIN_REQUEST_TYPE,
           begin_bytes, status);
        drive_record
          (exchange, handler, response, P.PARAMS_TYPE,
           encoded(encoded'first .. encoded'first + split - 1), status);
        if status = R.Record_Complete then
          drive_record
            (exchange, handler, response, P.PARAMS_TYPE,
             encoded(encoded'first + split .. encoded'last), status);
        end if;
        if status = R.Record_Complete then
          drive_record
            (exchange, handler, response, P.PARAMS_TYPE, empty, status);
        end if;

        A.assert_true
          (reporter, status = R.Record_Complete,
           "PARAMS decoding is invariant under every record split");
        A.assert_equal_natural
          (reporter, handler.parameter_count, 1,
           "every PARAMS split delivers exactly one pair");
        A.assert_equal_natural
          (reporter, handler.parameter_name_length, 128,
           "every PARAMS split preserves the four-byte name length");
        A.assert_equal_natural
          (reporter, handler.parameter_value_length, 129,
           "every PARAMS split preserves the four-byte value length");
      end;
    end loop;
  end params_fragmentation_sweep;

  procedure malformed_discrete_records
    (reporter : in out Clair.Test.Reporter.Context)
  is
    handler : Test_Application;
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => 0);
    bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    written : Natural;
    body_status : M.Body_Status;
    status : R.Input_Status;
  begin
    declare
      exchange : R.Exchange (max_name_bytes => 64, max_value_bytes => 64);
      response : R.Writer (max_output_bytes => 128);
      header : constant P.Header :=
        (version => P.VERSION_1, record_type => P.BEGIN_REQUEST_TYPE,
         request_id => 1, content_length => 7, padding_length => 0,
         reserved => 0);
    begin
      R.begin_record (exchange, header, response, status);
      A.assert_true
        (reporter, status = R.Invalid_Content_Length,
         "BEGIN_REQUEST rejects a non-eight-byte body");
    end;

    M.encode_begin_request (begin_body, bytes, written, body_status);
    declare
      exchange : R.Exchange (max_name_bytes => 64, max_value_bytes => 64);
      response : R.Writer (max_output_bytes => 128);
      header : constant P.Header :=
        (version => P.VERSION_1, record_type => P.ABORT_REQUEST_TYPE,
         request_id => 1, content_length => 1, padding_length => 0,
         reserved => 0);
    begin
      drive_record
        (exchange, handler, response, P.BEGIN_REQUEST_TYPE, bytes, status);
      A.assert_true
        (reporter, status = R.Record_Complete, "abort fixture begins");
      R.begin_record (exchange, header, response, status);
      A.assert_true
        (reporter, status = R.Invalid_Content_Length,
         "FCGI_ABORT_REQUEST rejects nonempty content");
    end;
  end malformed_discrete_records;

  procedure invalid_responder_sequence
    (reporter : in out Clair.Test.Reporter.Context)
  is
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => 0);
    bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty : P.Byte_Array (1 .. 0);
    partial_four_byte_length : constant P.Byte_Array :=
      [16#80#, 0, 0];
    written : Natural;
    body_status : M.Body_Status;
    status : R.Input_Status;
  begin
    M.encode_begin_request (begin_body, bytes, written, body_status);

    declare
      exchange : R.Exchange (max_name_bytes => 64, max_value_bytes => 64);
      handler  : Test_Application;
      response : R.Writer (max_output_bytes => 128);
    begin
      drive_record
        (exchange, handler, response, P.BEGIN_REQUEST_TYPE, bytes, status);
      drive_record (exchange, handler, response, P.STDIN_TYPE, empty, status);
      A.assert_true
        (reporter, status = R.Invalid_Record_Sequence,
         "Responder rejects STDIN before PARAMS EOF");
    end;

    declare
      exchange : R.Exchange (max_name_bytes => 64, max_value_bytes => 64);
      handler  : Test_Application;
      response : R.Writer (max_output_bytes => 128);
    begin
      drive_record
        (exchange, handler, response, P.BEGIN_REQUEST_TYPE, bytes, status);
      drive_record (exchange, handler, response, P.PARAMS_TYPE, empty, status);
      drive_record (exchange, handler, response, P.DATA_TYPE, empty, status);
      A.assert_true
        (reporter, status = R.Invalid_Record_Type,
         "Responder rejects FCGI_DATA");
    end;

    declare
      exchange : R.Exchange (max_name_bytes => 64, max_value_bytes => 64);
      handler  : Test_Application;
      response : R.Writer (max_output_bytes => 128);
    begin
      drive_record
        (exchange, handler, response, P.BEGIN_REQUEST_TYPE, bytes, status);
      drive_record
        (exchange, handler, response, P.PARAMS_TYPE,
         partial_four_byte_length, status);
      A.assert_true
        (reporter, status = R.Record_Complete,
         "fragmented four-byte PARAMS length remains incremental");
      drive_record (exchange, handler, response, P.PARAMS_TYPE, empty, status);
      A.assert_true
        (reporter, status = R.Malformed_Params,
         "PARAMS EOF rejects truncated four-byte length");
    end;
  end invalid_responder_sequence;

  procedure callback_exception_propagates
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange
      (max_name_bytes  => 64,
       max_value_bytes => 64);
    handler  : Failing_Application;
    response : R.Writer (max_output_bytes => 128);
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => 0);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty       : P.Byte_Array (1 .. 0);
    written     : Natural;
    body_status : M.Body_Status;
    status      : R.Input_Status;
    raised      : Boolean := False;
  begin
    M.encode_begin_request
      (begin_body, begin_bytes, written, body_status);
    A.assert_true
      (reporter,
       body_status = M.Body_Complete and then
       written = M.BEGIN_REQUEST_BODY_LENGTH,
       "callback failure BEGIN_REQUEST encodes");

    drive_record
      (exchange, handler, response, P.BEGIN_REQUEST_TYPE, begin_bytes, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "callback failure request begins");

    begin
      drive_record
        (exchange, handler, response, P.PARAMS_TYPE, empty, status);
    exception
      when Direct_Callback_Failure =>
        raised := True;
    end;

    A.assert_true
      (reporter, raised,
       "direct Exchange propagates application callback exception");
  end callback_exception_propagates;

  procedure cancellation_and_abort
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange
      (max_name_bytes => 64, max_value_bytes => 64);
    handler : Test_Application;
    response : R.Writer (max_output_bytes => 128);
    begin_body : constant M.Begin_Request_Body :=
      (role_code => P.RESPONDER_ROLE, flags => P.KEEP_CONN);
    bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    empty : P.Byte_Array (1 .. 0);
    written : Natural;
    body_status : M.Body_Status;
    status : R.Input_Status;
  begin
    M.encode_begin_request (begin_body, bytes, written, body_status);
    A.assert_true
      (reporter, body_status = M.Body_Complete,
       "abort fixture BEGIN_REQUEST encodes");
    drive_record
      (exchange, handler, response, P.BEGIN_REQUEST_TYPE, bytes, status);
    A.assert_true
      (reporter, status = R.Record_Complete, "abort fixture begins");
    drive_record
      (exchange, handler, response, P.ABORT_REQUEST_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Request_Complete,
       "FCGI_ABORT_REQUEST completes request");
    A.assert_true
      (reporter, R.is_complete (exchange), "aborted request is complete");
    A.assert_true
      (reporter, R.cancellation_reason (exchange) = R.Peer_Abort,
       "peer abort reason is retained");
    A.assert_true
      (reporter, R.keep_connection (exchange),
       "abort preserves KEEP_CONN");
    A.assert_positive
      (reporter, Integer (RT.output_length (response)),
       "abort queues FastCGI completion output");

    declare
      timeout_exchange : R.Exchange
        (max_name_bytes => 64, max_value_bytes => 64);
      timeout_handler : Test_Application;
      timeout_response : R.Writer (max_output_bytes => 128);
    begin
      drive_record
        (timeout_exchange, timeout_handler, timeout_response,
         P.BEGIN_REQUEST_TYPE, bytes, status);
      A.assert_true
        (reporter, status = R.Record_Complete, "timeout fixture begins");
      R.cancel
        (timeout_exchange, timeout_response, R.Request_Timeout, status);
      A.assert_true
        (reporter, status = R.Request_Complete,
         "timeout cancellation completes request");
      A.assert_true
        (reporter,
         R.cancellation_reason (timeout_exchange) = R.Request_Timeout,
         "timeout reason is retained");
    end;
  end cancellation_and_abort;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter, "complete responder exchange", complete_exchange'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "partial PARAMS rejected at EOF",
       partial_params_rejected_at_eof'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "inactive records are ignored",
       inactive_records_are_ignored'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "writer boundaries", writer_boundaries'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "PARAMS fragmentation sweep",
       params_fragmentation_sweep'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "unknown role result", unknown_role_result'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "malformed discrete records",
       malformed_discrete_records'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "invalid Responder sequence",
       invalid_responder_sequence'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "direct callback exception propagation",
       callback_exception_propagates'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "cancellation and FCGI_ABORT_REQUEST",
       cancellation_and_abort'access);
  end run;

end Tests.Responder;
