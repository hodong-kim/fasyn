-- ============================================================================
-- fasyn-diagnostics.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Status;

package Fasyn.Diagnostics is

  type Category is
    (Environment_Error,
     Protocol_Error,
     Resource_Error,
     System_Error);

  type Reporter is limited interface;
  type Reporter_Access is access all Reporter'Class;

  --! Diagnostic reporting is a side channel. Implementations shall not perform
  --! transport I/O on a FastCGI connection and shall not raise exceptions.
  procedure report
    (self     : in out Reporter;
     kind     : Category;
     status   : Clair.Status.Code;
     message  : String)
  is abstract;

end Fasyn.Diagnostics;
