-- ============================================================================
-- fasyn-protocol-management.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package Fasyn.Protocol.Management is

  type Values is record
    max_connections : Natural;
    max_requests    : Natural;
    multiplexing    : Boolean;
  end record;

  type Result_Status is
    (Result_Complete,
     Result_Output_Too_Small);

  --! Incremental `GET_VALUES` query decoder. It retains only bounded matching
  --! state for recognized names; unknown names and values are consumed without
  --! retaining their contents.
  type Query is limited private;

  procedure reset (self : in out Query);

  --! Completed pairs record recognized names and reset pair state so the next
  --! pair can be consumed immediately. Use `at_pair_boundary` when the caller
  --! needs to observe that boundary.
  procedure feed
    (self  : in out Query;
     value : in Byte);

  function at_pair_boundary (self : Query) return Boolean;

  function wants_max_connections (self : Query) return Boolean;
  function wants_max_requests (self : Query) return Boolean;
  function wants_multiplexing (self : Query) return Boolean;

  --! Encodes only requested recognized values. On insufficient output,
  --! `written` counts any complete pairs already emitted.
  function encode_result
    (self              : in Query;
     configured_values : in Values;
     output            : out Byte_Array;
     written           : out Natural) return Result_Status;

private

  type Query_Phase is
    (Name_Length_First,
     Name_Length_Rest,
     Value_Length_First,
     Value_Length_Rest,
     Name_Data,
     Value_Data,
     Malformed_State);

  type Query is limited record
    phase                 : Query_Phase := Name_Length_First;
    length_accumulator    : Natural := 0;
    length_bytes_left     : Natural range 0 .. 3 := 0;
    length_is_long        : Boolean := False;
    name_length           : Natural := 0;
    value_length          : Natural := 0;
    name_position         : Natural := 0;
    value_position        : Natural := 0;
    max_connections_match : Boolean := False;
    max_requests_match    : Boolean := False;
    multiplexing_match    : Boolean := False;
    max_connections_seen  : Boolean := False;
    max_requests_seen     : Boolean := False;
    multiplexing_seen     : Boolean := False;
  end record;

end Fasyn.Protocol.Management;
