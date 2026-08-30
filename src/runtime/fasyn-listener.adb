-- ============================================================================
-- fasyn-listener.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Network;

package body Fasyn.Listener is

  use type Clair.Event_Loop.Context_Access;
  use type Clair.IO.Descriptor;
  use type Clair.Network.Socket_Options;
  use type Clair.Status.Code;

  MAX_ACCEPTS_PER_CALLBACK : constant Positive := 16;

  function initialize
    (self       : in out Context;
     event_loop : Clair.Event_Loop.Context_Access;
     fd         : Clair.IO.Descriptor;
     handler    : Accept_Handler_Access) return Clair.Status.Code
  is
    status         : Clair.Status.Code;
    restore_status : Clair.Status.Code;
  begin
    if self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if event_loop = null or else handler = null then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    if fd = Clair.IO.INVALID_DESCRIPTOR then
      return Clair.Status.INVALID_HANDLE;
    end if;

    status := Clair.IO.Posix.enter_nonblocking (fd, self.mode);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.event_loop := event_loop;
    self.fd := fd;
    self.handler := handler;
    self.initialized := True;
    self.mode_active := True;

    status := Clair.Event_Loop.add_watch
      (self    => event_loop.all,
       fd      => fd,
       events  => Clair.Event_Loop.EVENT_INPUT,
       handler => self'Unchecked_Access,
       source  => self.watch);

    if status = Clair.Status.OK then
      self.watch_active := True;
      return Clair.Status.OK;
    end if;

    restore_status := Clair.IO.Posix.restore_nonblocking (self.mode);
    if restore_status /= Clair.Status.OK then
      return restore_status;
    end if;

    self.mode_active := False;
    self.initialized := False;
    self.event_loop := null;
    self.fd := Clair.IO.INVALID_DESCRIPTOR;
    self.handler := null;
    return status;
  end initialize;

  function finalize (self : in out Context) return Clair.Status.Code is
    status : Clair.Status.Code;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.watch_active then
      status := Clair.Event_Loop.remove (self.event_loop.all, self.watch);
      if status /= Clair.Status.OK then
        return status;
      end if;

      self.watch_active := False;
    end if;

    if self.mode_active then
      status := Clair.IO.Posix.restore_nonblocking (self.mode);
      if status /= Clair.Status.OK then
        return status;
      end if;

      self.mode_active := False;
    end if;

    self.initialized := False;
    self.event_loop := null;
    self.fd := Clair.IO.INVALID_DESCRIPTOR;
    self.handler := null;
    return Clair.Status.OK;
  end finalize;

  function is_active (self : Context) return Boolean is
  begin
    return self.initialized and then self.watch_active;
  end is_active;

  overriding function on_io
    (self   : in out Context;
     io     : Clair.Event_Loop.Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code
  is
    pragma Unreferenced (io, events);

    accepted       : Clair.IO.Descriptor;
    status         : Clair.Status.Code;
    handler_status : Clair.Status.Code;
    close_status   : Clair.Status.Code;
    options        : constant Clair.Network.Socket_Options :=
      Clair.Network.CLOSE_ON_EXEC or Clair.Network.NON_BLOCKING;
  begin
    if not self.initialized or else fd /= self.fd then
      return Clair.Status.INVALID_STATE;
    end if;

    for attempt in 1 .. MAX_ACCEPTS_PER_CALLBACK loop
      pragma Unreferenced (attempt);
      status := Clair.Network.accept_connection
        (fd      => self.fd,
         options => options,
         result  => accepted);

      if status = Clair.Status.OK then
        handler_status := on_accept (self.handler.all, accepted);

        if handler_status /= Clair.Status.OK then
          close_status := Clair.IO.close (accepted);
          if close_status /= Clair.Status.OK then
            return close_status;
          end if;

          return handler_status;
        end if;

      elsif Clair.IO.Posix.is_would_block (status) then
        return Clair.Status.OK;
      else
        return status;
      end if;
    end loop;

    return Clair.Status.OK;
  end on_io;

end Fasyn.Listener;
