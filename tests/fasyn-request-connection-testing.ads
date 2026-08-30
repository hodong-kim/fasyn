-- ============================================================================
-- fasyn-request-connection-testing.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Fasyn.Protocol;

package Fasyn.Request.Connection.Testing is

  function current_identity
    (self       : Context;
     request_id : Fasyn.Protocol.Request_Id_Type) return Request_Identity;

  function current_cancellation_reason
    (self       : Context;
     request_id : Fasyn.Protocol.Request_Id_Type) return Cancellation_Cause;

end Fasyn.Request.Connection.Testing;
