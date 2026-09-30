# gemstack

GemStack: a fast, modular Ruby API framework for Next.js applications.

Part of [GemStack](https://github.com/gemstack-rb/gemstack), a modular Ruby API framework for Next.js
applications by [Adware Technologies](https://www.adwaretech.com). All GemStack gems are developed
together in that repository and released with the same version.

## Installation

```bash
gem install gemstack
gemstack new myapp
```

This gem is the framework — routing, controllers, models (SQLite, PostgreSQL, MySQL), background jobs,
mail, file storage, the TypeScript contract, generators and the development server. Apps switch modules
on in `config/app.rb` (`require "gemstack/db"`, …). Authentication and realtime are the
[gemstack-auth](https://rubygems.org/gems/gemstack-auth) and
[gemstack-realtime](https://rubygems.org/gems/gemstack-realtime) gems.

## Documentation

- [Guide](https://github.com/gemstack-rb/gemstack/blob/main/docs/getting-started.md)
- [All guides](https://github.com/gemstack-rb/gemstack/tree/main/docs) ·
  [Architecture](https://github.com/gemstack-rb/gemstack/blob/main/ARCHITECTURE.md)

Source, issues and pull requests: [gemstack-rb/gemstack](https://github.com/gemstack-rb/gemstack)
(this gem lives in `gems/gemstack`).

## License

Open source under the MIT License — © [Adware Technologies](https://www.adwaretech.com). See [LICENSE.txt](LICENSE.txt).
