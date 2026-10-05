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
  use type Fasyn.Protocol.Codec.Decode_Status;
  use type Fasyn.Protocol.Codec.Record_Event;

  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package A renames Clair.Test.Assertions;

  procedure content_and_padding
    (reporter : in out Clair.Test.Reporter.Context)
  is
    source : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => P.PARAMS,
       request_id     => 7,
       content_length => 3,
       padding_length => 2);
    bytes         : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    decoder       : C.Record_Decoder;
    event         : C.Record_Event;
    record_header : P.Header;
    status        : C.Decode_Status;
  begin
    C.encode_header (source, bytes);

    for index in bytes'range loop
      status := C.feed (decoder, bytes(index), event, record_header);
    end loop;

    A.assert_true
      (reporter, status = C.Complete and then event = C.Header_Ready,
       "record header completes before content");
    A.assert_false
      (reporter, C.is_complete (decoder),
       "record is incomplete while content remains");

    status := C.feed (decoder, 16#a1#, event, record_header);
    A.assert_true
      (reporter, status = C.Complete and then event = C.Content_Byte,
       "first content byte");
    status := C.feed (decoder, 16#a2#, event, record_header);
    A.assert_true
      (reporter, status = C.Complete and then event = C.Content_Byte,
       "second content byte");
    status := C.feed (decoder, 16#a3#, event, record_header);
    A.assert_true
      (reporter, status = C.Complete and then event = C.Content_Byte,
       "third content byte");
    A.assert_false
      (reporter, C.is_complete (decoder),
       "padding still prevents record completion");

    status := C.feed (decoder, 0, event, record_header);
    A.assert_true
      (reporter, status = C.Complete and then event = C.Padding_Byte,
       "first padding byte");
    A.assert_false
      (reporter, C.is_complete (decoder),
       "record waits for final padding byte");

    status := C.feed (decoder, 0, event, record_header);
    A.assert_true
      (reporter, status = C.Complete and then event = C.Padding_Byte,
       "second padding byte");
    A.assert_true
      (reporter, C.is_complete (decoder),
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
    decode_errors    : Natural := 0;
    status_mismatches : Natural := 0;
  begin
    for sample in 1 .. 50_000 loop
      pragma Unreferenced (sample);
      state := state * 1_664_525 + 1_013_904_223;
      status := C.feed
        (decoder, P.Byte(state mod 256), event, record_header);
      if event = C.Decode_Error then
        if status = C.Complete or else status = C.Need_More_Data then
          status_mismatches := status_mismatches + 1;
        end if;
        decode_errors := decode_errors + 1;
        C.reset (decoder);
      elsif status /= C.Complete and then status /= C.Need_More_Data then
        status_mismatches := status_mismatches + 1;
      end if;
    end loop;

    A.assert_positive
      (reporter, Integer(decode_errors),
       "arbitrary record bytes exercise clean decode-error paths");
    A.assert_equal_natural
      (reporter, status_mismatches, 0,
       "record events and decode status remain consistent under fuzz");
  end deterministic_record_fuzz;

  procedure maximum_record_boundaries
    (reporter : in out Clair.Test.Reporter.Context)
  is
    source : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => P.STDIN,
       request_id     => 1,
       content_length => P.Content_Length'Last,
       padding_length => P.Byte'Last);
    bytes         : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    decoder       : C.Record_Decoder;
    event         : C.Record_Event;
    record_header : P.Header;
    status        : C.Decode_Status;
    content_seen  : Natural := 0;
    padding_seen  : Natural := 0;
    status_errors : Natural := 0;
  begin
    C.encode_header (source, bytes);
    for value of bytes loop
      status := C.feed (decoder, value, event, record_header);
    end loop;

    A.assert_true
      (reporter, status = C.Complete and then event = C.Header_Ready,
       "maximum record header is ready before content");

    for index in 1 .. 65_535 loop
      pragma Unreferenced (index);
      status := C.feed (decoder, 16#a5#, event, record_header);
      if status /= C.Complete then
        status_errors := status_errors + 1;
      end if;
      if event = C.Content_Byte then
        content_seen := content_seen + 1;
      end if;
    end loop;

    A.assert_equal_natural
      (reporter, content_seen, 65_535,
       "maximum FastCGI content length is consumed exactly");
    A.assert_false
      (reporter, C.is_complete(decoder),
       "maximum record waits for declared padding");

    for index in 1 .. 255 loop
      pragma Unreferenced (index);
      status := C.feed (decoder, 0, event, record_header);
      if status /= C.Complete then
        status_errors := status_errors + 1;
      end if;
      if event = C.Padding_Byte then
        padding_seen := padding_seen + 1;
      end if;
    end loop;

    A.assert_equal_natural
      (reporter, padding_seen, 255,
       "maximum FastCGI padding length is consumed exactly");
    A.assert_equal_natural
      (reporter, status_errors, 0,
       "maximum record content and padding keep Complete decode status");
    A.assert_true
      (reporter, C.is_complete(decoder),
       "maximum record completes at the exact wire boundary");

    status := C.feed (decoder, bytes(bytes'first), event, record_header);
    A.assert_true
      (reporter, status = C.Need_More_Data and then event = C.Header_Progress,
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
