-- ============================================================================
-- fasyn-request-testing.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package body Fasyn.Request.Testing is

  function output_length (self : Writer) return Natural is
  begin
    return self.length;
  end output_length;

  procedure consume_output
    (self  : in out Writer;
     count : Natural)
  is
  begin
    consume_buffered (self, count);
  end consume_output;

  function output_byte
    (self  : Writer;
     index : Positive)
  return Fasyn.Protocol.Byte is
  begin
    return buffered_byte (self, index);
  end output_byte;

end Fasyn.Request.Testing;
