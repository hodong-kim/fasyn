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
  begin
    N.encode_pair
      (name    => name,
       value   => value,
       output  => encoded,
       written => written,
       status  => encode_status);

    A.assert_true
      (reporter, encode_status = N.Encode_Complete,
       "name-value encoding completes");
    A.assert_equal_natural
      (reporter, written, required, "encoded size matches required size");

    for index in encoded'range loop
      N.feed (decoder, encoded(index), feed_status);
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
    N.encode_pair (name, value, output, written, status);
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
    N.feed (decoder, 5, status);
    A.assert_true
      (reporter, status = N.Limit_Exceeded,
       "decoder rejects declared name above policy limit");
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
    invalid_states : Natural := 0;
    terminal_states : Natural := 0;
  begin
    for sample in 1 .. 20_000 loop
      pragma Unreferenced (sample);
      state := state * 1_664_525 + 1_013_904_223;
      N.feed (decoder, P.Byte(state mod 256), status);
      case status is
        when N.Progress =>
          null;
        when N.Pair_Complete | N.Limit_Exceeded =>
          terminal_states := terminal_states + 1;
          N.reset (decoder);
        when N.Invalid_State =>
          invalid_states := invalid_states + 1;
          N.reset (decoder);
      end case;
    end loop;

    A.assert_equal_natural
      (reporter, invalid_states, 0,
       "arbitrary byte fuzz never enters an unhandled decoder state");
    A.assert_positive
      (reporter, Integer(terminal_states),
       "arbitrary byte fuzz exercises bounded terminal states");
  end deterministic_byte_fuzz;

  procedure declared_length_limits
    (reporter : in out Clair.Test.Reporter.Context)
  is
    below : N.Decoder (max_name_bytes => 4, max_value_bytes => 4);
    exact : N.Decoder (max_name_bytes => 4, max_value_bytes => 4);
    above : N.Decoder (max_name_bytes => 4, max_value_bytes => 4);
    huge  : N.Decoder (max_name_bytes => 4, max_value_bytes => 4);
    status : N.Feed_Status;
  begin
    N.feed (below, 3, status);
    A.assert_true
      (reporter, status = N.Progress, "name below policy limit is accepted");

    N.feed (exact, 4, status);
    A.assert_true
      (reporter, status = N.Progress,
       "name exactly at policy limit is accepted");

    N.feed (above, 5, status);
    A.assert_true
      (reporter, status = N.Limit_Exceeded,
       "name immediately above policy limit is rejected");

    N.feed (huge, 16#ff#, status);
    A.assert_true (reporter, status = N.Progress, "31-bit length byte one");
    N.feed (huge, 16#ff#, status);
    A.assert_true (reporter, status = N.Progress, "31-bit length byte two");
    N.feed (huge, 16#ff#, status);
    A.assert_true (reporter, status = N.Progress, "31-bit length byte three");
    N.feed (huge, 16#ff#, status);
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
      (reporter, "declared length limits", declared_length_limits'access);
  end run;

end Tests.Name_Values;
