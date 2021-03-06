require 'sequel'

module Moneta
  module Adapters
    # Sequel backend
    # @api public
    class Sequel
      include Defaults

      # Sequel::UniqueConstraintViolation is defined since sequel 3.44.0
      # older versions raise a Sequel::DatabaseError.
      UniqueConstraintViolation = defined?(::Sequel::UniqueConstraintViolation) ? ::Sequel::UniqueConstraintViolation : ::Sequel::DatabaseError

      supports :create, :increment
      attr_reader :backend, :key_column, :value_column

      # @param [Hash] options
      # @option options [String] :db Sequel database
      # @option options [String, Symbol] :table (:moneta) Table name
      # @option options [Array] :extensions ([]) List of Sequel extensions
      # @option options [Integer] :connection_validation_timeout (nil) Sequel connection_validation_timeout
      # @option options [Sequel::Database] :backend Use existing backend instance
      # @option options [Boolean] :optimize (true) Set to false to prevent database-specific optimisations
      # @option options [Proc, Boolean] :create_table Provide a Proc for creating the table, or
      #   set to false to disable table creation all together.  If a Proc is given, it will be
      #   called regardless of whether the table exists already.
      # @option options [Symbol] :key_column (:k) The name of the key column
      # @option options [Symbol] :value_column (:v) The name of the value column
      # @option options [String] :hstore If using Postgres, keys and values are stored in a single
      #   row of the table in the value_column using the hstore format.  The row to use is
      #   the one where the value_column is equal to the value of this option, and will be created
      #   if it doesn't exist.
      # @option options All other options passed to `Sequel#connect`
      def self.new(options = {})
        extensions = options.delete(:extensions)
        connection_validation_timeout = options.delete(:connection_validation_timeout)
        optimize = options.delete(:optimize)
        backend = options.delete(:backend) ||
          begin
            raise ArgumentError, 'Option :db is required' unless db = options.delete(:db)
            other_cols = [:table, :create_table, :key_column, :value_column, :hstore]
            ::Sequel.connect(db, options.reject { |k,_| other_cols.member?(k) }).tap do |backend|
              if extensions
                raise ArgumentError, 'Option :extensions must be an Array' unless extensions.is_a?(Array)
                extensions.map(&:to_sym).each(&backend.method(:extension))
              end

              if connection_validation_timeout
                backend.pool.connection_validation_timeout = connection_validation_timeout
              end
            end
          end

        instance =
          if optimize.nil? || optimize
            case backend.database_type
            when :mysql
              MySQL.allocate
            when :postgres
              if options[:hstore]
                PostgresHStore.allocate
              elsif matches = backend.get(::Sequel[:version].function).match(/PostgreSQL (\d+)\.(\d+)/)
                # Our optimisations only work on Postgres 9.5+
                major, minor = matches[1..2].map(&:to_i)
                Postgres.allocate if major > 9 || (major == 9 && minor >= 5)
              end
            when :sqlite
              SQLite.allocate
            end
          end || allocate

        instance.send(:initialize, options, backend)
        instance
      end

      # @api private
      def initialize(options, backend)
        @backend = backend
        @table_name = (options.delete(:table) || :moneta).to_sym
        @key_column = options.delete(:key_column) || :k
        @value_column = options.delete(:value_column) || :v

        create_proc = options.delete(:create_table)
        if create_proc.nil?
          create_table
        elsif create_proc
          create_proc.call(@backend)
        end

        @table = @backend[@table_name]
      end

      # (see Proxy#key?)
      def key?(key, options = {})
        !@table.where(key_column => key).empty?
      end

      # (see Proxy#load)
      def load(key, options = {})
        @table.where(key_column => key).get(value_column)
      end

      # (see Proxy#store)
      def store(key, value, options = {})
        blob_value = blob(value)
        unless @table.where(key_column => key).update(value_column => blob(value)) == 1
          @table.insert(key_column => key, value_column => blob(value))
        end
        value
      rescue ::Sequel::DatabaseError
        tries ||= 0
        (tries += 1) < 10 ? retry : raise
      end

      # (see Proxy#store)
      def create(key, value, options = {})
        @table.insert(key_column => key, value_column => blob(value))
        true
      rescue UniqueConstraintViolation
        false
      end

      # (see Proxy#increment)
      def increment(key, amount = 1, options = {})
        @backend.transaction do
          if existing = @table.where(key_column => key).for_update.get(value_column)
            total = amount + Integer(existing)
            raise "no update" unless @table.
              where(key_column => key).
              update(value_column => blob(total.to_s)) == 1
            total
          else
            @table.insert(key_column => key, value_column => blob(amount.to_s))
            amount
          end
        end
      rescue ::Sequel::DatabaseError
        # Concurrent modification might throw a bunch of different errors
        tries ||= 0
        (tries += 1) < 10 ? retry : raise
      end

      # (see Proxy#delete)
      def delete(key, options = {})
        value = load(key, options)
        @table.filter(key_column => key).delete
        value
      end

      # (see Proxy#clear)
      def clear(options = {})
        @table.delete
        self
      end

      # (see Proxy#close)
      def close
        @backend.disconnect
        nil
      end

      private

      # See https://github.com/jeremyevans/sequel/issues/715
      def blob(s)
        s.empty? ? '' : ::Sequel.blob(s)
      end

      def create_table
        key_column = self.key_column
        value_column = self.value_column
        @backend.create_table?(@table_name) do
          String key_column, null: false, primary_key: true
          File value_column
        end
      end

      # @api private
      class MySQL < Sequel
        def store(key, value, options = {})
          @table.
            on_duplicate_key_update(value_column => ::Sequel[:values].function(value_column)).
            insert(key_column => key, value_column => blob(value))
          value
        end

        def increment(key, amount = 1, options = {})
          @backend.transaction do
            if existing = load(key)
              Integer(existing)
            end
            @table.
              on_duplicate_key_update(
                value_column => ::Sequel.+(value_column, ::Sequel[:values].function(value_column))).
              insert(key_column => key, value_column => amount)
            load(key).to_i
          end
        rescue ::Sequel::SerializationFailure # Thrown on deadlock
          tries ||= 0
          (tries += 1) <= 3 ? retry : raise
        end
      end

      # @api private
      class Postgres < Sequel
        def store(key, value, options = {})
          @table.
            insert_conflict(
              target: key_column,
              update: {value_column => ::Sequel[:excluded][value_column]}).
            insert(key_column => key, value_column => blob(value))
          value
        end

        def increment(key, amount = 1, options = {})
          update_expr = ::Sequel[:convert_to].function(
            (::Sequel[:convert_from].function(
              ::Sequel[@table_name][value_column],
              'UTF8').cast(Integer) + amount).cast(String),
            'UTF8')

          if row = @table.
            returning(value_column).
            insert_conflict(target: key_column, update: {value_column => update_expr}).
            insert(key_column => key, value_column => blob(amount.to_s)).
            first
          then
            row[value_column].to_i
          end
        end

        def delete(key, options = {})
          if row = @table.returning(value_column).where(key_column => key).delete.first
            row[value_column]
          end
        end
      end

      # @api private
      class PostgresHStore < Sequel
        def initialize(options, backend)
          @row = options.delete(:hstore).to_s
          backend.extension :pg_hstore
          ::Sequel.extension :pg_hstore_ops
          super
        end

        def key?(key, options = {})
          !!@table.where(key_column => @row).get(::Sequel[value_column].hstore.key?(key))
        end

        def store(key, value, options = {})
          create_row
          @table.
            where(key_column => @row).
            update(value_column => ::Sequel[@table_name][value_column].hstore.merge(key => value))
          value
        end

        def load(key, options = {})
          @table.where(key_column => @row).get(::Sequel[value_column].hstore[key])
        end

        def delete(key, options = {})
          value = load(key, options)
          @table.where(key_column => @row).update(value_column => ::Sequel[value_column].hstore.delete(key))
          value
        end

        def increment(key, amount = 1, options = {})
          create_row
          pair = ::Sequel[:hstore].function(
            key,
            (::Sequel[:coalesce].function(
              ::Sequel[value_column].hstore[key].cast(Integer),
              0) + amount).cast(String))

          if row = @table.
            returning(::Sequel[value_column].hstore[key].as(:value)).
            where(key_column => @row).
            update(value_column => ::Sequel.join([value_column, pair])).
            first
          then
            row[:value].to_i
          end
        end

        def create(key, value, options = {})
          create_row
          1 == @table.
            where(key_column => @row).
            exclude(::Sequel[value_column].hstore.key?(key)).
            update(value_column => ::Sequel[value_column].hstore.merge(key => value))
        end

        def clear(options = {})
          @table.where(key_column => @row).update(value_column => '')
          self
        end

        protected

        def create_row
          @table.
            insert_ignore.
            insert(key_column => @row, value_column => '')
        end

        def create_table
          key_column = self.key_column
          value_column = self.value_column

          @backend.create_table?(@table_name) do
            column key_column, String, null: false, primary_key: true
            column value_column, :hstore
            index value_column, type: :gin
          end
        end
      end

      # @api private
      class SQLite < Sequel
        def store(key, value, options = {})
          @table.insert_conflict(:replace).insert(key_column => key, value_column => blob(value))
          value
        end
      end
    end
  end
end
