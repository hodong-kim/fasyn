-- ============================================================================
-- fasyn-request-shutdown.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Event_Loop;
with Clair.Status;
with Fasyn.Request.Connection;
with Fasyn.Request.Execution;

package Fasyn.Request.Shutdown is

  type Outcome is (Drained, Grace_Expired);

  type Connection_Array is
    array (Natural range <>) of Fasyn.Request.Connection.Context_Access;

  --! The caller must stop listener admission before entering this boundary.
  --
  --! Active connections are cancelled with Runtime_Shutdown and executor
  --! admission is stopped. The event loop is driven until all accepted work
  --! drains or grace_period expires.
  --
  --! Drained:
  --!   Connections and the executor have been finalized successfully.
  --
  --! Grace_Expired:
  --!   Remaining active transports are forcibly closed, but application work
  --!   may still be running. Connection and executor storage must remain alive.
  --!   Call drain again after cooperative work returns to finish finalization.
  function drain
    (event_loop   : in out Clair.Event_Loop.Context;
     executor     : in out Fasyn.Request.Execution.Context;
     connections  : in Connection_Array;
     grace_period : Clair.Event_Loop.Milliseconds;
     result       : out Outcome) return Clair.Status.Code;

private

  package RC renames Fasyn.Request.Connection;
  package E renames Fasyn.Request.Execution;

end Fasyn.Request.Shutdown;
