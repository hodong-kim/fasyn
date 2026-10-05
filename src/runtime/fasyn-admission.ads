-- ============================================================================
-- fasyn-admission.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package Fasyn.Admission is

  --! Thread-safe shared counters for bounded connection/request admission.
  --! `max_connections = 0` refuses every connection acquisition.
  --! `max_requests = 0` permits admitted connections but refuses every request
  --! acquisition.
  type Context
    (max_connections : Natural;
     max_requests    : Natural)
  is limited private;

  type Context_Access is access all Context;

  --! Returns True and increments the connection count only when capacity is
  --! available. Every successful acquisition requires one matching release.
  function try_acquire_connection (self : in out Context) return Boolean;

  --! Releases one successful connection acquisition. Raises Program_Error if
  --! no connection acquisition is owned.
  procedure release_connection (self : in out Context);

  --! Returns True and increments the request count only when capacity is
  --! available. Every successful acquisition requires one matching release.
  function try_acquire_request (self : in out Context) return Boolean;

  --! Releases one successful request acquisition. Raises Program_Error if no
  --! request acquisition is owned.
  procedure release_request (self : in out Context);

  function max_connections (self : Context) return Natural;
  function max_requests (self : Context) return Natural;
  function active_connections (self : Context) return Natural;
  function active_requests (self : Context) return Natural;

private

  protected type Counters
    (max_connections : Natural;
     max_requests    : Natural)
  is
    procedure try_connection (accepted : out Boolean);
    procedure release_connection (released : out Boolean);
    procedure try_request (accepted : out Boolean);
    procedure release_request (released : out Boolean);
    function connection_count return Natural;
    function request_count return Natural;
  private
    --  Keep synchronization atomic-only so scoped Context values carry no
    --  OS-backed protection lifetime.
    pragma Lock_Free;
    connections : Natural := 0;
    requests    : Natural := 0;
  end Counters;

  type Context
    (max_connections : Natural;
     max_requests    : Natural)
  is limited record
    state : Counters (max_connections, max_requests);
  end record;

end Fasyn.Admission;
