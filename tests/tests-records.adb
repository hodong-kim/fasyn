-- ============================================================================
-- tests-records.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces;
with Clair.Test.Assertions;
with Fasyn.Protocol;
with Fasyn.Protocol.Codec;

package body Tests.Records is

  use type Interfaces.Unsigned_32;
  use type Fasyn.Protocol.Codec.Record_Event;

  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package A renames Clair.Test.Assertions;

  procedure content_and_padding
    (reporter : in out Clair.Test.Reporter.Context)
  is
    source : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => P.PARAMS_TYPE,
       request_id     => 7,
       content_length => 3,
       padding_length => 2,
       reserved       => 0);
    bytes         : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    decoder       : C.Record_Decoder;
    event         : C.Record_Event;
    record_header : P.Header;
    status        : C.Decode_Status;
  begin
    C.encode_header (source, bytes);

    for index in bytes'range loop
      C.feed (decoder, bytes(index), event, record_header, status);
    end loop;

    A.assert_true
      (reporter, event = C.Header_Ready,
       "record header completes before content");
    A.assert_false
      (reporter, C.record_complete (decoder),
       "record is incomplete while content remains");

    C.feed (decoder, 16#a1#, event, record_header, status);
    A.assert_true (reporter, event = C.Content_Byte, "first content byte");
    C.feed (decoder, 16#a2#, event, record_header, status);
    A.assert_true (reporter, event = C.Content_Byte, "second content byte");
    C.feed (decoder, 16#a3#, event, record_header, status);
    A.assert_true (reporter, event = C.Content_Byte, "third content byte");
    A.assert_false
      (reporter, C.record_complete (decoder),
       "padding still prevents record completion");

    C.feed (decoder, 0, event, record_header, status);
    A.assert_true (reporter, event = C.Padding_Byte, "first padding byte");
    A.assert_false
      (reporter, C.record_complete (decoder),
       "record waits for final padding byte");

    C.feed (decoder, 0, event, record_header, status);
    A.assert_true (reporter, event = C.Padding_Byte, "second padding byte");
    A.assert_true
      (reporter, C.record_complete (decoder),
       "record completes after final padding byte");
  end content_and_padding;

  procedure deterministic_record_fuzz
    (reporter : in out Clair.Test.Reporter.Context)
  is
    decoder : C.Record_Decoder;
    event : C.Record_Event;
    record_header : P.Header;
    status : C.Decode_Status;
    state : Interfaces.Unsigned_32 := 16#c001_d00d#;
    decode_errors : Natural := 0;
  begin
    for sample in 1 .. 50_000 loop
      pragma Unreferenced (sample);
      state := state * 1_664_525 + 1_013_904_223;
      C.feed
        (decoder, P.Byte(state mod 256), event, record_header, status);
      if event = C.Decode_Error then
        decode_errors := decode_errors + 1;
        C.reset (decoder);
      end if;
    end loop;

    A.assert_positive
      (reporter, Integer(decode_errors),
       "arbitrary record bytes exercise clean decode-error paths");
  end deterministic_record_fuzz;

  procedure maximum_record_boundaries
    (reporter : in out Clair.Test.Reporter.Context)
  is
    source : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => P.STDIN_TYPE,
       request_id     => 1,
       content_length => P.Content_Length_Type'Last,
       padding_length => P.Byte'Last,
       reserved       => 0);
    bytes         : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    decoder       : C.Record_Decoder;
    event         : C.Record_Event;
    record_header : P.Header;
    status        : C.Decode_Status;
    content_seen  : Natural := 0;
    padding_seen  : Natural := 0;
  begin
    C.encode_header (source, bytes);
    for value of bytes loop
      C.feed (decoder, value, event, record_header, status);
    end loop;

    for index in 1 .. 65_535 loop
      pragma Unreferenced (index);
      C.feed (decoder, 16#a5#, event, record_header, status);
      if event = C.Content_Byte then
        content_seen := content_seen + 1;
      end if;
    end loop;

    A.assert_equal_natural
      (reporter, content_seen, 65_535,
       "maximum FastCGI content length is consumed exactly");
    A.assert_false
      (reporter, C.record_complete(decoder),
       "maximum record waits for declared padding");

    for index in 1 .. 255 loop
      pragma Unreferenced (index);
      C.feed (decoder, 0, event, record_header, status);
      if event = C.Padding_Byte then
        padding_seen := padding_seen + 1;
      end if;
    end loop;

    A.assert_equal_natural
      (reporter, padding_seen, 255,
       "maximum FastCGI padding length is consumed exactly");
    A.assert_true
      (reporter, C.record_complete(decoder),
       "maximum record completes at the exact wire boundary");

    C.feed (decoder, bytes(bytes'first), event, record_header, status);
    A.assert_true
      (reporter, event = C.Header_Progress,
       "next record starts immediately after maximum record boundary");
  end maximum_record_boundaries;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter, "content and padding", content_and_padding'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "deterministic record fuzz",
       deterministic_record_fuzz'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "maximum record boundaries",
       maximum_record_boundaries'access);
  end run;

end Tests.Records;
