-- ============================================================================
-- tests-protocol.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Test.Assertions;
with Fasyn.Protocol;
with Fasyn.Protocol.Codec;

package body Tests.Protocol is

  use type Fasyn.Protocol.Codec.Decode_Status;

  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package A renames Clair.Test.Assertions;

  procedure header_round_trip
    (reporter : in out Clair.Test.Reporter.Context)
  is
    source : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => P.PARAMS_TYPE,
       request_id     => 16#1234#,
       content_length => 16#4567#,
       padding_length => 8,
       reserved       => 0);
    bytes   : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    decoded : P.Header;
    status  : C.Decode_Status;
  begin
    C.encode_header (source, bytes);
    C.decode_header (bytes, decoded, status);

    A.assert_true (reporter, status = C.Complete, "header decode completes");
    A.assert_equal_integer
      (reporter, Integer(decoded.request_id), Integer(source.request_id),
       "request id round trips");
    A.assert_equal_integer
      (reporter,
       Integer(decoded.content_length),
       Integer(source.content_length),
       "content length round trips");
    A.assert_equal_integer
      (reporter,
       Integer(decoded.padding_length),
       Integer(source.padding_length),
       "padding length round trips");
  end header_round_trip;

  procedure incremental_header
    (reporter : in out Clair.Test.Reporter.Context)
  is
    source : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => P.STDIN_TYPE,
       request_id     => 42,
       content_length => 3,
       padding_length => 5,
       reserved       => 0);
    bytes   : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    decoder : C.Header_Decoder;
    decoded : P.Header;
    status  : C.Decode_Status;
  begin
    C.encode_header (source, bytes);

    for index in bytes'range loop
      C.feed (decoder, bytes(index), decoded, status);

      if index < bytes'last then
        A.assert_true
          (reporter, status = C.Need_More_Data,
           "partial header requires more data");
      else
        A.assert_true
          (reporter, status = C.Complete,
           "eighth header byte completes decode");
      end if;
    end loop;

    A.assert_equal_integer
      (reporter, Integer(decoded.request_id), Integer(source.request_id),
       "incremental request id round trips");
  end incremental_header;

  procedure header_validation
    (reporter : in out Clair.Test.Reporter.Context)
  is
    bytes         : P.Byte_Array (0 .. P.HEADER_LENGTH - 1) := [others => 0];
    record_header : P.Header;
    status        : C.Decode_Status;
  begin
    bytes(0) := 2;
    bytes(1) := P.PARAMS_TYPE;
    bytes(3) := 1;
    C.decode_header (bytes, record_header, status);
    A.assert_true
      (reporter, status = C.Unsupported_Version,
       "unsupported FastCGI version is rejected");

    bytes(0) := P.VERSION_1;
    bytes(3) := 0;
    C.decode_header (bytes, record_header, status);
    A.assert_true
      (reporter, status = C.Invalid_Request_Id_Domain,
       "application record rejects null request id");

    bytes(1) := P.GET_VALUES_TYPE;
    C.decode_header (bytes, record_header, status);
    A.assert_true
      (reporter, status = C.Complete,
       "management record accepts null request id");
  end header_validation;

  procedure wire_boundaries
    (reporter : in out Clair.Test.Reporter.Context)
  is
    source : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => P.PARAMS_TYPE,
       request_id     => P.Request_Id_Type'Last,
       content_length => P.Content_Length_Type'Last,
       padding_length => P.Byte'Last,
       reserved       => P.Byte'Last);
    bytes   : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    short   : P.Byte_Array (0 .. P.HEADER_LENGTH - 2);
    decoded : P.Header;
    status  : C.Decode_Status;
  begin
    C.encode_header (source, bytes);
    C.decode_header (bytes, decoded, status);
    A.assert_true
      (reporter, status = C.Complete, "maximum wire header decodes");
    A.assert_equal_integer
      (reporter, Integer(decoded.request_id), 65_535,
       "maximum request id is preserved");
    A.assert_equal_integer
      (reporter, Integer(decoded.content_length), 65_535,
       "maximum content length is preserved");
    A.assert_equal_integer
      (reporter, Integer(decoded.padding_length), 255,
       "maximum padding length is preserved");

    short := bytes(short'range);
    C.decode_header (short, decoded, status);
    A.assert_true
      (reporter, status = C.Need_More_Data,
       "seven header bytes remain incomplete");
  end wire_boundaries;

  procedure request_id_domains
    (reporter : in out Clair.Test.Reporter.Context)
  is
    type Type_List is array (Positive range <>) of P.Byte;
    application_types : constant Type_List :=
      [P.BEGIN_REQUEST_TYPE, P.ABORT_REQUEST_TYPE, P.END_REQUEST_TYPE,
       P.PARAMS_TYPE, P.STDIN_TYPE, P.STDOUT_TYPE, P.STDERR_TYPE,
       P.DATA_TYPE];
    management_types : constant Type_List :=
      [P.GET_VALUES_TYPE, P.GET_VALUES_RESULT_TYPE, P.UNKNOWN_TYPE_TYPE];
    bytes         : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    record_header : P.Header;
    status        : C.Decode_Status;
  begin
    for record_type of application_types loop
      C.encode_header
        ((version => P.VERSION_1, record_type => record_type, request_id => 0,
          content_length => 0, padding_length => 0, reserved => 0), bytes);
      C.decode_header (bytes, record_header, status);
      A.assert_true
        (reporter, status = C.Invalid_Request_Id_Domain,
         "application record rejects request id zero");
    end loop;

    for record_type of management_types loop
      C.encode_header
        ((version => P.VERSION_1, record_type => record_type, request_id => 1,
          content_length => 0, padding_length => 0, reserved => 0), bytes);
      C.decode_header (bytes, record_header, status);
      A.assert_true
        (reporter, status = C.Invalid_Request_Id_Domain,
         "management record rejects nonzero request id");
    end loop;

    C.encode_header
      ((version => P.VERSION_1, record_type => 99, request_id => 0,
        content_length => 0, padding_length => 0, reserved => 0), bytes);
    C.decode_header (bytes, record_header, status);
    A.assert_true
      (reporter, status = C.Complete,
       "unknown management type accepts request id zero");

    bytes(3) := 1;
    C.decode_header (bytes, record_header, status);
    A.assert_true
      (reporter, status = C.Invalid_Request_Id_Domain,
       "unknown record type rejects nonzero request id");
  end request_id_domains;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter, "header round trip", header_round_trip'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "incremental header", incremental_header'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "header validation", header_validation'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "wire boundaries", wire_boundaries'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "request id domains", request_id_domains'access);
  end run;

end Tests.Protocol;
