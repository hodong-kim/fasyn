-- ============================================================================
-- fasyn-protocol-management.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Fasyn.Protocol.Name_Values;

package Fasyn.Protocol.Management is

  type Values is record
    max_connections : Positive;
    max_requests    : Positive;
    multiplexing    : Boolean;
  end record;

  type Query_Status is
    (Query_Progress,
     Query_Pair_Complete,
     Query_Limit_Exceeded,
     Query_Invalid);

  type Result_Status is
    (Result_Complete,
     Result_Output_Too_Small);

  type Query is limited private;

  procedure reset (self : in out Query);

  procedure feed
    (self   : in out Query;
     value  : in Byte;
     status : out Query_Status);

  function at_pair_boundary (self : Query) return Boolean;

  function wants_max_connections (self : Query) return Boolean;
  function wants_max_requests (self : Query) return Boolean;
  function wants_multiplexing (self : Query) return Boolean;

  procedure encode_result
    (self    : in Query;
     configured_values : in Values;
     output  : out Byte_Array;
     written : out Natural;
     status  : out Result_Status);

private

  package N renames Fasyn.Protocol.Name_Values;

  MANAGEMENT_NAME_LIMIT  : constant Positive := 32;
  MANAGEMENT_VALUE_LIMIT : constant Positive := 32;

  type Query is limited record
    decoder              : N.Decoder
      (max_name_bytes  => MANAGEMENT_NAME_LIMIT,
       max_value_bytes => MANAGEMENT_VALUE_LIMIT);
    max_connections_seen : Boolean := False;
    max_requests_seen    : Boolean := False;
    multiplexing_seen    : Boolean := False;
  end record;

end Fasyn.Protocol.Management;
