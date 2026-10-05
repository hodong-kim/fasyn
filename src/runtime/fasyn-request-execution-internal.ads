-- ============================================================================
-- fasyn-request-execution-internal.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Event_Loop;
with Clair.Status;
with Fasyn.Protocol;

package Fasyn.Request.Execution.Internal is

  --! Implementation integration surface for Request.Connection. This child is
  --! not part of Fasyn's supported consumer API and may change without
  --! compatibility treatment.

  type Operation_Kind is
    (Deliver_Parameter,
     Finish_Params,
     Deliver_Stdin,
     Finish_Stdin,
     Deliver_Data,
     Finish_Data);

  function deferred_output_chunk_bytes return Positive;
  function max_parameter_pairs_per_batch return Positive;

  function submit_parameter_batch
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     encoded            : Fasyn.Protocol.Byte_Array;
     finish_params      : Boolean;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  function submit_stdin_batch
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     finish_stream      : Boolean;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  function submit_data_batch
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     finish_stream      : Boolean;
     output_limit       : Natural;
     accepted           : out Boolean) return Clair.Status.Code;

  function uses_event_loop
    (self       : Context;
     event_loop : not null Clair.Event_Loop.Context_Access) return Boolean;

  function issue_connection_identity
    (self     : in out Context;
     identity : out Connection_Identity) return Clair.Status.Code;

  function supports_work_limits
    (self                  : Context;
     required_input_bytes  : Positive;
     required_output_bytes : Positive) return Boolean;

  function supports_batch_input_bytes
    (self           : Context;
     required_bytes : Positive) return Boolean;

  function deferred_requested
    (self    : Context;
     request : Identity) return Boolean;

  function activate_deferred
    (self               : in out Context;
     request            : Identity;
     request_pending    : Natural;
     request_limit      : Positive;
     connection_pending : Natural;
     connection_limit   : Positive) return Clair.Status.Code;

  procedure retire_deferred
    (self    : in out Context;
     request : Identity;
     cause   : Cancellation_Cause := Not_Cancelled);

  procedure set_deferred_connection_busy
    (self          : in out Context;
     connection_id : Connection_Identity;
     busy          : Boolean);

  procedure sync_deferred_connection
    (self          : in out Context;
     connection_id : Connection_Identity;
     pending       : Natural);

  procedure sync_deferred_request
    (self    : in out Context;
     request : Identity;
     pending : Natural);

  function deferred_pending_bytes
    (self    : Context;
     request : Identity) return Natural;

  function deferred_connection_pending_bytes
    (self          : Context;
     connection_id : Connection_Identity) return Natural;

end Fasyn.Request.Execution.Internal;
