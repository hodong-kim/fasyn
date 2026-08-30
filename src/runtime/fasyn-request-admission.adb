-- ============================================================================
-- fasyn-request-admission.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package body Fasyn.Request.Admission is

  protected body Counters is

    procedure try_connection (accepted : out Boolean) is
    begin
      if connections < connection_limit then
        connections := connections + 1;
        accepted := True;
      else
        accepted := False;
      end if;
    end try_connection;

    procedure release_connection is
    begin
      if connections > 0 then
        connections := connections - 1;
      end if;
    end release_connection;

    procedure try_request (accepted : out Boolean) is
    begin
      if requests < request_limit then
        requests := requests + 1;
        accepted := True;
      else
        accepted := False;
      end if;
    end try_request;

    procedure release_request is
    begin
      if requests > 0 then
        requests := requests - 1;
      end if;
    end release_request;

    function connection_count return Natural is
    begin
      return connections;
    end connection_count;

    function request_count return Natural is
    begin
      return requests;
    end request_count;

  end Counters;

  procedure try_acquire_connection
    (self     : in out Context;
     accepted : out Boolean)
  is
  begin
    self.state.try_connection (accepted);
  end try_acquire_connection;

  procedure release_connection (self : in out Context) is
  begin
    self.state.release_connection;
  end release_connection;

  procedure try_acquire_request
    (self     : in out Context;
     accepted : out Boolean)
  is
  begin
    self.state.try_request (accepted);
  end try_acquire_request;

  procedure release_request (self : in out Context) is
  begin
    self.state.release_request;
  end release_request;

  function max_connections (self : Context) return Positive is
  begin
    return self.connection_limit;
  end max_connections;

  function max_requests (self : Context) return Positive is
  begin
    return self.request_limit;
  end max_requests;

  function active_connections (self : Context) return Natural is
  begin
    return self.state.connection_count;
  end active_connections;

  function active_requests (self : Context) return Natural is
  begin
    return self.state.request_count;
  end active_requests;

end Fasyn.Request.Admission;
