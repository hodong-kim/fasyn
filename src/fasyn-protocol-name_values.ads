-- ============================================================================
-- fasyn-protocol-name_values.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package Fasyn.Protocol.Name_Values is

  type Feed_Status is
    (Progress,
     Pair_Complete,
     Limit_Exceeded,
     Invalid_State);

  type Encode_Status is
    (Encode_Complete,
     Output_Too_Small);

  type Decoder
    (max_name_bytes  : Positive;
     max_value_bytes : Positive)
  is limited private;

  procedure reset (self : in out Decoder);

  procedure feed
    (self   : in out Decoder;
     value  : in Byte;
     status : out Feed_Status);

  function at_pair_boundary (self : Decoder) return Boolean;
  function name_length (self : Decoder) return Natural;
  function value_length (self : Decoder) return Natural;

  function name_byte
    (self  : Decoder;
     index : Positive)
  return Byte;

  function value_byte
    (self  : Decoder;
     index : Positive)
  return Byte;

  function encoded_size
    (name_length  : Natural;
     value_length : Natural)
  return Natural;

  procedure encode_pair
    (name    : in Byte_Array;
     value   : in Byte_Array;
     output  : out Byte_Array;
     written : out Natural;
     status  : out Encode_Status);

private

  type Phase is
    (Name_Length_First,
     Name_Length_Rest,
     Value_Length_First,
     Value_Length_Rest,
     Name_Data,
     Value_Data,
     Complete_State,
     Failed_State);

  type Name_Buffer is array (Positive range <>) of Byte;
  type Value_Buffer is array (Positive range <>) of Byte;

  type Decoder
    (max_name_bytes  : Positive;
     max_value_bytes : Positive)
  is limited record
    state                : Phase := Name_Length_First;
    length_accumulator   : Natural := 0;
    length_bytes_left    : Natural range 0 .. 3 := 0;
    decoded_name_length  : Natural := 0;
    decoded_value_length : Natural := 0;
    name_position        : Natural := 0;
    value_position       : Natural := 0;
    name_data            : Name_Buffer (1 .. max_name_bytes);
    value_data           : Value_Buffer (1 .. max_value_bytes);
  end record;

end Fasyn.Protocol.Name_Values;
