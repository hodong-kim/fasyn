-- ============================================================================
-- fasyn-listener-testing.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package Fasyn.Listener.Testing is

  function accept_budget return Positive;

  function dispatch_io
    (self   : in out Context;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code;

end Fasyn.Listener.Testing;
