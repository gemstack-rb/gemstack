# Mail

New apps load it (`require "gemstack/mail"` in `config/app.rb`) and include `app/mailers/application_mailer.rb`, the
base class for your mailers (shared `default from:` and helpers). Mailers live
in `app/mailers`:

```ruby
class OrderMailer < ApplicationMailer
  default from: "Shop <orders@shop.example>"

  def shipped(order_id)
    @order = Order[order_id] or return       # returning without `mail` sends nothing
    mail to: @order.email, subject: "Your order is on its way"
  end
end

OrderMailer.shipped(order.id).deliver_later   # from a background job (pass ids, not records)
OrderMailer.shipped(order.id).deliver_now
```

Bodies come from templates next to the mailer:

```
app/mailers/templates/order_mailer/shipped.text.erb
app/mailers/templates/order_mailer/shipped.html.erb
```

Instance variables set in the action are available in both. HTML templates
**escape** `<%= %>` output; use `<%== %>` only for markup you trust. Give
`text:` / `html:` to `mail` to skip templates.

## Delivery

| Environment | Default | |
| --- | --- | --- |
| development | `:log` | logged, and saved to `tmp/mail/*.eml` + `.html` to open in a browser |
| test | `:test` | collected in `GemStack::Mail.deliveries` |
| production | `:smtp` | `SMTP_URL=smtp://user:pass@smtp.example.com:587` (STARTTLS) or `smtps://…:465` |

```ruby
config.mail.delivery = :smtp               # or an object with #deliver(message) for an API provider
config.mail.default_from = "Shop <hello@shop.example>"   # default: MAIL_FROM
config.mail.queue = "mailers"               # deliver_later's queue
```

`deliver_later` uses `GemStack::Jobs`: failed deliveries are
retried with backoff, and — with the database queue — an email enqueued in a
transaction that rolls back is never sent.

## Testing

```ruby
assert_emails(1) { post_json "/api/auth/password/forgot", { email: user.email } }
assert_equal [user.email], last_email.to
assert_includes last_email.text_part.decoded, "reset-password?token="
```

`assert_emails` also runs the delivery jobs enqueued inside its block.
