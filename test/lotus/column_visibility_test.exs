defmodule Lotus.ColumnVisibilityTest do
  use ExUnit.Case
  use Mimic

  alias Lotus.Schema
  alias Lotus.Visibility

  setup do
    Mimic.copy(Lotus.Config)
    Mimic.copy(Lotus.Source.Adapter)
    Mimic.copy(Lotus.Source)
    :ok
  end

  describe "column policy resolution" do
    setup do
      # Default: mask to NULL, visible in schema
      rules = [
        {"public", "users", "password", [mask: :sha256]},
        {"users", "api_key", :omit},
        {"password_hash", :error}
      ]

      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _repo -> rules end)

      :ok
    end

    test "most specific schema+table+column match wins" do
      rels = [{"public", "users"}]

      pol = Visibility.column_policy_for("postgres", rels, "password")
      assert pol.action == :mask
      assert pol.mask == :sha256
      assert pol.show_in_schema? == true
    end

    test "table+column match applies when schema not specified" do
      rels = [{"public", "users"}]

      pol = Visibility.column_policy_for("postgres", rels, "api_key")
      assert pol.action == :omit
      assert pol.show_in_schema? == true
    end

    test "column-only rule applies across any table/schema" do
      rels = [{"public", "users"}]

      pol = Visibility.column_policy_for("postgres", rels, "password_hash")
      assert pol.action == :error
      assert pol.show_in_schema? == true
    end
  end

  describe "default policy values" do
    setup do
      # No explicit action -> default to mask:null
      rules = [
        {"users", "password", []},
        {"users", "token", [mask: :sha256]},
        {"users", "secret", [mask: {:fixed, "REDACTED"}]}
      ]

      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _repo -> rules end)

      :ok
    end

    test "defaults to mask:null with show_in_schema? true" do
      pol = Visibility.column_policy_for("postgres", [{"public", "users"}], "password")
      assert pol.action == :mask
      assert pol.mask == :null
      assert pol.show_in_schema? == true
    end

    test "keeps show_in_schema? true by default" do
      pol = Visibility.column_policy_for("postgres", [{"public", "users"}], "token")
      assert pol.action == :mask
      assert pol.mask == :sha256
      assert pol.show_in_schema? == true
    end
  end

  describe "schema introspection annotations and hiding" do
    setup do
      Mimic.copy(Lotus.Visibility)

      # Rules for users.password: masked; users.secret: hidden from introspection
      rules = [
        {"public", "users", "password", [mask: :null, show_in_schema?: true]},
        {"public", "users", "secret",
         [action: :mask, mask: {:fixed, "REDACTED"}, show_in_schema?: false]}
      ]

      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _repo -> rules end)

      Lotus.Visibility
      |> stub(:allowed_relation?, fn _, _ -> true end)

      :ok
    end

    test "describe_table annotates visibility and preserves visible columns" do
      mock_adapter = %Lotus.Source.Adapter{
        name: "postgres",
        module: Lotus.Source.Adapters.Ecto,
        state: Lotus.Test.Repo,
        source_type: :postgres
      }

      Lotus.Source
      |> stub(:resolve!, fn _repo_opt, _fallback -> mock_adapter end)

      Lotus.Source.Adapter
      |> stub(:resolve_table_namespace, fn _adapter, _table, _schemas -> {:ok, "public"} end)

      Lotus.Source.Adapter
      |> stub(:describe_table, fn _adapter, _schema, _table ->
        {:ok,
         [
           %{name: "id", type: "integer", nullable: false, default: nil, primary_key: true},
           %{name: "password", type: "text", nullable: true, default: nil, primary_key: false},
           %{name: "secret", type: "text", nullable: true, default: nil, primary_key: false}
         ]}
      end)

      Lotus.Source.Adapter
      |> stub(:default_schemas, fn _adapter -> ["public"] end)

      {:ok, cols} = Schema.describe_table("postgres", "users", schema: "public")

      names = Enum.map(cols, & &1.name)
      # secret should be hidden in introspection
      assert names == ["id", "password"]

      pw = Enum.find(cols, &(&1.name == "password"))
      assert pw.visibility == %{action: :mask, mask: :null}
    end
  end
end
