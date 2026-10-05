-- ============================================================================
-- fasyn-listener-testing.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package body Fasyn.Listener.Testing is

  function accept_budget return Positive is
  begin
    return MAX_ACCEPTS_PER_CALLBACK;
  end accept_budget;

  function dispatch_io
    (self   : in out Context;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code
  is
  begin
    return on_io
      (self.io_handler, Clair.Event_Loop.NULL_SOURCE, fd, events);
  end dispatch_io;

end Fasyn.Listener.Testing;
