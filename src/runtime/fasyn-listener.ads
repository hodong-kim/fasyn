-- ============================================================================
-- fasyn-listener.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Event_Loop;
with Clair.IO;
with Clair.IO.Posix;
with Clair.Status;

package Fasyn.Listener is

  type Accept_Handler is limited interface;
  type Accept_Handler_Access is access all Accept_Handler'Class;

  --! `fd` is a newly accepted nonblocking descriptor. Returning OK transfers
  --! ownership to the handler. On a non-OK return, Listener closes `fd`.
  function on_accept
    (handler : in out Accept_Handler;
     fd      : Clair.IO.Descriptor) return Clair.Status.Code
  is abstract;

  type Context is limited new Clair.Event_Loop.IO_Handler with private;

  --! The listener descriptor remains caller-owned. Listener temporarily puts it
  --! in nonblocking mode and restores the original mode on successful finalize;
  --! it never closes the descriptor. `event_loop` and `handler` must remain
  --! alive while this Context is active.
  function initialize
    (self       : in out Context;
     event_loop : Clair.Event_Loop.Context_Access;
     fd         : Clair.IO.Descriptor;
     handler    : Accept_Handler_Access) return Clair.Status.Code;

  function finalize (self : in out Context) return Clair.Status.Code;

  function is_active (self : Context) return Boolean;

  overriding function on_io
    (self   : in out Context;
     io     : Clair.Event_Loop.Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code;

private

  type Context is limited new Clair.Event_Loop.IO_Handler with record
    event_loop   : Clair.Event_Loop.Context_Access := null;
    fd           : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    watch        : Clair.Event_Loop.Handle := Clair.Event_Loop.NULL_HANDLE;
    handler      : Accept_Handler_Access := null;
    mode         : Clair.IO.Posix.Nonblocking_Mode_State;
    initialized  : Boolean := False;
    watch_active : Boolean := False;
    mode_active  : Boolean := False;
  end record;

end Fasyn.Listener;
