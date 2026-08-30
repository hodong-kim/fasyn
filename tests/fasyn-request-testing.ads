-- ============================================================================
-- fasyn-request-testing.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Fasyn.Protocol;

package Fasyn.Request.Testing is

  function output_length (self : Writer) return Natural;

  function output_byte
    (self  : Writer;
     index : Positive)
  return Fasyn.Protocol.Byte;

end Fasyn.Request.Testing;
