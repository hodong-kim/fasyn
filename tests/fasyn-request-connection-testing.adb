-- ============================================================================
-- fasyn-request-connection-testing.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================

package body Fasyn.Request.Connection.Testing is

  package P renames Fasyn.Protocol;
  use type P.Request_Id_Type;

  function current_identity
    (self       : Context;
     request_id : P.Request_Id_Type) return Request_Identity
  is
  begin
    if request_id = 0 then
      return NULL_REQUEST_IDENTITY;
    end if;

    for index in self.slots'range loop
      if self.slots(index) /= null and then
         self.slots(index).in_use and then
         self.slots(index).identity_value.request_id = request_id
      then
        return self.slots(index).identity_value;
      end if;
    end loop;

    return NULL_REQUEST_IDENTITY;
  end current_identity;

  function current_cancellation_reason
    (self       : Context;
     request_id : P.Request_Id_Type) return Cancellation_Cause
  is
  begin
    if request_id = 0 then
      return Not_Cancelled;
    end if;

    for index in self.slots'range loop
      if self.slots(index) /= null and then
         self.slots(index).in_use and then
         self.slots(index).identity_value.request_id = request_id
      then
        return cancellation_reason (self.slots(index).exchange);
      end if;
    end loop;

    return Not_Cancelled;
  end current_cancellation_reason;

end Fasyn.Request.Connection.Testing;
