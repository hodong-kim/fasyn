-- ============================================================================
-- fasyn-protocol-bodies.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces;

package Fasyn.Protocol.Bodies is

  BEGIN_REQUEST_BODY_LENGTH : constant := 8;
  END_REQUEST_BODY_LENGTH   : constant := 8;
  UNKNOWN_TYPE_BODY_LENGTH  : constant := 8;

  --! Decoders require the exact protocol body length and initialize their
  --! output body before validation. Encoders return `written = 0` when the
  --! output buffer is too small.
  type Body_Status is
    (Body_Complete,
     Invalid_Body_Length,
     Output_Too_Small);

  type Begin_Request_Body is record
    role_code : Fasyn.Protocol.Role_Code := 0;
    flags     : Byte := 0;
  end record;

  type End_Request_Body is record
    application_status   : Interfaces.Unsigned_32 := 0;
    protocol_status_code : Fasyn.Protocol.Status_Code :=
      REQUEST_COMPLETE;
  end record;

  type Unknown_Type_Body is record
    record_type : Fasyn.Protocol.Record_Type := 0;
  end record;

  --! Requires exactly `BEGIN_REQUEST_BODY_LENGTH` bytes.
  function decode_begin_request
    (input        : in Byte_Array;
     request_body : out Begin_Request_Body) return Body_Status;

  --! Returns `written = 0` with `Output_Too_Small` if `output` is short.
  function encode_begin_request
    (request_body : in Begin_Request_Body;
     output       : out Byte_Array;
     written      : out Natural) return Body_Status;

  --! Requires exactly `END_REQUEST_BODY_LENGTH` bytes.
  function decode_end_request
    (input        : in Byte_Array;
     request_body : out End_Request_Body) return Body_Status;

  --! Returns `written = 0` with `Output_Too_Small` if `output` is short.
  function encode_end_request
    (request_body : in End_Request_Body;
     output       : out Byte_Array;
     written      : out Natural) return Body_Status;

  --! Requires exactly `UNKNOWN_TYPE_BODY_LENGTH` bytes.
  function decode_unknown_type
    (input        : in Byte_Array;
     request_body : out Unknown_Type_Body) return Body_Status;

  --! Returns `written = 0` with `Output_Too_Small` if `output` is short.
  function encode_unknown_type
    (request_body : in Unknown_Type_Body;
     output       : out Byte_Array;
     written      : out Natural) return Body_Status;

end Fasyn.Protocol.Bodies;
