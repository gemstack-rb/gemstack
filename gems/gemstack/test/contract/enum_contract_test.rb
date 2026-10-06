# frozen_string_literal: true

require "test_helper"

# A model-like class: enums are fields with enum: values (GemStack::Model#enum).
class CeTicket
  Field = Struct.new(:name, :type, :options)

  def self.gemstack_fields
    { status: Field.new(:status, :string, { null: false, enum: %w[open closed] }),
      title: Field.new(:title, :string, { null: false }) }
  end
end

class CeTicketSerializer < GemStack::Serializer
  attributes :status, :title
  attribute :label, :string # explicit types stay as declared
end

class CeTicketInput < GemStack::Schema
  required :status, :string, enum: %w[open closed]
  optional :tags, [:string], enum: %w[bug idea]
end

class CeTicketsController < GemStack::HTTP::Controller
  accepts :create, with: CeTicketInput
  def create; end
  def show; end
end

class EnumContractTest < Minitest::Test
  FakeApp = Struct.new(:routes, :config) do
    def eager_load! = nil
  end

  def contract
    @contract ||= begin
      router = GemStack::HTTP::Router.new(prefix: "/api").draw { resources :ce_tickets, only: %i[create show] }
      GemStack::Contract.build(FakeApp.new(router.routes, GemStack::Config.new))
    end
  end

  def test_enums_are_union_types
    ts = GemStack::Contract::TypeScript.new(contract).files["types.ts"]

    assert_includes ts, %(status: "open" | "closed";)        # serializer, inferred from the model
    assert_includes ts, "label: string;"
    assert_includes ts, %(tags?: Array<"bug" | "idea">;)     # request schema
  end

  def test_enums_in_openapi
    schemas = GemStack::Contract::OpenAPI.new(contract).document[:components][:schemas]

    assert_equal({ type: "string", enum: %w[open closed] }, schemas["CeTicket"][:properties]["status"])
    assert_equal({ type: "string", enum: %w[open closed] }, schemas["CeTicketInput"][:properties]["status"])
  end

  def test_the_schema_accepts_only_the_values
    assert_equal({ status: "open" }, CeTicketInput.call("status" => "open"))
    error = assert_raises(GemStack::ValidationError) { CeTicketInput.call("status" => "lost", "tags" => %w[bug x]) }

    assert_equal({ "status" => ["must be one of: open, closed"], "tags.1" => ["must be one of: bug, idea"] }, error.errors)
    assert_equal "Validation failed: status must be one of: open, closed, tags.1 must be one of: bug, idea", error.message
  end
end
