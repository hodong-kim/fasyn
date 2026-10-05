-- ============================================================================
-- fasyn-protocol.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces;

package Fasyn.Protocol is

  subtype Byte is Interfaces.Unsigned_8;
  subtype Version is Byte;
  subtype Record_Type is Byte;
  subtype Request_Id is Interfaces.Unsigned_16;
  subtype Content_Length is Interfaces.Unsigned_16;
  subtype Padding_Length is Interfaces.Unsigned_8;
  subtype Role_Code is Interfaces.Unsigned_16;
  subtype Status_Code is Byte;

  VERSION_1 : constant Version := 1;

  BEGIN_REQUEST     : constant Record_Type := 1;
  ABORT_REQUEST     : constant Record_Type := 2;
  END_REQUEST       : constant Record_Type := 3;
  PARAMS            : constant Record_Type := 4;
  STDIN             : constant Record_Type := 5;
  STDOUT            : constant Record_Type := 6;
  STDERR            : constant Record_Type := 7;
  DATA              : constant Record_Type := 8;
  GET_VALUES        : constant Record_Type := 9;
  GET_VALUES_RESULT : constant Record_Type := 10;
  UNKNOWN_TYPE      : constant Record_Type := 11;

  RESPONDER_CODE  : constant Role_Code := 1;
  AUTHORIZER_CODE : constant Role_Code := 2;
  FILTER_CODE     : constant Role_Code := 3;

  type Role is (Responder, Authorizer, Filter);
  for Role use
    (Responder  => RESPONDER_CODE,
     Authorizer => AUTHORIZER_CODE,
     Filter     => FILTER_CODE);
  for Role'Size use 16;

  KEEP_CONN : constant Byte := 1;

  REQUEST_COMPLETE : constant Status_Code := 0;
  CANT_MPX_CONN    : constant Status_Code := 1;
  OVERLOADED       : constant Status_Code := 2;
  UNKNOWN_ROLE     : constant Status_Code := 3;

  HEADER_LENGTH : constant := 8;

  type Header is record
    version        : Fasyn.Protocol.Version := VERSION_1;
    record_type    : Fasyn.Protocol.Record_Type := 0;
    request_id     : Fasyn.Protocol.Request_Id := 0;
    content_length : Fasyn.Protocol.Content_Length := 0;
    padding_length : Fasyn.Protocol.Padding_Length := 0;
  end record;

  type Byte_Array is array (Natural range <>) of Byte;

  function is_management_record
    (record_type : Fasyn.Protocol.Record_Type) return Boolean;
  function is_application_record
    (record_type : Fasyn.Protocol.Record_Type) return Boolean;
  function is_known_record_type
    (record_type : Fasyn.Protocol.Record_Type) return Boolean;

end Fasyn.Protocol;
