# frozen_string_literal: true

module GemStack
  # Base class for background jobs. See GemStack::Jobs.
  #
  #   class ImportProducts < GemStack::Job
  #     queue :imports
  #     priority 10                                          # lower runs first (default 100)
  #     retry_on Faraday::TimeoutError, attempts: 5, wait: :exponential
  #     discard_on GemStack::NotFound                        # the record is gone; nothing to do
  #
  #     def perform(import_id, options = {})
  #       ...
  #     end
  #   end
  #
  #   ImportProducts.perform_later(import.id)                       # => job id
  #   ImportProducts.set(wait: 300, queue: "slow").perform_later(1)  # in 5 minutes
  #   ImportProducts.set(at: Time.now + 3600).perform_later(1)
  #   ImportProducts.perform_now(1)                                 # synchronously
  #
  # Arguments must be JSON values (strings, numbers, booleans, nil, arrays,
  # hashes with string or symbol keys). Pass ids, not records. Hash keys come
  # back as strings.
  class Job
    RetryRule = Struct.new(:classes, :attempts, :wait)

    class << self
      def queue(name = nil)
        @queue = name.to_s if name
        @queue || (superclass.respond_to?(:queue) ? superclass.queue : Jobs.config.default_queue)
      end

      def priority(value = nil)
        @priority = Integer(value) if value
        @priority || (superclass.respond_to?(:priority) ? superclass.priority : Jobs.config.default_priority)
      end

      # retry_on Net::ReadTimeout, attempts: 5, wait: 30          # fixed seconds
      # retry_on StandardError, wait: :exponential                 # default
      # retry_on Api::RateLimited, wait: ->(attempt) { attempt * 60 }
      # The first matching rule (most recently declared first) decides.
      def retry_on(*classes, attempts: nil, wait: :exponential)
        retry_rules.unshift(RetryRule.new(classes, attempts, wait))
      end

      # Errors that mean the job should simply be dropped (logged, not retried).
      def discard_on(*classes)
        discard_classes.concat(classes)
      end

      def retry_rules = @retry_rules ||= superclass.respond_to?(:retry_rules) ? superclass.retry_rules.dup : []

      def discard_classes
        @discard_classes ||= superclass.respond_to?(:discard_classes) ? superclass.discard_classes.dup : []
      end

      def perform_later(*) = Enqueuer.new(self).perform_later(*)
      def set(**) = Enqueuer.new(self, **)

      def perform_now(*args)
        new.perform(*Jobs::Arguments.load(Jobs::Arguments.dump(args)))
      end

      # [max attempts, seconds to wait before the next attempt] for an error
      # raised on attempt number `attempt` (1-based); nil wait = give up.
      def retry_decision(error, attempt)
        rule = retry_rules.find { |r| r.classes.any? { |klass| error.is_a?(klass) } }
        max = rule&.attempts || Jobs.config.default_max_attempts
        return [max, nil] if attempt >= max

        [max, backoff(rule&.wait || :exponential, attempt)]
      end

      def discard?(error) = discard_classes.any? { |klass| error.is_a?(klass) }

      private

      # Sidekiq's curve: 16s, 31s, 96s, 271s, … ≈ 4 hours over 10 attempts.
      def backoff(wait, attempt)
        case wait
        when :exponential then (attempt**4) + 15 + (rand(10) * attempt)
        when Proc then Float(wait.call(attempt))
        else Float(wait)
        end
      end
    end

    # Builds the payload for a (possibly customised) enqueue.
    class Enqueuer
      def initialize(job_class, wait: nil, at: nil, queue: nil, priority: nil)
        @job_class = job_class
        @run_at = at || (wait && (Time.now + Float(wait)))
        @queue = queue&.to_s
        @priority = priority
      end

      def perform_later(*args)
        payload = {
          "job_class" => @job_class.name,
          "queue" => @queue || @job_class.queue,
          "priority" => @priority || @job_class.priority,
          "args" => Jobs::Arguments.dump(args),
          "run_at" => @run_at
        }
        raise ArgumentError, "anonymous job classes can't be enqueued" unless payload["job_class"]

        id = Jobs.adapter.enqueue(payload)
        Jobs.instrument(:enqueued, job_class: payload["job_class"], job_id: id, queue: payload["queue"],
                                   run_at: payload["run_at"])
        id
      end
    end

    # Subclasses implement this.
    def perform(*)
      raise NotImplementedError, "#{self.class.name}#perform is not implemented"
    end

    # Set by the executor for the running job.
    attr_accessor :job_id, :attempt
  end

  module Jobs
    # Validates and converts arguments to/from their JSON form.
    module Arguments
      module_function

      def dump(args) = args.map { |arg| dump_value(arg, "argument") }

      def load(json) = json

      def dump_value(value, path)
        case value
        when String, Integer, true, false, nil then value
        when Float then value.finite? ? value : invalid(value, path)
        when Symbol then value.name
        when Array then value.each_with_index.map { |v, i| dump_value(v, "#{path}[#{i}]") }
        when Hash
          value.to_h do |key, v|
            invalid(key, "#{path} key") unless key.is_a?(String) || key.is_a?(Symbol)
            [key.to_s, dump_value(v, "#{path}[#{key.inspect}]")]
          end
        else invalid(value, path)
        end
      end

      def invalid(value, path)
        hint = value.respond_to?(:pk) || value.respond_to?(:id) ? " — pass its id instead" : ""
        raise SerializationError, "#{path} #{value.class} can't be serialized to JSON#{hint}"
      end
    end
  end
end
