# frozen_string_literal: true

require "digest"
require "time"

module GemStack
  module HTTP
    # Base class for API controllers.
    #
    #   class ProductsController < ApplicationController
    #     before :load_product, only: %i[show update]
    #     rescue_from Payments::Declined, status: 402
    #
    #     def index = render(Product.all)
    #     def show = render(@product)
    #
    #     def create
    #       product = Product.create!(params.require(:product).permit(:name, :price))
    #       render product, status: :created
    #     end
    #
    #     private
    #
    #     def load_product = @product = Product.find(params[:id])
    #   end
    #
    # Actions are the public methods defined in subclasses. An action that
    # doesn't render responds 204 No Content. A `before` callback that
    # renders halts the chain and the action is skipped.
    class Controller
      class DoubleRenderError < Error; end
      class ActionNotFound < Error; end

      Callback = Struct.new(:callback_method, :block, :only, :except) do
        def applies?(action)
          (only.nil? || only.include?(action)) && (except.nil? || !except.include?(action))
        end
      end

      RescueHandler = Struct.new(:classes, :handler, :status, :code)

      class << self
        def before_callbacks = @before_callbacks ||= inherited_copy(:before_callbacks)
        def after_callbacks = @after_callbacks ||= inherited_copy(:after_callbacks)
        def rescue_handlers = @rescue_handlers ||= inherited_copy(:rescue_handlers)

        # before :authenticate, only: %i[create update]
        # before { render({ error: "..." }, status: 401) unless ok? }
        def before(*methods, only: nil, except: nil, &block)
          add_callbacks(before_callbacks, methods, block, only, except)
        end

        def after(*methods, only: nil, except: nil, &block)
          add_callbacks(after_callbacks, methods, block, only, except)
        end

        def skip_before(*methods)
          names = methods.map(&:to_sym)
          @before_callbacks = before_callbacks.reject { |cb| names.include?(cb.callback_method) }
        end

        # rescue_from Stripe::CardError, with: :card_declined
        # rescue_from Timeout::Error, status: 504, code: "upstream_timeout"
        # rescue_from(MyError) { |error| render({ message: error.message }, status: 400) }
        # Later declarations take precedence (they are checked first).
        def rescue_from(*classes, with: nil, status: nil, code: nil, &block)
          handler = with || block
          raise ArgumentError, "rescue_from needs with:, a block, or status:" unless handler || status

          rescue_handlers.unshift(RescueHandler.new(classes, handler, status, code))
        end

        # Declares the request schema for actions; `input` returns the
        # validated, coerced data inside those actions.
        #
        #   accepts :create, with: Product.input_schema
        #   accepts :update, with: Product.input_schema, partial: true
        #   accepts(:search) { required :q, :string }
        def accepts(*actions, with: nil, partial: false, &)
          schema = with || Schema.define(&)
          raise ArgumentError, "accepts needs with: SchemaClass or a block" unless schema

          schema = schema.partial if partial
          actions.each { |action| input_schemas[action.to_s] = schema }
        end

        def input_schemas = @input_schemas ||= inherited_copy(:input_schemas, {})

        # Declares an action's response type for the API contract when the
        # convention (<Resource>Serializer, see docs/typescript.md) doesn't apply:
        #   returns :search, [ProductSerializer]
        #   returns :stats, StatsSerializer
        #   returns :ping, nil          # no body
        def returns(*actions, type)
          actions.each { |action| response_types[action.to_s] = type }
        end

        def response_types = @response_types ||= inherited_copy(:response_types, {})

        # Public instance methods added by subclasses of Controller.
        def action_methods
          @action_methods ||= (public_instance_methods(true) - Controller.public_instance_methods(true))
                              .to_set(&:to_s).freeze
        end

        def method_added(name)
          super
          @action_methods = nil
        end

        def dispatch(action, env)
          raise ActionNotFound, "#{name}##{action} is not a public action" unless action_methods.include?(action)

          new(env).process(action)
        end

        private

        def inherited_copy(name, empty = [])
          superclass.respond_to?(name) ? superclass.public_send(name).dup : empty
        end

        def add_callbacks(list, methods, block, only, except)
          only &&= Array(only).map(&:to_s)
          except &&= Array(except).map(&:to_s)
          methods.each { |m| list << Callback.new(m.to_sym, nil, only, except) }
          list << Callback.new(nil, block, only, except) if block
        end
      end

      attr_reader :env, :request, :action_name

      def initialize(env)
        @env = env
        @request = Request.new(env)
        @response = nil
        @response_headers = {}
      end

      def params
        @params ||= Params.new(request.all_params)
      end

      # The validated input for the current action, as declared with `accepts`.
      def input
        @input ||= begin
          schema = self.class.input_schemas[action_name] or
            raise Error, "#{self.class.name}##{action_name} has no `accepts` declaration; use params.validate instead"
          schema.call(params)
        end
      end

      # Headers to add to the response. Set them before or after rendering.
      def headers = @response_headers

      def logger = GemStack.logger

      def rendered? = !@response.nil?

      # Renders value as JSON.
      #   render product
      #   render products, status: :ok
      #   render({ ok: true }, status: 202, headers: { "cache-control" => "no-store" })
      #   render product, serializer: Admin::ProductSerializer
      def render(value = nil, status: 200, headers: {}, serializer: nil)
        raise DoubleRenderError, "render/head called twice in #{self.class.name}##{action_name}" if rendered?

        @response_headers.merge!(headers)
        @response_headers["content-type"] ||= "application/json; charset=utf-8"
        body = serializer ? apply_serializer(serializer, value) : serialize(value)
        @response = [status_code(status), [codec.dump(body)]]
      end

      # Responds without a body: head :no_content, head 404
      def head(status, headers = {})
        raise DoubleRenderError, "render/head called twice in #{self.class.name}##{action_name}" if rendered?

        @response_headers.merge!(headers)
        @response = [status_code(status), []]
      end

      # Turns domain objects into JSON-ready structures. By convention an
      # object of class Product is rendered with ProductSerializer (also for
      # arrays and datasets of them). Values without a serializer go to the
      # JSON codec as they are. Override for custom behaviour.
      def serialize(value)
        return { data: serialize(value.items), meta: value.meta } if value.is_a?(HTTP::Page)

        Serializer.render(value, serializer_context)
      end

      # Paginates a dataset (or array) using the `page` and `per_page` query
      # parameters, bounded by config.http.pagination:
      #
      #   render paginate(Product.order(:id))
      #   render paginate(Product.where(active: true).order(:name), per_page: 50)
      #
      # Invalid values are a 422 with field errors. The dataset should be
      # ordered, or pages may overlap.
      def paginate(scope, per_page: nil)
        settings = pagination_settings
        max = settings.max_per_page
        page, size = PAGE_SCHEMA.call(params).values_at(:page, :per_page)
        size = (size || per_page || settings.per_page).clamp(1, max)
        page ||= 1
        total = scope.count
        offset = (page - 1) * size
        items = scope.is_a?(Array) ? scope[offset, size] || [] : scope.limit(size).offset(offset).all
        HTTP::Page.new(items, page: page, per_page: size, total: total)
      end

      PAGE_SCHEMA = Schema.define do
        optional :page, :integer, gte: 1
        optional :per_page, :integer, gte: 1
      end

      # HTTP caching. Sets ETag / Last-Modified and answers 304 Not Modified
      # (without rendering) when the client already has this version:
      #
      #   def show
      #     product = Product.find(params[:id])
      #     render product if stale?(etag: product, last_modified: product.updated_at)
      #   end
      #
      # etag: any value; records use #cache_key when they have one.
      def stale?(etag: nil, last_modified: nil)
        headers["etag"] = %(W/"#{Digest::SHA256.hexdigest(etag_source(etag))[0, 32]}") unless etag.nil?
        headers["last-modified"] = last_modified.httpdate if last_modified
        return true unless fresh?

        head :not_modified
        false
      end

      def fresh_when(**) = stale?(**)

      #   cache_control max_age: 60                        # private, max-age=60
      #   cache_control max_age: 300, public: true, stale_while_revalidate: 30
      #   cache_control :no_store
      def cache_control(directive = nil, max_age: nil, public: false, stale_while_revalidate: nil)
        headers["cache-control"] =
          if directive == :no_store then "no-store"
          else
            [public ? "public" : "private", ("max-age=#{Integer(max_age)}" if max_age),
             ("stale-while-revalidate=#{Integer(stale_while_revalidate)}" if stale_while_revalidate)].compact.join(", ")
          end
      end

      # Passed to serializers as `context` (e.g. { current_user: current_user }).
      def serializer_context = {}

      def process(action)
        @action_name = action
        run_callbacks(self.class.before_callbacks)
        public_send(action) unless rendered?
        run_callbacks(self.class.after_callbacks)
        finish
      rescue StandardError => e
        handle_exception(e)
        finish
      end

      private

      def finish
        head(:no_content) unless rendered?
        status, body = @response
        [status, @response_headers, body]
      end

      def run_callbacks(callbacks)
        callbacks.each do |callback|
          next unless callback.applies?(@action_name)

          callback.callback_method ? send(callback.callback_method) : instance_exec(&callback.block)
          break if rendered? && callbacks.equal?(self.class.before_callbacks)
        end
      end

      def handle_exception(error)
        rescuer = self.class.rescue_handlers.find { |h| h.classes.any? { |klass| error.is_a?(klass) } }
        raise error unless rescuer

        @response = nil
        @response_headers = @response_headers.slice("x-request-id")
        if rescuer.handler
          rescuer.handler.is_a?(Proc) ? instance_exec(error, &rescuer.handler) : call_handler(rescuer.handler, error)
        else
          status = status_code(rescuer.status)
          wrapped = GemStack::Error.new(error.message, status: status,
                                                       code: rescuer.code || ErrorRenderer.code_for(status))
          status, headers, body = ErrorRenderer.render(wrapped, request_id: request.request_id)
          @response_headers.merge!(headers)
          @response = [status, body]
        end
      end

      def pagination_settings = (env[CONFIG] || Config.new).pagination

      def etag_source(value)
        case value
        when Array then value.map { |v| etag_source(v) }.join("/")
        else value.respond_to?(:cache_key) ? value.cache_key.to_s : value.to_s
        end
      end

      def fresh?
        none_match = request.get_header("HTTP_IF_NONE_MATCH")
        etag = headers["etag"]
        if none_match && etag
          tags = none_match.split(",").map { |t| t.strip.delete_prefix("W/") }
          return tags.include?("*") || tags.include?(etag.delete_prefix("W/"))
        end
        modified_since = request.get_header("HTTP_IF_MODIFIED_SINCE")
        last_modified = headers["last-modified"]
        return false unless modified_since && last_modified

        Time.httpdate(last_modified) <= Time.httpdate(modified_since)
      rescue ArgumentError
        false
      end

      def apply_serializer(serializer, value)
        return { data: serializer.many(value.items, serializer_context), meta: value.meta } if value.is_a?(HTTP::Page)

        list = value.is_a?(Array) || (value.respond_to?(:all) && value.respond_to?(:model))
        list ? serializer.many(value, serializer_context) : serializer.serialize(value, serializer_context)
      end

      def call_handler(name, error)
        method(name).arity.zero? ? send(name) : send(name, error)
      end

      def status_code(status)
        return status if status.is_a?(Integer)

        Rack::Utils::SYMBOL_TO_STATUS_CODE.fetch(status.to_sym) { raise ArgumentError, "unknown status #{status}" }
      end

      def codec = env[JSON_CODEC] || JSONCodec.default
    end
  end
end
