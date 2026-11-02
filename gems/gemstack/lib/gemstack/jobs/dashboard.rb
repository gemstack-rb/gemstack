# frozen_string_literal: true

module GemStack
  module Jobs
    # Adapter-backed operations used by the built-in jobs dashboard. This
    # boundary keeps queue SQL and row decoding in the adapter.
    class Dashboard
      class UnsupportedAdapter < Error; end

      def initialize(adapter: nil)
        @adapter = adapter
      end

      def available?
        return database_adapter?(@adapter) if @adapter

        Jobs.database_queue?
      end

      def stats = database_adapter.stats

      def list(state: nil, queue: nil, page: 1, per_page: 25)
        database_adapter.list_jobs(state: state, queue: queue, page: page, per_page: per_page)
      end

      def find(id) = database_adapter.find_job(id)

      def retry_failed(id) = database_adapter.retry_failed_job(id)

      def discard_failed(id) = database_adapter.discard_failed_job(id)

      def retry_failed_jobs(ids) = database_adapter.retry_failed_jobs(ids)

      def run_now(id) = database_adapter.run_job_now(id)

      def delete_pending(id) = database_adapter.delete_pending_job(id)

      def run_now_jobs(ids) = database_adapter.run_jobs_now(ids)

      def delete_jobs(ids) = database_adapter.delete_jobs(ids)

      private

      def database_adapter
        adapter = @adapter || (Jobs.adapter if Jobs.database_queue?)
        raise UnsupportedAdapter, "the jobs dashboard requires the :database adapter" unless database_adapter?(adapter)

        adapter
      end

      def database_adapter?(adapter)
        adapter.is_a?(Adapters::Database) ||
          (adapter.respond_to?(:list_jobs) && adapter.respond_to?(:find_job) &&
           adapter.respond_to?(:retry_failed_job) && adapter.respond_to?(:discard_failed_job) &&
           adapter.respond_to?(:retry_failed_jobs) && adapter.respond_to?(:run_job_now) &&
           adapter.respond_to?(:delete_pending_job) && adapter.respond_to?(:run_jobs_now) &&
           adapter.respond_to?(:delete_jobs))
      end
    end
  end
end
