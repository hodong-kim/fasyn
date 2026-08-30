-- ============================================================================
-- fasyn-diagnostics-native.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Status;

package Fasyn.Diagnostics.Native is

  --! Uses Clair's native diagnostic destination. On POSIX targets this maps to
  --! the native syslog backend expected by the FastCGI specification.
  type Reporter is limited new Fasyn.Diagnostics.Reporter with private;

  overriding procedure report
    (self     : in out Reporter;
     kind     : Fasyn.Diagnostics.Category;
     status   : Clair.Status.Code;
     message  : String);

private

  type Reporter is limited new Fasyn.Diagnostics.Reporter with null record;

end Fasyn.Diagnostics.Native;
