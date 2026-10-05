-- ============================================================================
-- fasyn-listener.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Unchecked_Conversion;
with Clair.Unix.Network;
with System;

package body Fasyn.Listener is

  use type Clair.Event_Loop.Context_Access;
  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;

  type IO_Adapter_Access is access all IO_Adapter;
  function address_to_io_adapter is new Ada.Unchecked_Conversion
    (System.Address, IO_Adapter_Access);

  function io_callback
    (source  : access constant Clair.Event_Loop.Source_Handle;
     fd      : Clair.IO.Descriptor;
     events  : Clair.Event_Loop.Event_Mask;
     context : System.Address) return Clair.Status.Code
  with Convention => C;

  function io_callback
    (source  : access constant Clair.Event_Loop.Source_Handle;
     fd      : Clair.IO.Descriptor;
     events  : Clair.Event_Loop.Event_Mask;
     context : System.Address) return Clair.Status.Code
  is
    adapter : constant IO_Adapter_Access := address_to_io_adapter (context);
  begin
    if adapter = null or else source = null then
      return Clair.Status.INVALID_STATE;
    end if;

    return on_io (adapter.all, source.all, fd, events);
  exception
    when others =>
      return Clair.Status.CALLBACK_FAILED;
  end io_callback;

  function initialize
    (self       : aliased in out Context;
     event_loop : not null Clair.Event_Loop.Context_Access;
     fd         : Clair.IO.Descriptor;
     handler    : not null Accept_Handler_Access) return Clair.Status.Code
  is
    status         : Clair.Status.Code;
    restore_status : Clair.Status.Code;
  begin
    if self.initialized then
      return Clair.Status.INVALID_STATE;
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
    self.io_handler.owner := self'Unchecked_Access;
    self.initialized := True;
    self.mode_active := True;

    status := Clair.Event_Loop.add_watch
      (self    => event_loop.all,
       fd      => fd,
       events           => Clair.Event_Loop.EVENT_INPUT,
       callback         => io_callback'Access,
       callback_context => self.io_handler'Address,
       source           => self.watch);

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
    self.io_handler.owner := null;
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
    self.io_handler.owner := null;
    return Clair.Status.OK;
  end finalize;

  function is_active (self : Context) return Boolean is
  begin
    return self.initialized and then self.watch_active;
  end is_active;

  function on_io
    (self   : in out IO_Adapter;
     io     : Clair.Event_Loop.Source_Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code
  is
    pragma Unreferenced (io, events);

    owner          : constant Context_Access := self.owner;
    accepted       : Clair.IO.Descriptor;
    status         : Clair.Status.Code;
    handler_status : Clair.Status.Code;
    close_status   : Clair.Status.Code;
    options        : constant Clair.Unix.Network.Socket_Options :=
      [Clair.Unix.Network.Close_On_Exec => True,
       Clair.Unix.Network.Nonblocking => True];
  begin
    if owner = null or else
       not owner.initialized or else
       fd /= owner.fd
    then
      return Clair.Status.INVALID_STATE;
    end if;

    for attempt in 1 .. MAX_ACCEPTS_PER_CALLBACK loop
      pragma Unreferenced (attempt);
      status := Clair.Unix.Network.accept_connection
        (fd                  => owner.fd,
         options             => options,
         accepted_descriptor => accepted);

      if status = Clair.Status.OK then
        begin
          handler_status := on_accept (owner.handler.all, accepted);
        exception
          when others =>
            close_status := Clair.IO.close (accepted);
            if close_status /= Clair.Status.OK then
              return close_status;
            end if;
            return Clair.Status.CALLBACK_FAILED;
        end;

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
