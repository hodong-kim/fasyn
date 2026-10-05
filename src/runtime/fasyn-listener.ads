-- ============================================================================
-- fasyn-listener.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Event_Loop;
with Clair.IO;
private with Clair.IO.Posix;
with Clair.Status;

package Fasyn.Listener is

  type Accept_Handler is limited interface;
  type Accept_Handler_Access is access all Accept_Handler'Class;

  --! `fd` is a newly accepted nonblocking descriptor. Returning OK transfers
  --! ownership to the handler. On a non-OK return, Listener closes `fd`. An
  --! exception escaping the handler is contained as `CALLBACK_FAILED` after
  --! Listener closes the still-owned descriptor.
  function on_accept
    (self    : in out Accept_Handler;
     fd      : Clair.IO.Descriptor) return Clair.Status.Code
  is abstract;

  type Context is limited private;

  --! The listener descriptor remains caller-owned. Listener temporarily puts it
  --! in nonblocking mode and restores the original mode on successful finalize;
  --! it never closes the descriptor. `event_loop` and `handler` must remain
  --! alive while this Context is active. Invalid state/descriptor conditions
  --! are reported as `INVALID_STATE` or `INVALID_HANDLE`.
  function initialize
    (self       : aliased in out Context;
     event_loop : not null Clair.Event_Loop.Context_Access;
     fd         : Clair.IO.Descriptor;
     handler    : not null Accept_Handler_Access) return Clair.Status.Code;

  function finalize (self : in out Context) return Clair.Status.Code;

  function is_active (self : Context) return Boolean;

private

  MAX_ACCEPTS_PER_CALLBACK : constant Positive := 16;

  type Context_Access is access all Context;

  type IO_Adapter is limited record
    owner : Context_Access := null;
  end record;

  function on_io
    (self   : in out IO_Adapter;
     io     : Clair.Event_Loop.Source_Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code;

  type Context is limited record
    io_handler   : aliased IO_Adapter;
    event_loop   : Clair.Event_Loop.Context_Access := null;
    fd           : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    watch        : Clair.Event_Loop.Source_Handle :=
                     Clair.Event_Loop.NULL_SOURCE;
    handler      : Accept_Handler_Access := null;
    mode         : Clair.IO.Posix.Nonblocking_Mode_State;
    initialized  : Boolean := False;
    watch_active : Boolean := False;
    mode_active  : Boolean := False;
  end record;

end Fasyn.Listener;
