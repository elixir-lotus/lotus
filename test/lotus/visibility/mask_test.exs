defmodule Lotus.Visibility.MaskTest do
  use ExUnit.Case, async: true

  alias Lotus.Visibility.Mask

  doctest Mask

  describe ":null" do
    test "replaces any value with nil" do
      assert Mask.apply("secret", :null) == nil
      assert Mask.apply(42, :null) == nil
      assert Mask.apply(nil, :null) == nil
    end
  end

  describe "{:fixed, value}" do
    test "replaces any value with the fixed value" do
      assert Mask.apply("secret", {:fixed, "REDACTED"}) == "REDACTED"
      assert Mask.apply(42, {:fixed, 0}) == 0
      assert Mask.apply(nil, {:fixed, "REDACTED"}) == "REDACTED"
    end
  end

  describe ":sha256" do
    test "hashes a binary as its bytes" do
      assert Mask.apply("secret", :sha256) == sha256_hex("secret")
      assert Mask.apply(<<222, 173, 190, 239>>, :sha256) == sha256_hex(<<222, 173, 190, 239>>)
    end

    test "hashes the display string of a value that is not a binary" do
      assert Mask.apply(%{"a" => 1}, :sha256) ==
               sha256_hex(Lotus.Value.to_display_string(%{"a" => 1}))

      assert Mask.apply(42, :sha256) == sha256_hex("42")
    end

    test "hashes nil as the empty string" do
      assert Mask.apply(nil, :sha256) == sha256_hex("")
    end
  end

  describe "{:partial, opts}" do
    test "keeps the last 4 characters by default" do
      assert Mask.apply("555-123-4567", {:partial, []}) == "********4567"
    end

    test "keeps the first and last characters with a custom replacement" do
      assert Mask.apply(
               "john@example.com",
               {:partial, keep_first: 2, keep_last: 4, replacement: "#"}
             ) ==
               "jo##########.com"
    end

    test "counts characters, not bytes, in valid UTF-8" do
      assert Mask.apply("ação-1234", {:partial, keep_first: 1, keep_last: 2}) == "a******34"
    end

    test "masks a value completely when the kept ends cover all of it" do
      assert Mask.apply("1234", {:partial, keep_last: 4}) == "****"
      assert Mask.apply("abc", {:partial, keep_first: 2, keep_last: 2}) == "***"
    end

    test "masks every byte of a binary that is not valid UTF-8" do
      assert Mask.apply(<<222, 173, 190, 239, 1, 2>>, {:partial, keep_last: 4}) == "******"
    end

    test "masks the display string of a value that is not a binary" do
      assert Mask.apply(123_456_789, {:partial, keep_last: 2}) == "*******89"
    end

    test "masks nil as the empty string" do
      assert Mask.apply(nil, {:partial, keep_last: 4}) == ""
    end
  end

  describe "{:partial, opts} with keep_domain: true" do
    test "keeps the domain and masks the local part" do
      assert Mask.apply("alice@example.com", {:partial, keep_domain: true, keep_last: 0}) ==
               "*****@example.com"
    end

    test "applies keep_first, keep_last and replacement to the local part" do
      opts = [keep_domain: true, keep_first: 1, keep_last: 1, replacement: "#"]
      assert Mask.apply("alice@example.com", {:partial, opts}) == "a###e@example.com"
    end

    test "uses the default keep_last on the local part" do
      assert Mask.apply("alexandra@example.com", {:partial, keep_domain: true}) ==
               "*****ndra@example.com"
    end

    test "splits at the last @" do
      assert Mask.apply("a@b@example.com", {:partial, keep_domain: true, keep_last: 0}) ==
               "***@example.com"
    end

    test "masks a local part completely when the kept ends cover all of it" do
      assert Mask.apply("bob@example.com", {:partial, keep_domain: true}) == "***@example.com"
    end

    test "masks a value with no @ completely" do
      assert Mask.apply("not-an-email", {:partial, keep_domain: true, keep_first: 2}) ==
               "************"
    end

    test "masks every byte of a binary that is not valid UTF-8" do
      assert Mask.apply(<<222, ?@, 190>>, {:partial, keep_domain: true}) == "***"
    end
  end

  test "an unknown strategy replaces the value with nil" do
    assert Mask.apply("secret", :unknown) == nil
    assert Mask.apply("secret", nil) == nil
  end

  defp sha256_hex(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
end
