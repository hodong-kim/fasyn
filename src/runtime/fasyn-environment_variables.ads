-- ============================================================================
-- fasyn-environment_variables.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package Fasyn.Environment_Variables is

  --! Define one environment variable, replacing any existing value.
  --! This has the same contract as Ada.Environment_Variables.Set on the
  --! supported Fasyn runtimes: a prohibited name/value raises Constraint_Error.
  procedure set
    (name  : String;
     value : String);

end Fasyn.Environment_Variables;
