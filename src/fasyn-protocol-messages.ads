-- ============================================================================
-- fasyn-protocol-messages.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces;

package Fasyn.Protocol.Messages is

  BEGIN_REQUEST_BODY_LENGTH : constant := 8;
  END_REQUEST_BODY_LENGTH   : constant := 8;
  UNKNOWN_TYPE_BODY_LENGTH  : constant := 8;

  type Body_Status is
    (Body_Complete,
     Invalid_Body_Length,
     Output_Too_Small);

  type Begin_Request_Body is record
    role_code : Interfaces.Unsigned_16 := 0;
    flags     : Byte := 0;
  end record;

  type End_Request_Body is record
    application_status   : Interfaces.Unsigned_32 := 0;
    protocol_status_code : Byte := REQUEST_COMPLETE_STATUS;
  end record;

  type Unknown_Type_Body is record
    record_type : Byte := 0;
  end record;

  procedure decode_begin_request
    (input        : in Byte_Array;
     request_body : out Begin_Request_Body;
     status       : out Body_Status);

  procedure encode_begin_request
    (request_body : in Begin_Request_Body;
     output       : out Byte_Array;
     written      : out Natural;
     status       : out Body_Status);

  procedure decode_end_request
    (input        : in Byte_Array;
     request_body : out End_Request_Body;
     status       : out Body_Status);

  procedure encode_end_request
    (request_body : in End_Request_Body;
     output       : out Byte_Array;
     written      : out Natural;
     status       : out Body_Status);

  procedure decode_unknown_type
    (input        : in Byte_Array;
     request_body : out Unknown_Type_Body;
     status       : out Body_Status);

  procedure encode_unknown_type
    (request_body : in Unknown_Type_Body;
     output       : out Byte_Array;
     written      : out Natural;
     status       : out Body_Status);

end Fasyn.Protocol.Messages;
