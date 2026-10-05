-- ============================================================================
-- fasyn-protocol-name_values.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package Fasyn.Protocol.Name_Values is

  type Feed_Status is
    (Progress,
     Pair_Complete,
     Limit_Exceeded,
     Malformed_Length);

  type Encode_Status is
    (Encode_Complete,
     Output_Too_Small);

  --! Incremental decoder with caller-selected resident bounds for one pair.
  type Decoder
    (max_name_bytes  : Natural;
     max_value_bytes : Natural)
  is limited private;

  procedure reset (self : in out Decoder);

  --! After `Pair_Complete`, `Limit_Exceeded`, or `Malformed_Length`, call
  --! `reset` before feeding another byte; feeding a terminal decoder raises
  --! `Program_Error`.
  function feed
    (self  : in out Decoder;
     value : in Byte) return Feed_Status;

  function at_pair_boundary (self : Decoder) return Boolean;
  function name_length (self : Decoder) return Natural;
  function value_length (self : Decoder) return Natural;

  --! Byte accessors use one-based indices and raise `Constraint_Error` when
  --! the index exceeds the corresponding decoded length.
  function name_byte
    (self  : Decoder;
     index : Positive)
  return Byte;

  --! Uses a one-based index and raises `Constraint_Error` past value length.
  function value_byte
    (self  : Decoder;
     index : Positive)
  return Byte;

  --! Visits the completed pair without copying its bounded decoder storage.
  --! The supplied arrays alias decoder-owned storage and are valid only for the
  --! synchronous duration of `visitor`; callers must not retain references or
  --! addresses after it returns. Raises `Program_Error` unless a pair is
  --! complete.
  procedure visit_pair
    (self    : in Decoder;
     visitor : not null access procedure
       (name  : in Byte_Array;
        value : in Byte_Array));

  --! Raises `Constraint_Error` if the encoded pair size cannot fit `Natural`.
  function encoded_size
    (name_length  : Natural;
     value_length : Natural)
  return Natural;

  --! On `Output_Too_Small`, `written` is zero. On success, `written` is the
  --! exact encoded pair size.
  function encode_pair
    (name    : in Byte_Array;
     value   : in Byte_Array;
     output  : out Byte_Array;
     written : out Natural) return Encode_Status;

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

  type Decoder
    (max_name_bytes  : Natural;
     max_value_bytes : Natural)
  is limited record
    state                : Phase := Name_Length_First;
    length_accumulator   : Natural := 0;
    length_bytes_left    : Natural range 0 .. 3 := 0;
    length_is_long       : Boolean := False;
    decoded_name_length  : Natural := 0;
    decoded_value_length : Natural := 0;
    name_position        : Natural := 0;
    value_position       : Natural := 0;
    name_data            : Byte_Array (1 .. max_name_bytes);
    value_data           : Byte_Array (1 .. max_value_bytes);
  end record;

end Fasyn.Protocol.Name_Values;
