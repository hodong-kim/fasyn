-- ============================================================================
-- fasyn-protocol.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces;

package Fasyn.Protocol is

  subtype Byte is Interfaces.Unsigned_8;
  subtype Request_Id_Type is Interfaces.Unsigned_16;
  subtype Content_Length_Type is Interfaces.Unsigned_16;
  subtype Padding_Length_Type is Interfaces.Unsigned_8;

  VERSION_1 : constant Byte := 1;

  BEGIN_REQUEST_TYPE     : constant Byte := 1;
  ABORT_REQUEST_TYPE     : constant Byte := 2;
  END_REQUEST_TYPE       : constant Byte := 3;
  PARAMS_TYPE            : constant Byte := 4;
  STDIN_TYPE             : constant Byte := 5;
  STDOUT_TYPE            : constant Byte := 6;
  STDERR_TYPE            : constant Byte := 7;
  DATA_TYPE              : constant Byte := 8;
  GET_VALUES_TYPE        : constant Byte := 9;
  GET_VALUES_RESULT_TYPE : constant Byte := 10;
  UNKNOWN_TYPE_TYPE      : constant Byte := 11;

  RESPONDER_ROLE  : constant Interfaces.Unsigned_16 := 1;
  AUTHORIZER_ROLE : constant Interfaces.Unsigned_16 := 2;
  FILTER_ROLE     : constant Interfaces.Unsigned_16 := 3;

  type Role is (Responder, Authorizer, Filter);
  for Role use
    (Responder  => 1,
     Authorizer => 2,
     Filter     => 3);
  for Role'Size use 16;

  KEEP_CONN : constant Byte := 1;

  REQUEST_COMPLETE_STATUS : constant Byte := 0;
  CANT_MPX_CONN_STATUS    : constant Byte := 1;
  OVERLOADED_STATUS       : constant Byte := 2;
  UNKNOWN_ROLE_STATUS     : constant Byte := 3;

  HEADER_LENGTH : constant := 8;

  type Header is record
    version        : Byte := VERSION_1;
    record_type    : Byte := 0;
    request_id     : Request_Id_Type := 0;
    content_length : Content_Length_Type := 0;
    padding_length : Padding_Length_Type := 0;
    reserved       : Byte := 0;
  end record;

  type Byte_Array is array (Natural range <>) of Byte;

  function is_management_record (record_type : Byte) return Boolean;
  function is_application_record (record_type : Byte) return Boolean;
  function is_known_record_type (record_type : Byte) return Boolean;

end Fasyn.Protocol;
