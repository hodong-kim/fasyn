-- ============================================================================
-- fasyn-protocol-messages.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package body Fasyn.Protocol.Messages is

  use type Interfaces.Unsigned_16;
  use type Interfaces.Unsigned_32;

  function decode_u16
    (input : Byte_Array;
     first : Natural)
  return Interfaces.Unsigned_16
  is
  begin
    return Interfaces.Unsigned_16(input(first)) * 256 +
           Interfaces.Unsigned_16(input(first + 1));
  end decode_u16;

  function decode_u32
    (input : Byte_Array;
     first : Natural)
  return Interfaces.Unsigned_32
  is
  begin
    return Interfaces.Unsigned_32(input(first)) * 16#01000000# +
           Interfaces.Unsigned_32(input(first + 1)) * 16#00010000# +
           Interfaces.Unsigned_32(input(first + 2)) * 16#00000100# +
           Interfaces.Unsigned_32(input(first + 3));
  end decode_u32;

  procedure encode_u16
    (value    : in Interfaces.Unsigned_16;
     output   : in out Byte_Array;
     position : in Natural)
  is
  begin
    output(position) :=
      Byte(Interfaces.Shift_Right(value, 8) and 16#ff#);
    output(position + 1) := Byte(value and 16#ff#);
  end encode_u16;

  procedure encode_u32
    (value    : in Interfaces.Unsigned_32;
     output   : in out Byte_Array;
     position : in Natural)
  is
  begin
    output(position) :=
      Byte(Interfaces.Shift_Right(value, 24) and 16#ff#);
    output(position + 1) :=
      Byte(Interfaces.Shift_Right(value, 16) and 16#ff#);
    output(position + 2) :=
      Byte(Interfaces.Shift_Right(value, 8) and 16#ff#);
    output(position + 3) := Byte(value and 16#ff#);
  end encode_u32;

  procedure decode_begin_request
    (input        : in Byte_Array;
     request_body : out Begin_Request_Body;
     status       : out Body_Status)
  is
    first : constant Natural := input'first;
  begin
    request_body := (others => <>);

    if input'length /= BEGIN_REQUEST_BODY_LENGTH then
      status := Invalid_Body_Length;
      return;
    end if;

    request_body.role_code := decode_u16 (input, first);
    request_body.flags := input(first + 2);
    status := Body_Complete;
  end decode_begin_request;

  procedure encode_begin_request
    (request_body : in Begin_Request_Body;
     output       : out Byte_Array;
     written      : out Natural;
     status       : out Body_Status)
  is
    first : constant Natural := output'first;
  begin
    written := 0;

    if output'length < BEGIN_REQUEST_BODY_LENGTH then
      status := Output_Too_Small;
      return;
    end if;

    output(first .. first + BEGIN_REQUEST_BODY_LENGTH - 1) := [others => 0];
    encode_u16 (request_body.role_code, output, first);
    output(first + 2) := request_body.flags;
    written := BEGIN_REQUEST_BODY_LENGTH;
    status := Body_Complete;
  end encode_begin_request;

  procedure decode_end_request
    (input        : in Byte_Array;
     request_body : out End_Request_Body;
     status       : out Body_Status)
  is
    first : constant Natural := input'first;
  begin
    request_body := (others => <>);

    if input'length /= END_REQUEST_BODY_LENGTH then
      status := Invalid_Body_Length;
      return;
    end if;

    request_body.application_status := decode_u32 (input, first);
    request_body.protocol_status_code := input(first + 4);
    status := Body_Complete;
  end decode_end_request;

  procedure encode_end_request
    (request_body : in End_Request_Body;
     output       : out Byte_Array;
     written      : out Natural;
     status       : out Body_Status)
  is
    first : constant Natural := output'first;
  begin
    written := 0;

    if output'length < END_REQUEST_BODY_LENGTH then
      status := Output_Too_Small;
      return;
    end if;

    output(first .. first + END_REQUEST_BODY_LENGTH - 1) := [others => 0];
    encode_u32 (request_body.application_status, output, first);
    output(first + 4) := request_body.protocol_status_code;
    written := END_REQUEST_BODY_LENGTH;
    status := Body_Complete;
  end encode_end_request;

  procedure decode_unknown_type
    (input        : in Byte_Array;
     request_body : out Unknown_Type_Body;
     status       : out Body_Status)
  is
  begin
    request_body := (others => <>);

    if input'length /= UNKNOWN_TYPE_BODY_LENGTH then
      status := Invalid_Body_Length;
      return;
    end if;

    request_body.record_type := input(input'first);
    status := Body_Complete;
  end decode_unknown_type;

  procedure encode_unknown_type
    (request_body : in Unknown_Type_Body;
     output       : out Byte_Array;
     written      : out Natural;
     status       : out Body_Status)
  is
    first : constant Natural := output'first;
  begin
    written := 0;

    if output'length < UNKNOWN_TYPE_BODY_LENGTH then
      status := Output_Too_Small;
      return;
    end if;

    output(first .. first + UNKNOWN_TYPE_BODY_LENGTH - 1) := [others => 0];
    output(first) := request_body.record_type;
    written := UNKNOWN_TYPE_BODY_LENGTH;
    status := Body_Complete;
  end encode_unknown_type;

end Fasyn.Protocol.Messages;
