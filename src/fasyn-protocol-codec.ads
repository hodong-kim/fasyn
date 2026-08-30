-- ============================================================================
-- fasyn-protocol-codec.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package Fasyn.Protocol.Codec is

  type Decode_Status is
    (Complete,
     Need_More_Data,
     Unsupported_Version,
     Invalid_Request_Id_Domain);

  type Record_Event is
    (Header_Progress,
     Header_Ready,
     Content_Byte,
     Padding_Byte,
     Decode_Error);

  type Header_Decoder is limited private;
  type Record_Decoder is limited private;

  procedure reset (self : in out Header_Decoder);
  procedure reset (self : in out Record_Decoder);

  procedure feed
    (self          : in out Header_Decoder;
     value         : in Byte;
     record_header : out Header;
     status        : out Decode_Status);

  procedure feed
    (self          : in out Record_Decoder;
     value         : in Byte;
     event         : out Record_Event;
     record_header : out Header;
     status        : out Decode_Status);

  function record_complete (self : Record_Decoder) return Boolean;

  procedure encode_header
    (record_header : in Header;
     output        : out Byte_Array);

  procedure decode_header
    (input         : in Byte_Array;
     record_header : out Header;
     status        : out Decode_Status);

  function validate_request_id_domain
    (record_header : Header)
  return Boolean;

private

  type Header_Decoder is limited record
    bytes    : Byte_Array (0 .. HEADER_LENGTH - 1) := [others => 0];
    received : Natural range 0 .. HEADER_LENGTH := 0;
  end record;

  type Record_Phase is (Reading_Header, Reading_Content, Reading_Padding);

  type Record_Decoder is limited record
    header_parser     : Header_Decoder;
    current_header    : Header;
    phase             : Record_Phase := Reading_Header;
    content_remaining : Natural := 0;
    padding_remaining : Natural := 0;
    complete_flag     : Boolean := False;
  end record;

end Fasyn.Protocol.Codec;
