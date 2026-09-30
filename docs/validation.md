# Validation

Request input is validated and coerced by **schemas** (`GemStack::Schema`).
Model validations (see [models](models.md)) are a second line of defence at
the data layer.

## In controllers

```ruby
class ProductsController < ApplicationController
  accepts :create, with: Product.input_schema               # derived from Product's fields
  accepts :update, with: Product.input_schema, partial: true
  accepts(:search) { required :q, :string, min_length: 2 }  # GET → validates the query string

  def create = render(Product.create(input), status: :created)
  def search = render(Product.where(Sequel.ilike(:name, "%#{input[:q]}%")))
end
```

`input` is the validated data for the current action: a Hash with symbol
keys containing **only declared fields**, coerced to their types. Because
`accepts` is declared on the class, the same schema also types the generated
TypeScript client (`products.create(data: ProductInput)`).

For one-off validation:

```ruby
attrs = params.validate do
  required :email, :string, format: /@/
  optional :age, :integer, gte: 0
end
```

## Schema classes

```ruby
class SignupInput < GemStack::Schema
  required :email, :string, max_length: 255, format: /\A[^@\s]+@[^@\s]+\z/
  required :plan, :string, in: %w[free pro]
  optional :seats, :integer, gte: 1, default: 1
  optional :tags, [:string]                  # list of scalars
  optional :company do                       # nested object
    required :name, :string
  end
  optional :members, :array do               # list of objects
    required :email, :string
  end
  optional :note, :text, nullable: true      # explicit null allowed
end

SignupInput.call(params)                     # => {...} or raises 422
result, errors = SignupInput.validate(params) # no raise
SignupInput.partial                          # everything optional, no defaults
GemStack::Schema.from_model(Product, only: %i[name price])
```

Types are the shared GemStack types (`:string`, `:decimal`, ... or Ruby
classes like `Integer`). Rules: `gt gte lt lte min_length max_length in format`.

### Coercion rules

- `"12"` → `12` for `:integer`, `"9.99"` → `BigDecimal` for `:decimal`,
  `"true"/"1"/"on"` → `true`, ISO strings → `Date`/`Time`.
- An empty string for a non-string field means "not given" (HTML forms).
- A blank required string is "is required".
- Absent + `default:` → the default. Explicit `null` → `nil` if `nullable: true`,
  otherwise "can't be null".
- Unknown keys are dropped.

## Error format

```json
{
  "error": { "code": "validation_failed", "message": "Validation failed", "request_id": "…" },
  "errors": { "price": ["must be greater than 0"], "company.name": ["is required"], "tags.2": ["must be a string"] }
}
```

The TypeScript client exposes these as `ApiError.errors`; generated forms show
them under each field.
