-- ============================================================================
-- tests-filter.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
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

package body Tests.Filter is

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

  type Filter_Application is new R.Application with record
    parameter_count : Natural := 0;
    stdin_bytes     : Natural := 0;
    data_bytes      : Natural := 0;
    params_end_seen : Boolean := False;
    stdin_end_seen  : Boolean := False;
    data_end_seen   : Boolean := False;
    role_seen       : P.Role := P.Responder;
    write_on_params : Boolean := False;
    finish_on_stdin_end : Boolean := False;
    params_write_status : R.Write_Status := R.Write_Complete;
    output_ok       : Boolean := True;
    finish_status_value : Interfaces.Unsigned_32 := 23;
  end record;

  overriding procedure on_parameter
    (self    : in out Filter_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Filter_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Filter_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Filter_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_data
    (self     : in out Filter_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_data_end
    (self     : in out Filter_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Filter_Application;
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
    (self     : in out Filter_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    marker : constant P.Byte_Array := to_bytes ("P");
  begin
    self.params_end_seen := True;
    self.role_seen := R.request_role(context);

    if self.write_on_params then
      R.write_stdout (response, marker, self.params_write_status);
    end if;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Filter_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (response);
  begin
    self.role_seen := R.request_role(context);
    self.stdin_bytes := self.stdin_bytes + data'length;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Filter_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    marker : constant P.Byte_Array := to_bytes ("S");
    write_status : R.Write_Status;
    finish_status : R.Write_Status;
  begin
    self.stdin_end_seen := True;
    self.role_seen := R.request_role(context);
    R.write_stdout (response, marker, write_status);
    self.output_ok := self.output_ok and then
      write_status = R.Write_Complete;

    if self.finish_on_stdin_end then
      R.finish (response, self.finish_status_value, finish_status);
      self.output_ok := self.output_ok and then
        finish_status = R.Write_Complete;
    end if;
  end on_stdin_end;

  overriding procedure on_data
    (self     : in out Filter_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    status : R.Write_Status;
  begin
    self.role_seen := R.request_role(context);
    self.data_bytes := self.data_bytes + data'length;
    R.write_stdout (response, data, status);
    self.output_ok := self.output_ok and then status = R.Write_Complete;
  end on_data;

  overriding procedure on_data_end
    (self     : in out Filter_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    status : R.Write_Status;
  begin
    self.data_end_seen := True;
    self.role_seen := R.request_role(context);
    R.finish (response, self.finish_status_value, status);
    self.output_ok := self.output_ok and then status = R.Write_Complete;
  end on_data_end;

  procedure encode_begin
    (output : out P.Byte_Array)
  is
    request_body : constant M.Begin_Request_Body :=
      (role_code => P.FILTER_ROLE,
       flags     => P.KEEP_CONN);
    written : Natural;
    status  : M.Body_Status;
  begin
    M.encode_begin_request (request_body, output, written, status);
    if status /= M.Body_Complete or else
       written /= M.BEGIN_REQUEST_BODY_LENGTH
    then
      raise Program_Error with "Filter BEGIN_REQUEST encoding failed";
    end if;
  end encode_begin;

  procedure append_pair
    (buffer   : in out P.Byte_Array;
     position : in out Positive;
     name     : String;
     value    : String)
  is
    name_bytes  : constant P.Byte_Array := to_bytes(name);
    value_bytes : constant P.Byte_Array := to_bytes(value);
    encoded : P.Byte_Array
      (1 .. N.encoded_size(name_bytes'length, value_bytes'length));
    written : Natural;
    status  : N.Encode_Status;
  begin
    N.encode_pair
      (name_bytes, value_bytes, encoded, written, status);

    if status /= N.Encode_Complete or else
       position + written - 1 > buffer'last
    then
      raise Program_Error with "Filter PARAMS pair encoding failed";
    end if;

    for offset in 0 .. written - 1 loop
      buffer(position + offset) := encoded(encoded'first + offset);
    end loop;
    position := position + written;
  end append_pair;

  procedure build_filter_params
    (buffer      : in out P.Byte_Array;
     length      : out Natural;
     data_length : String := "5";
     include_last_mod : Boolean := True)
  is
    position : Positive := buffer'first;
  begin
    append_pair (buffer, position, "FCGI_DATA_LENGTH", data_length);
    if include_last_mod then
      append_pair (buffer, position, "FCGI_DATA_LAST_MOD", "123456");
    end if;
    append_pair (buffer, position, "REQUEST_METHOD", "POST");
    length := position - buffer'first;
  end build_filter_params;

  procedure drive_record
    (exchange    : in out R.Exchange;
     application : in out Filter_Application;
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

  function end_request_status
    (response : R.Writer;
     app_status : out Interfaces.Unsigned_32) return Boolean
  is
    output : P.Byte_Array (1 .. RT.output_length(response));
    position : Natural := 1;
    header_bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    header : P.Header;
    decode_status : C.Decode_Status;
    body_bytes : P.Byte_Array (0 .. M.END_REQUEST_BODY_LENGTH - 1);
    decoded_body : M.End_Request_Body;
    body_status : M.Body_Status;
  begin
    app_status := 0;
    for index in output'range loop
      output(index) := RT.output_byte (response, index);
    end loop;

    while position + P.HEADER_LENGTH - 1 <= output'last loop
      for offset in header_bytes'range loop
        header_bytes(offset) := output(position + offset);
      end loop;
      C.decode_header (header_bytes, header, decode_status);
      if decode_status /= C.Complete then
        return False;
      end if;

      if header.record_type = P.END_REQUEST_TYPE then
        if Natural(header.content_length) /= M.END_REQUEST_BODY_LENGTH or else
           position + P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH - 1 >
             output'last
        then
          return False;
        end if;

        for offset in body_bytes'range loop
          body_bytes(offset) :=
            output(position + P.HEADER_LENGTH + offset);
        end loop;
        M.decode_end_request (body_bytes, decoded_body, body_status);
        app_status := decoded_body.application_status;
        return
          body_status = M.Body_Complete and then
          decoded_body.protocol_status_code = P.REQUEST_COMPLETE_STATUS;
      end if;

      position :=
        position + P.HEADER_LENGTH +
        Natural(header.content_length) +
        Natural(header.padding_length);
    end loop;

    return False;
  end end_request_status;

  procedure direct_filter_sequence
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange
      (max_name_bytes => 64, max_value_bytes => 64);
    application : Filter_Application;
    response : R.Writer (max_output_bytes => 512);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    params : P.Byte_Array (1 .. 160);
    params_length : Natural;
    stdin_first : constant P.Byte_Array := to_bytes ("x");
    stdin_second : constant P.Byte_Array := to_bytes ("y");
    data_first : constant P.Byte_Array := to_bytes ("12");
    data_second : constant P.Byte_Array := to_bytes ("345");
    empty : P.Byte_Array (1 .. 0);
    status : R.Input_Status;
    app_status : Interfaces.Unsigned_32;
    end_status_ok : Boolean;
  begin
    encode_begin (begin_bytes);
    build_filter_params (params, params_length);

    drive_record
      (exchange, application, response,
       P.BEGIN_REQUEST_TYPE, begin_bytes, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "Filter BEGIN_REQUEST is accepted");

    drive_record
      (exchange, application, response,
       P.PARAMS_TYPE, params(1 .. 7), status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "fragmented Filter PARAMS first record completes");
    drive_record
      (exchange, application, response,
       P.PARAMS_TYPE, params(8 .. params_length), status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "fragmented Filter PARAMS second record completes");
    drive_record
      (exchange, application, response,
       P.PARAMS_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "Filter PARAMS EOF completes");

    drive_record
      (exchange, application, response,
       P.STDIN_TYPE, stdin_first, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "Filter STDIN first fragment is accepted");
    drive_record
      (exchange, application, response,
       P.STDIN_TYPE, stdin_second, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "Filter STDIN second fragment is accepted");
    drive_record
      (exchange, application, response,
       P.STDIN_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "Filter STDIN EOF enables output");

    drive_record
      (exchange, application, response,
       P.DATA_TYPE, data_first, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "Filter DATA first record is accepted");
    drive_record
      (exchange, application, response,
       P.DATA_TYPE, data_second, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "Filter DATA second record is accepted");
    drive_record
      (exchange, application, response,
       P.DATA_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Request_Complete,
       "Filter DATA EOF completes request");

    A.assert_equal_natural
      (reporter, application.parameter_count, 3,
       "Filter receives required and ordinary parameters");
    A.assert_equal_natural
      (reporter, application.stdin_bytes, 2,
       "Filter receives complete STDIN stream");
    A.assert_equal_natural
      (reporter, application.data_bytes, 5,
       "Filter receives complete DATA stream");
    A.assert_true
      (reporter,
       application.params_end_seen and then
       application.stdin_end_seen and then
       application.data_end_seen,
       "Filter receives all stream EOF callbacks");
    A.assert_true
      (reporter, application.role_seen = P.Filter,
       "Filter callbacks expose Filter role");
    A.assert_true
      (reporter, application.output_ok,
       "Filter may write after STDIN EOF and while receiving DATA");
    A.assert_true
      (reporter, R.is_complete(exchange),
       "Filter exchange is complete");
    end_status_ok := end_request_status(response, app_status);
    A.assert_true
      (reporter,
       end_status_ok and then app_status = 23,
       "Filter END_REQUEST preserves application status");
  end direct_filter_sequence;

  procedure filter_protocol_rejections
    (reporter : in out Clair.Test.Reporter.Context)
  is
    empty : P.Byte_Array (1 .. 0);
  begin
    declare
      exchange : R.Exchange
        (max_name_bytes => 64, max_value_bytes => 64);
      application : Filter_Application;
      response : R.Writer (max_output_bytes => 256);
      begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
      params : P.Byte_Array (1 .. 160);
      params_length : Natural;
      status : R.Input_Status;
    begin
      encode_begin (begin_bytes);
      build_filter_params (params, params_length);
      drive_record
        (exchange, application, response,
         P.BEGIN_REQUEST_TYPE, begin_bytes, status);
      drive_record
        (exchange, application, response,
         P.PARAMS_TYPE, params(1 .. params_length), status);
      drive_record
        (exchange, application, response,
         P.PARAMS_TYPE, empty, status);
      drive_record
        (exchange, application, response,
         P.DATA_TYPE, empty, status);
      A.assert_true
        (reporter, status = R.Invalid_Record_Sequence,
         "Filter rejects DATA before STDIN EOF");
    end;

    declare
      exchange : R.Exchange
        (max_name_bytes => 64, max_value_bytes => 64);
      application : Filter_Application;
      response : R.Writer (max_output_bytes => 256);
      begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
      params : P.Byte_Array (1 .. 160);
      params_length : Natural;
      status : R.Input_Status;
    begin
      application.write_on_params := True;
      encode_begin (begin_bytes);
      build_filter_params (params, params_length);
      drive_record
        (exchange, application, response,
         P.BEGIN_REQUEST_TYPE, begin_bytes, status);
      drive_record
        (exchange, application, response,
         P.PARAMS_TYPE, params(1 .. params_length), status);
      drive_record
        (exchange, application, response,
         P.PARAMS_TYPE, empty, status);
      A.assert_true
        (reporter,
         status = R.Output_Failed and then
         application.params_write_status = R.Output_Limit_Exceeded,
         "Filter output is blocked before STDIN EOF");
    end;

    declare
      exchange : R.Exchange
        (max_name_bytes => 64, max_value_bytes => 64);
      application : Filter_Application;
      response : R.Writer (max_output_bytes => 256);
      begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
      params : P.Byte_Array (1 .. 160);
      params_length : Natural;
      status : R.Input_Status;
    begin
      encode_begin (begin_bytes);
      build_filter_params
        (params, params_length, include_last_mod => False);
      drive_record
        (exchange, application, response,
         P.BEGIN_REQUEST_TYPE, begin_bytes, status);
      drive_record
        (exchange, application, response,
         P.PARAMS_TYPE, params(1 .. params_length), status);
      drive_record
        (exchange, application, response,
         P.PARAMS_TYPE, empty, status);
      A.assert_true
        (reporter, status = R.Malformed_Params,
         "Filter requires FCGI_DATA_LAST_MOD");
    end;

    declare
      exchange : R.Exchange
        (max_name_bytes => 64, max_value_bytes => 64);
      application : Filter_Application;
      response : R.Writer (max_output_bytes => 256);
      begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
      params : P.Byte_Array (1 .. 160);
      params_length : Natural;
      status : R.Input_Status;
    begin
      encode_begin (begin_bytes);
      build_filter_params
        (params, params_length, data_length => "12x");
      drive_record
        (exchange, application, response,
         P.BEGIN_REQUEST_TYPE, begin_bytes, status);
      drive_record
        (exchange, application, response,
         P.PARAMS_TYPE, params(1 .. params_length), status);
      A.assert_true
        (reporter, status = R.Malformed_Params,
         "Filter rejects malformed FCGI_DATA_LENGTH");
    end;
  end filter_protocol_rejections;

  procedure filter_data_length_validation
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange
      (max_name_bytes => 64, max_value_bytes => 64);
    application : Filter_Application;
    response : R.Writer (max_output_bytes => 256);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    params : P.Byte_Array (1 .. 160);
    params_length : Natural;
    too_much : constant P.Byte_Array := to_bytes ("1234");
    empty : P.Byte_Array (1 .. 0);
    status : R.Input_Status;
  begin
    encode_begin (begin_bytes);
    build_filter_params (params, params_length, data_length => "3");
    drive_record
      (exchange, application, response,
       P.BEGIN_REQUEST_TYPE, begin_bytes, status);
    drive_record
      (exchange, application, response,
       P.PARAMS_TYPE, params(1 .. params_length), status);
    drive_record
      (exchange, application, response,
       P.PARAMS_TYPE, empty, status);
    drive_record
      (exchange, application, response,
       P.STDIN_TYPE, empty, status);
    A.assert_true
      (reporter, status = R.Record_Complete,
       "Filter STDIN EOF precedes DATA length validation");

    drive_record
      (exchange, application, response,
       P.DATA_TYPE, too_much, status);
    A.assert_true
      (reporter, status = R.Invalid_Content_Length,
       "Filter rejects DATA beyond FCGI_DATA_LENGTH");
    A.assert_equal_natural
      (reporter, application.data_bytes, 0,
       "over-limit Filter DATA is not delivered");

    declare
      short_exchange : R.Exchange
        (max_name_bytes => 64, max_value_bytes => 64);
      short_application : Filter_Application;
      short_response : R.Writer (max_output_bytes => 256);
      short_begin : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
      short_params : P.Byte_Array (1 .. 160);
      short_params_length : Natural;
      short_data : constant P.Byte_Array := to_bytes ("123");
      short_status : R.Input_Status;
    begin
      encode_begin (short_begin);
      build_filter_params
        (short_params, short_params_length, data_length => "5");
      drive_record
        (short_exchange, short_application, short_response,
         P.BEGIN_REQUEST_TYPE, short_begin, short_status);
      drive_record
        (short_exchange, short_application, short_response,
         P.PARAMS_TYPE, short_params(1 .. short_params_length), short_status);
      drive_record
        (short_exchange, short_application, short_response,
         P.PARAMS_TYPE, empty, short_status);
      drive_record
        (short_exchange, short_application, short_response,
         P.STDIN_TYPE, empty, short_status);
      drive_record
        (short_exchange, short_application, short_response,
         P.DATA_TYPE, short_data, short_status);
      drive_record
        (short_exchange, short_application, short_response,
         P.DATA_TYPE, empty, short_status);

      A.assert_true
        (reporter, short_status = R.Request_Complete,
         "short Filter DATA reaches application for policy handling");
      A.assert_equal_natural
        (reporter, short_application.data_bytes, short_data'length,
         "short Filter DATA is delivered rather than treated as framing error");
    end;
  end filter_data_length_validation;

  procedure filter_cache_shortcut
    (reporter : in out Clair.Test.Reporter.Context)
  is
    exchange : R.Exchange
      (max_name_bytes => 64, max_value_bytes => 64);
    application : Filter_Application;
    response : R.Writer (max_output_bytes => 256);
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    params : P.Byte_Array (1 .. 160);
    params_length : Natural;
    empty : P.Byte_Array (1 .. 0);
    status : R.Input_Status;
  begin
    application.finish_on_stdin_end := True;
    application.finish_status_value := 0;
    encode_begin (begin_bytes);
    build_filter_params (params, params_length, data_length => "999");

    drive_record
      (exchange, application, response,
       P.BEGIN_REQUEST_TYPE, begin_bytes, status);
    drive_record
      (exchange, application, response,
       P.PARAMS_TYPE, params(1 .. params_length), status);
    drive_record
      (exchange, application, response,
       P.PARAMS_TYPE, empty, status);
    drive_record
      (exchange, application, response,
       P.STDIN_TYPE, empty, status);

    A.assert_true
      (reporter, status = R.Request_Complete,
       "Filter may finish from cache at STDIN EOF without reading DATA");
    A.assert_true
      (reporter,
       application.stdin_end_seen and then not application.data_end_seen,
       "cache shortcut does not require DATA callbacks");
    A.assert_true
      (reporter, application.output_ok,
       "cache shortcut output finalizes normally");
  end filter_cache_shortcut;

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
          raise Program_Error with "Filter output buffer overflow";
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

  procedure runtime_fragmented_filter
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor : aliased E.Context;
    application : aliased Filter_Application;
    connection : aliased RC.Context
      (max_requests_per_connection => 1,
       max_name_bytes              => 64,
       max_value_bytes             => 64,
       max_request_output_bytes    => 512,
       max_output_bytes            => 512,
       read_buffer_bytes           => 8,
       write_chunk_bytes           => 7);
    runtime_raw : aliased Interfaces.C.int := -1;
    peer_raw : aliased Interfaces.C.int := -1;
    runtime_fd : Clair.IO.Descriptor;
    peer_fd : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status : Clair.Status.Code;
    dispatched : Boolean;
    begin_bytes : P.Byte_Array (0 .. M.BEGIN_REQUEST_BODY_LENGTH - 1);
    params : P.Byte_Array (1 .. 160);
    params_length : Natural;
    stdin_data : constant P.Byte_Array := to_bytes ("abcdefghijkl");
    data_data : constant P.Byte_Array := to_bytes ("12345678901234567890");
    empty : P.Byte_Array (1 .. 0);
    input : P.Byte_Array (1 .. 384);
    input_position : Positive := input'first;
    output : P.Byte_Array (1 .. 512);
    output_length : Natural := 0;
  begin
    encode_begin (begin_bytes);
    build_filter_params (params, params_length, data_length => "20");

    native_error := c_socketpair (runtime_raw'access, peer_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "Filter socketpair is created");
    runtime_fd := Clair.IO.Descriptor(runtime_raw);
    peer_fd := Clair.IO.Descriptor(peer_raw);
    A.assert_true
      (reporter, drain_peer(peer_fd) > 0,
       "Filter socket fixture prefill is discarded");

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Filter event loop initializes");
    status := E.initialize
      (executor,
       event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 64,
       max_output_bytes => 512);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Filter executor initializes");
    status := RC.initialize
      (connection,
       event_loop'Unchecked_Access,
       runtime_fd,
       application'Unchecked_Access,
       executor'Unchecked_Access,
       request_timeout => 60_000,
       connection_id   => 40);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Filter connection initializes");

    append_record
      (input, input_position, P.BEGIN_REQUEST_TYPE, begin_bytes);
    append_record
      (input, input_position, P.PARAMS_TYPE,
       params(1 .. params_length));
    append_record
      (input, input_position, P.PARAMS_TYPE, empty);
    append_record
      (input, input_position, P.STDIN_TYPE, stdin_data);
    append_record
      (input, input_position, P.STDIN_TYPE, empty);
    append_record
      (input, input_position, P.DATA_TYPE, data_data(1 .. 9));
    append_record
      (input, input_position, P.DATA_TYPE, data_data(10 .. data_data'last));
    append_record
      (input, input_position, P.DATA_TYPE, empty);

    status := write_all
      (peer_fd, input(input'first .. input_position - 1));
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "fragmented Filter request is written");

    for attempt in 1 .. 400 loop
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
       "fragmented Filter runtime dispatch succeeds");
    A.assert_equal_natural
      (reporter, application.parameter_count, 3,
       "runtime Filter receives all PARAMS");
    A.assert_equal_natural
      (reporter, application.stdin_bytes, stdin_data'length,
       "runtime Filter receives fragmented STDIN");
    A.assert_equal_natural
      (reporter, application.data_bytes, data_data'length,
       "runtime Filter receives fragmented DATA");
    A.assert_true
      (reporter,
       application.stdin_end_seen and then application.data_end_seen,
       "runtime Filter receives both stream EOF callbacks");
    A.assert_true
      (reporter, application.role_seen = P.Filter,
       "runtime Filter preserves role through executor");
    A.assert_true
      (reporter, application.output_ok,
       "runtime Filter writes during DATA and finishes");
    A.assert_true
      (reporter, output_length > 0,
       "runtime Filter emits FastCGI output");

    status := RC.finalize (connection);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Filter connection finalizes");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Filter executor begins shutdown");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Filter executor finalizes");
    status := Clair.IO.close (peer_fd);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Filter peer closes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "Filter event loop finalizes");
  end runtime_fragmented_filter;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "direct Filter sequence",
       direct_filter_sequence'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "Filter protocol rejections",
       filter_protocol_rejections'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "Filter DATA length validation",
       filter_data_length_validation'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "Filter cache shortcut",
       filter_cache_shortcut'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "runtime fragmented Filter",
       runtime_fragmented_filter'access);
  end run;

end Tests.Filter;
