# frozen_string_literal: true

require 'active_support/subscriber'

# Subscriber that is attached to ActiveRecord and will handle writing
# migration SQL to the output stream.
module CaptureMigrationSql
  class SqlSubscriber < ::ActiveSupport::Subscriber
    IGNORE_PAYLOAD_NAMES = ["SCHEMA", "EXPLAIN"]

    SHOW_STATEMENT = /\ASHOW\b/i
    EXPLAIN_STATEMENT = /\AEXPLAIN\b/i
    SELECT_SCHEMA_MIGRATIONS = /\ASELECT.*FROM.*schema_migrations/i
    SELECT_INFORMATION_SCHEMA = /\ASELECT.*information_schema/im
    SQLLITE_VERSION = /\ASELECT sqlite_version\(/i
    IGNORE_STATEMENTS = Regexp.union(SHOW_STATEMENT, EXPLAIN_STATEMENT, SELECT_SCHEMA_MIGRATIONS, SELECT_INFORMATION_SCHEMA, SQLLITE_VERSION)

    class << self
      def attach_if_necessary
        unless defined?(@attached) && @attached
          attach_to(:active_record)
          @attached = true
        end
      end
    end

    def sql(event)
      stream = CaptureMigrationSql.capture_stream
      return unless stream && CaptureMigrationSql.capture_enabled?

      payload = event.payload
      return if IGNORE_PAYLOAD_NAMES.include?(payload[:name])
      sql = sql_from_payload payload
      return if sql.nil? || IGNORE_STATEMENTS.match(sql)

      sql = sql.strip
      sql = "#{sql};" unless sql.end_with?(";")
      stream.write("#{sql}\n\n")
    end

    def sql_from_payload(payload)
      if payload[:binds] == []
        payload[:sql]
      else
        prepared_stmt payload
      end
    end

    def prepared_stmt(payload)
      types = payload[:binds].map do 'unknown' end
      vars = payload[:binds].map do |b|
        if ((b.type.class == ActiveModel::Type::String) ||
            (b.type.class == ActiveRecord::Type::Text))
          "'#{b.value}'"
        else
          b.value_for_database
        end
      end
      stmts = [
        "prepare _tmpqry (#{types.join ','}) as\n#{payload[:sql]}",
        "execute _tmpqry (#{vars.join ','})",
        "deallocate _tmpqry"
      ]
      stmts.join ";\n"
    end
  end
end
