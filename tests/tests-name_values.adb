-- ============================================================================
-- tests-name_values.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces;
with Clair.Test.Assertions;
with Fasyn.Protocol;
with Fasyn.Protocol.Name_Values;

package body Tests.Name_Values is

  use type Interfaces.Unsigned_8;
  use type Interfaces.Unsigned_32;
  use type Fasyn.Protocol.Name_Values.Encode_Status;
  use type Fasyn.Protocol.Name_Values.Feed_Status;

  package P renames Fasyn.Protocol;
  package N renames Fasyn.Protocol.Name_Values;
  package A renames Clair.Test.Assertions;

  procedure check_round_trip
    (reporter    : in out Clair.Test.Reporter.Context;
     name_count  : Natural;
     value_count : Natural)
  is
    name : constant P.Byte_Array (1 .. name_count) :=
      [for index in 1 .. name_count => P.Byte((index * 17) mod 256)];
    value : constant P.Byte_Array (1 .. value_count) :=
      [for index in 1 .. value_count => P.Byte((index * 29) mod 256)];
    required : constant Natural := N.encoded_size (name_count, value_count);
    encoded : P.Byte_Array (0 .. required - 1);
    written : Natural;
    encode_status : N.Encode_Status;
    decoder : N.Decoder
      (max_name_bytes  => (if name_count = 0 then 1 else name_count),
       max_value_bytes => (if value_count = 0 then 1 else value_count));
    feed_status : N.Feed_Status := N.Progress;
    visited     : Boolean := False;

    procedure inspect_pair
      (view_name  : in P.Byte_Array;
       view_value : in P.Byte_Array)
    is
      name_matches  : Boolean := view_name'length = name'length;
      value_matches : Boolean := view_value'length = value'length;
    begin
      visited := True;

      if name_matches then
        for index in view_name'range loop
          if view_name(index) /= name(index) then
            name_matches := False;
            exit;
          end if;
        end loop;
      end if;
      if value_matches then
        for index in view_value'range loop
          if view_value(index) /= value(index) then
            value_matches := False;
            exit;
          end if;
        end loop;
      end if;

      A.assert_true
        (reporter, name_matches,
         "borrowed name aliases exact decoded storage");
      A.assert_true
        (reporter, value_matches,
         "borrowed value aliases exact decoded storage");
    end inspect_pair;
  begin
    encode_status := N.encode_pair
      (name    => name,
       value   => value,
       output  => encoded,
       written => written);

    A.assert_true
      (reporter, encode_status = N.Encode_Complete,
       "name-value encoding completes");
    A.assert_equal_natural
      (reporter, written, required, "encoded size matches required size");

    for index in encoded'range loop
      feed_status := N.feed (decoder, encoded(index));
    end loop;

    A.assert_true
      (reporter, feed_status = N.Pair_Complete,
       "encoded pair decodes incrementally");
    A.assert_equal_natural
      (reporter, N.name_length (decoder), name_count,
       "decoded name length matches");
    A.assert_equal_natural
      (reporter, N.value_length (decoder), value_count,
       "decoded value length matches");

    for index in name'range loop
      A.assert_true
        (reporter, N.name_byte (decoder, index) = name(index),
         "decoded name byte matches encoded input");
    end loop;

    for index in value'range loop
      A.assert_true
        (reporter, N.value_byte (decoder, index) = value(index),
         "decoded value byte matches encoded input");
    end loop;

    N.visit_pair (decoder, inspect_pair'Access);
    A.assert_true
      (reporter, visited, "completed pair is visited synchronously");
  end check_round_trip;

  procedure boundary_round_trips
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    check_round_trip (reporter, 0, 0);
    check_round_trip (reporter, 1, 1);
    check_round_trip (reporter, 127, 0);
    check_round_trip (reporter, 128, 1);
    check_round_trip (reporter, 255, 128);
  end boundary_round_trips;

  procedure output_limit
    (reporter : in out Clair.Test.Reporter.Context)
  is
    name : constant P.Byte_Array (1 .. 1) := [1 => 16#41#];
    value : constant P.Byte_Array (1 .. 1) := [1 => 16#42#];
    output : P.Byte_Array (0 .. 2);
    written : Natural;
    status : N.Encode_Status;
  begin
    status := N.encode_pair (name, value, output, written);
    A.assert_true
      (reporter, status = N.Output_Too_Small,
       "encoder rejects undersized output buffer");
    A.assert_equal_natural
      (reporter, written, 0, "failed encode writes zero bytes");
  end output_limit;

  procedure decode_limit
    (reporter : in out Clair.Test.Reporter.Context)
  is
    decoder : N.Decoder
      (max_name_bytes  => 4,
       max_value_bytes => 4);
    status : N.Feed_Status;
  begin
    status := N.feed (decoder, 5);
    A.assert_true
      (reporter, status = N.Limit_Exceeded,
       "decoder rejects declared name above policy limit");

    declare
      misuse_rejected : Boolean := False;
    begin
      begin
        status := N.feed (decoder, 0);
      exception
        when Program_Error =>
          misuse_rejected := True;
      end;
      A.assert_true
        (reporter, misuse_rejected,
         "terminal decoder rejects feed before reset");
    end;
  end decode_limit;

  procedure deterministic_property_sweep
    (reporter : in out Clair.Test.Reporter.Context)
  is
    state       : Interfaces.Unsigned_32 := 16#5a17_c3e9#;
    name_count  : Natural;
    value_count : Natural;
  begin
    for sample in 1 .. 64 loop
      pragma Unreferenced (sample);
      state := state * 1_664_525 + 1_013_904_223;
      name_count := Natural(state mod 257);
      state := state * 1_664_525 + 1_013_904_223;
      value_count := Natural(state mod 257);
      check_round_trip (reporter, name_count, value_count);
    end loop;
  end deterministic_property_sweep;

  procedure deterministic_byte_fuzz
    (reporter : in out Clair.Test.Reporter.Context)
  is
    decoder : N.Decoder (max_name_bytes => 32, max_value_bytes => 32);
    state : Interfaces.Unsigned_32 := 16#91e1_0da5#;
    status : N.Feed_Status;
    terminal_states : Natural := 0;
  begin
    for sample in 1 .. 20_000 loop
      pragma Unreferenced (sample);
      state := state * 1_664_525 + 1_013_904_223;
      status := N.feed (decoder, P.Byte(state mod 256));
      case status is
        when N.Progress =>
          null;
        when N.Pair_Complete | N.Limit_Exceeded | N.Malformed_Length =>
          terminal_states := terminal_states + 1;
          N.reset (decoder);
      end case;
    end loop;

    A.assert_positive
      (reporter, Integer(terminal_states),
       "arbitrary byte fuzz exercises bounded terminal states");
  end deterministic_byte_fuzz;

  procedure noncanonical_long_lengths
    (reporter : in out Clair.Test.Reporter.Context)
  is
    decoder : N.Decoder (max_name_bytes => 32, max_value_bytes => 32);
    status  : N.Feed_Status;
  begin
    status := N.feed (decoder, 16#80#);
    A.assert_true (reporter, status = N.Progress, "long name length byte one");
    status := N.feed (decoder, 0);
    A.assert_true (reporter, status = N.Progress, "long name length byte two");
    status := N.feed (decoder, 0);
    A.assert_true (reporter, status = N.Progress, "long name length byte three");
    status := N.feed (decoder, 1);
    A.assert_true
      (reporter, status = N.Malformed_Length,
       "four-byte name length below 128 is rejected as noncanonical");

    N.reset (decoder);
    status := N.feed (decoder, 0);
    A.assert_true (reporter, status = N.Progress, "empty name length is accepted");
    status := N.feed (decoder, 16#80#);
    A.assert_true (reporter, status = N.Progress, "long value length byte one");
    status := N.feed (decoder, 0);
    A.assert_true (reporter, status = N.Progress, "long value length byte two");
    status := N.feed (decoder, 0);
    A.assert_true (reporter, status = N.Progress, "long value length byte three");
    status := N.feed (decoder, 1);
    A.assert_true
      (reporter, status = N.Malformed_Length,
       "four-byte value length below 128 is rejected as noncanonical");
  end noncanonical_long_lengths;

  procedure zero_resident_limits
    (reporter : in out Clair.Test.Reporter.Context)
  is
    decoder : N.Decoder (max_name_bytes => 0, max_value_bytes => 0);
    status  : N.Feed_Status;
  begin
    status := N.feed (decoder, 0);
    A.assert_true
      (reporter, status = N.Progress,
       "zero-bound decoder accepts an empty name length");
    status := N.feed (decoder, 0);
    A.assert_true
      (reporter, status = N.Pair_Complete,
       "zero-bound decoder accepts an empty name-value pair");
    A.assert_equal_natural
      (reporter, N.name_length(decoder), 0,
       "zero-bound decoder reports empty name");
    A.assert_equal_natural
      (reporter, N.value_length(decoder), 0,
       "zero-bound decoder reports empty value");

    N.reset (decoder);
    status := N.feed (decoder, 1);
    A.assert_true
      (reporter, status = N.Limit_Exceeded,
       "zero name bound rejects the first non-empty name");

    N.reset (decoder);
    status := N.feed (decoder, 0);
    A.assert_true
      (reporter, status = N.Progress,
       "zero-bound decoder reaccepts an empty name after reset");
    status := N.feed (decoder, 1);
    A.assert_true
      (reporter, status = N.Limit_Exceeded,
       "zero value bound rejects the first non-empty value");
  end zero_resident_limits;

  procedure declared_length_limits
    (reporter : in out Clair.Test.Reporter.Context)
  is
    below : N.Decoder (max_name_bytes => 4, max_value_bytes => 4);
    exact : N.Decoder (max_name_bytes => 4, max_value_bytes => 4);
    above : N.Decoder (max_name_bytes => 4, max_value_bytes => 4);
    huge  : N.Decoder (max_name_bytes => 4, max_value_bytes => 4);
    status : N.Feed_Status;
  begin
    status := N.feed (below, 3);
    A.assert_true
      (reporter, status = N.Progress, "name below policy limit is accepted");

    status := N.feed (exact, 4);
    A.assert_true
      (reporter, status = N.Progress,
       "name exactly at policy limit is accepted");

    status := N.feed (above, 5);
    A.assert_true
      (reporter, status = N.Limit_Exceeded,
       "name immediately above policy limit is rejected");

    status := N.feed (huge, 16#ff#);
    A.assert_true (reporter, status = N.Progress, "31-bit length byte one");
    status := N.feed (huge, 16#ff#);
    A.assert_true (reporter, status = N.Progress, "31-bit length byte two");
    status := N.feed (huge, 16#ff#);
    A.assert_true (reporter, status = N.Progress, "31-bit length byte three");
    status := N.feed (huge, 16#ff#);
    A.assert_true
      (reporter, status = N.Limit_Exceeded,
       "maximum 31-bit declared length is rejected before allocation");
  end declared_length_limits;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter, "boundary round trips", boundary_round_trips'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "output limit", output_limit'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "decode limit", decode_limit'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deterministic round-trip property sweep",
       deterministic_property_sweep'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "deterministic byte fuzz", deterministic_byte_fuzz'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "noncanonical long lengths", noncanonical_long_lengths'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "zero resident limits", zero_resident_limits'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "declared length limits", declared_length_limits'access);
  end run;

end Tests.Name_Values;
