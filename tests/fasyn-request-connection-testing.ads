-- ============================================================================
-- fasyn-request-connection-testing.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with Fasyn.Diagnostics;
with Fasyn.Protocol;
with Fasyn.Request.Execution;

package Fasyn.Request.Connection.Testing is

  function initialize_without_shared_admission
    (self            : aliased in out Context;
     event_loop      : not null Clair.Event_Loop.Context_Access;
     fd              : Clair.IO.Descriptor;
     application     : not null Application_Access;
     executor        : not null Fasyn.Request.Execution.Context_Access;
     request_lifetime_timeout : Clair.Event_Loop.Milliseconds;
     idle_connection_timeout : Clair.Event_Loop.Milliseconds :=
       DEFAULT_IDLE_CONNECTION_TIMEOUT;
     diagnostics     : Fasyn.Diagnostics.Reporter_Access := null;
     input_limits    : Stream_Limits := DEFAULT_STREAM_LIMITS)
  return Clair.Status.Code;

  function current_identity
    (self       : Context;
     request_id : Fasyn.Protocol.Request_Id) return Identity;

  function current_cancellation_reason
    (self       : Context;
     request_id : Fasyn.Protocol.Request_Id) return Cancellation_Cause;

  function slot_index_consistent (self : Context) return Boolean;
  function output_accounting_consistent (self : Context) return Boolean;
  function allocated_slot_count (self : Context) return Natural;
  function slot_storage_capacity (self : Context) return Natural;
  function input_dispatch_bytes (self : Context) return Natural;
  function output_dispatch_bytes (self : Context) return Natural;
  function input_dispatch_budget return Positive;
  function output_dispatch_budget return Positive;
  function request_timer_count (self : Context) return Natural;
  function idle_timer_active (self : Context) return Boolean;
  function finalization_required (self : Context) return Boolean;
  procedure seed_next_generation
    (self : in out Context; value : Generation);
  procedure seed_pending_input
    (self : in out Context; data : Fasyn.Protocol.Byte_Array);

  function dispatch_io
    (self   : in out Context;
     io     : Clair.Event_Loop.Source_Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code;

end Fasyn.Request.Connection.Testing;
