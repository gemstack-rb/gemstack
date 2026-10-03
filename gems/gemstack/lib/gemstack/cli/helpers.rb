# frozen_string_literal: true

module GemStack
  module CLIHelpers
    # -e ENV, else GEMSTACK_ENV, else development.
    def use_environment!
      ENV["GEMSTACK_ENV"] = options[:environment] || ENV["GEMSTACK_ENV"] || "development"
    end

    def generate_model(root, name, args)
      abort("Usage: gemstack generate model NAME field:type ...") unless name && !args.empty?
      spec = ResourceSpec.new(name, args)
      ResourceGenerator.new(
        spec,
        root: root,
        parts: %i[migration model serializer],
        tests: !options[:skip_tests],
        force: options[:force]
      ).run
      say("\nNext: gemstack db:migrate")
    end

    def generate_job(root, name, args)
      abort("Usage: gemstack generate job NAME [QUEUE]") unless name
      JobGenerator.new(name, queue: args.first, root: root, force: options[:force]).run
      say("\nNext: gemstack db:migrate (first job only) · #{Inflector.camelize(name)}.perform_later(...)")
    end

    def generate_policy(root, name)
      abort("Usage: gemstack generate policy MODEL") unless name
      PolicyGenerator.new(name, root: root, force: options[:force]).run
      say("\nNext: authorize!(record) and policy_scope(#{Inflector.camelize(name)}) in controllers")
    end

    def generate_resource(root, name, args)
      abort("Usage: gemstack generate resource NAME field:type ...") unless name
      abort("--api-only and --frontend-only can't be combined") if options[:api_only] && options[:frontend_only]
      interactive = args.empty? && $stdin.tty?
      args = ask("Fields (e.g. name:string price:decimal description:text:optional):").split if interactive
      abort("Give at least one field, e.g. `gemstack generate resource #{name} name:string`") if args.empty?

      spec = ResourceSpec.new(name, args, actions: resource_actions(interactive))
      parts = resource_parts(root, interactive)
      tests = !options[:skip_tests] && (!interactive || yes?("Generate tests? [Y/n]"))
      ResourceGenerator.new(spec, root: root, parts: parts, tests: tests, force: options[:force]).run
      refresh_contract(root) unless options[:skip_contract]
      page = " · open http://localhost:3000/#{spec.url_segment}" if parts.include?(:frontend)
      say("\nNext: gemstack db:migrate#{page}")
    end

    def resource_parts(root, interactive)
      parts = options[:frontend_only] ? [] : %i[migration model serializer controller]
      frontend = File.directory?(File.join(root, "frontend")) && !options[:api_only]
      frontend &&= yes?("Generate Next.js pages? [Y/n]") if interactive
      frontend ? parts + [:frontend] : parts
    end

    def resource_actions(interactive)
      return options[:actions].split(",").map(&:strip) if options[:actions]
      return ResourceSpec::REST_ACTIONS if !interactive || yes?("Generate the full CRUD API? [Y/n]")

      ask("Actions (comma-separated from #{ResourceSpec::REST_ACTIONS.join(",")}):").split(",").map(&:strip)
    end

    # Thor's yes? only accepts y/yes; treat an empty answer as "yes".
    def yes?(question)
      answer = ask(question).strip.downcase
      answer.empty? || %w[y yes].include?(answer)
    end

    # Regenerates TypeScript types/clients in the app's own bundle.
    def refresh_contract(root)
      say("  #{"run".rjust(9)}  gemstack contract")
      ok = (defined?(Bundler) ? Bundler.with_unbundled_env { contract_command(root) } : contract_command(root))
      return if ok

      say("  #{"warning".rjust(9)}  contract not generated — run `gemstack contract` once the database is reachable")
    end

    def contract_command(root)
      system("bundle", "exec", "gemstack", "contract", "--quiet", chdir: root)
    end
  end
end
