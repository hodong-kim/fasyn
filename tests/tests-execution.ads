-- ============================================================================
-- tests-execution.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Test.Reporter;

package Tests.Execution is
  procedure run
    (reporter : in out Clair.Test.Reporter.Context);
end Tests.Execution;
