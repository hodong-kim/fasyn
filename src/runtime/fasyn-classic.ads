-- ============================================================================
-- fasyn-classic.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Event_Loop;
with Clair.IO;
private with Clair.Unix.Network;
with Clair.Status;
with Fasyn.Diagnostics;
with Fasyn.Listener;

package Fasyn.Classic is

  FCGI_LISTENSOCK_FILENO : constant Clair.IO.Descriptor :=
    Clair.IO.Descriptor(0);
  FCGI_WEB_SERVER_ADDRS : constant String := "FCGI_WEB_SERVER_ADDRS";

  type Context is limited private;

  --! Reads FCGI_WEB_SERVER_ADDRS once, validates it, and starts watching the
  --! inherited FastCGI listener on file descriptor 0. The descriptor remains
  --! process/caller-owned and is not closed by finalize. `event_loop` and
  --! `handler`, and any supplied `diagnostics` object, must remain alive until
  --! this Context has finalized successfully.
  function initialize
    (self        : aliased in out Context;
     event_loop  : not null Clair.Event_Loop.Context_Access;
     handler     : not null Fasyn.Listener.Accept_Handler_Access;
     diagnostics : Fasyn.Diagnostics.Reporter_Access := null)
  return Clair.Status.Code;

  --! Stops new connection admission and restores the inherited listener's
  --! original blocking mode. A SIGTERM integration shall transfer termination
  --! into normal control flow before calling this operation; this operation is
  --! not an async-signal handler. Existing accepted connections can then be
  --! drained through the ordinary bounded Fasyn shutdown path.
  function finalize (self : in out Context) return Clair.Status.Code;

  function is_active (self : Context) return Boolean;

private

  -- The FastCGI variable has no protocol-defined count limit. Keep the
  -- startup representation bounded without exposing its storage cap as an
  -- application-facing configuration contract.
  MAX_WEB_SERVER_ADDRESSES : constant Positive := 64;

  type Context_Access is access all Context;

  type Accept_Adapter is limited new Fasyn.Listener.Accept_Handler with record
    owner : Context_Access := null;
  end record;

  overriding function on_accept
    (self : in out Accept_Adapter;
     fd   : Clair.IO.Descriptor) return Clair.Status.Code;

  subtype Address_Index is Positive range 1 .. MAX_WEB_SERVER_ADDRESSES;
  type Address_Array is array (Address_Index) of Clair.Unix.Network.IPv4_Address;

  type Context is limited record
    accept_handler    : aliased Accept_Adapter;
    listener          : aliased Fasyn.Listener.Context;
    handler           : Fasyn.Listener.Accept_Handler_Access := null;
    diagnostics       : Fasyn.Diagnostics.Reporter_Access := null;
    allowed_addresses : Address_Array := [others => [others => 0]];
    allowed_count     : Natural range 0 .. MAX_WEB_SERVER_ADDRESSES := 0;
    restrict_peers    : Boolean := False;
    initialized       : Boolean := False;
  end record;

end Fasyn.Classic;
