-- ============================================================================
-- fasyn-request-admission.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package Fasyn.Request.Admission is

  type Context
    (connection_limit : Positive;
     request_limit    : Positive)
  is limited private;

  type Context_Access is access all Context;

  procedure try_acquire_connection
    (self     : in out Context;
     accepted : out Boolean);

  procedure release_connection (self : in out Context);

  procedure try_acquire_request
    (self     : in out Context;
     accepted : out Boolean);

  procedure release_request (self : in out Context);

  function max_connections (self : Context) return Positive;
  function max_requests (self : Context) return Positive;
  function active_connections (self : Context) return Natural;
  function active_requests (self : Context) return Natural;

private

  protected type Counters
    (connection_limit : Positive;
     request_limit    : Positive)
  is
    procedure try_connection (accepted : out Boolean);
    procedure release_connection;
    procedure try_request (accepted : out Boolean);
    procedure release_request;
    function connection_count return Natural;
    function request_count return Natural;
  private
    connections : Natural := 0;
    requests    : Natural := 0;
  end Counters;

  type Context
    (connection_limit : Positive;
     request_limit    : Positive)
  is limited record
    state : Counters (connection_limit, request_limit);
  end record;

end Fasyn.Request.Admission;
