-- ============================================================================
-- fasyn-request-execution-testing.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package Fasyn.Request.Execution.Testing is

  function output_capacity (item : Completion) return Positive;
  function completion_delivery_budget return Positive;
  function deferred_index_consistent (self : Context) return Boolean;
  function admission_index_churn_consistent return Boolean;
  procedure seed_next_connection_identity
    (self : in out Context; value : Connection_Identity);
  procedure retire_deferred_request
    (self : in out Context; request : Identity);

end Fasyn.Request.Execution.Testing;
