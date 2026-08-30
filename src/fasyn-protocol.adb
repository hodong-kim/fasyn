-- ============================================================================
-- fasyn-protocol.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package body Fasyn.Protocol is

  use type Interfaces.Unsigned_8;

  function is_management_record (record_type : Byte) return Boolean is
  begin
    return record_type = GET_VALUES_TYPE or else
           record_type = GET_VALUES_RESULT_TYPE or else
           record_type = UNKNOWN_TYPE_TYPE;
  end is_management_record;

  function is_application_record (record_type : Byte) return Boolean is
  begin
    return record_type >= BEGIN_REQUEST_TYPE and then
           record_type <= DATA_TYPE;
  end is_application_record;

  function is_known_record_type (record_type : Byte) return Boolean is
  begin
    return is_application_record (record_type) or else
           is_management_record (record_type);
  end is_known_record_type;

end Fasyn.Protocol;
