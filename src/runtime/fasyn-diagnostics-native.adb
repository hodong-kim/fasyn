-- ============================================================================
-- fasyn-diagnostics-native.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Log;

package body Fasyn.Diagnostics.Native is

  overriding procedure report
    (self     : in out Reporter;
     kind     : Fasyn.Diagnostics.Category;
     status   : Clair.Status.Code;
     message  : String)
  is
    pragma Unreferenced (self);
  begin
    Clair.Log.error
      ("fasyn " & Fasyn.Diagnostics.Category'Image(kind) &
       " status=" & Clair.Status.Code'Image(status) & ": " & message);
  end report;

end Fasyn.Diagnostics.Native;
