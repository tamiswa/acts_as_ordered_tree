# coding: utf-8

module ActsAsOrderedTree
  class PerseveringTransaction
    module State
      # Generate helper methods for given +state+.
      # AR adapter calls :committed! and :rolledback! methods
      #
      # @api private
      def state_method(state)
        define_method "#{state}!" do |*|
          @state = state
        end

        define_method "#{state}?" do
          @state == state
        end
      end
    end
    extend State

    # Which errors should be treated as deadlocks
    DEADLOCK_MESSAGES = Regexp.new [
      'Deadlock found when trying to get lock',
      'Lock wait timeout exceeded',
      'deadlock detected',
      'database is locked'
    ].join(?|).freeze
    # How many times we should retry transaction
    RETRY_COUNT = 10

    attr_reader :connection, :attempts
    delegate :logger, :to => :connection

    state_method :committed
    state_method :rolledback

    def initialize(connection)
      @connection = connection
      @attempts = 0
      @callbacks = []
      @state = nil
    end

    # Starts persevering transaction
    def start(&block)
      @attempts += 1

      with_transaction_state(&block)
    rescue ActiveRecord::StatementInvalid => error
      raise unless connection.open_transactions.zero?
      raise unless error.message =~ DEADLOCK_MESSAGES
      raise if attempts >= RETRY_COUNT

      logger.info "Deadlock detected on attempt #{attempts}, restarting transaction"

      pause and retry
    end

    # Execute given +block+ when after transaction _real_ commit
    def after_commit(&block)
      @callbacks << block if block_given?
    end

    # This method is called by AR adapter
    # @api private
    def has_transactional_callbacks?
      true
    end
    
    def before_committed!
      # no-op
    end

    # Marks this transaction as committed and executes its commit callbacks
    # @api private
    def committed!
      @callbacks.each { |callback| callback.call }
    end
    self.class.prepend(ActsAsOrderedTree::PerseveringTransaction::State)

    private
    def pause 
      sleep(rand(attempts) * 0.1)
    end

    # Runs real transaction and remembers its state
    def with_transaction_state
      connection.transaction do
        connection.add_transaction_record(self)

        yield
      end
    end
  end # class PerseveringTransaction
end # module ActsAsOrderedTree