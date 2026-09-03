require "sync"

class Alumna::MongoAdapter
  # Raised when `#transaction` cannot run (standalone, or nested on this fiber).
  class TransactionError < Exception
  end

  STANDALONE_MESSAGE = "MongoDB transactions need a replica set. Standalone servers cannot run them."
  NESTED_MESSAGE     = "A transaction is already running on this fiber"

  # Fiber → explicit session. preview_mt shares adapters across fibers, so this
  # cannot live in an instance var. The mutex guards only this map (D19).
  @@fiber_sessions = {} of Fiber => Mongo::Session::ClientSession
  @@fiber_sessions_lock = Sync::Mutex.new

  # Run *block* in one MongoDB transaction on this fiber.
  # Commit if the block returns a value. Abort if it raises or returns ServiceError.
  # CRUD methods pick up the session from the fiber map. Do not pass a session in.
  def transaction(& : -> T) : T | ServiceError forall T
    raise TransactionError.new(NESTED_MESSAGE) if lookup_session(Fiber.current)
    return run_transaction { yield } if clustered_topology?
    raise TransactionError.new(STANDALONE_MESSAGE)
  end

  # Session for this adapter's client on the current fiber, or nil.
  private def fiber_session : Mongo::Session::ClientSession?
    session = lookup_session(Fiber.current)
    session if session && session.client == @client
  end

  private def lookup_session(fiber : Fiber) : Mongo::Session::ClientSession?
    @@fiber_sessions_lock.synchronize { @@fiber_sessions[fiber]? }
  end

  # Replica set, sharded, or load-balanced. Standalone (Single) cannot run
  # transactions or change streams. Shared by `#transaction` and `#watch`.
  private def clustered_topology? : Bool
    discover_topology if @client.topology.type.unknown?
    type = @client.topology.type
    type.replica_set_with_primary? || type.replica_set_no_primary? || type.sharded? || type.load_balanced?
  end

  # LCOV_EXCL_START - replica-set only; GitHub CI is standalone mongo:8.0

  private def discover_topology : Nil
    @client.command(Mongo::Commands::Ping)
  rescue Mongo::Error
  end

  # Turns a ServiceError return into an abort inside with_transaction.
  class AbortOnServiceError < Exception
    getter error : ServiceError

    def initialize(@error : ServiceError)
      super("abort transaction")
    end
  end

  private def run_transaction(& : -> T) : T | ServiceError forall T
    session = @client.start_session
    fiber = Fiber.current
    begin
      bind_session(fiber, session)
      finish_transaction(session) { yield }
    ensure
      unbind_session(fiber)
      begin
        session.end
      rescue Mongo::Error
      end
    end
  end

  # with_transaction retries TransientTransactionError. A ServiceError return
  # must abort, so we raise AbortOnServiceError and convert it back after abort.
  private def finish_transaction(session : Mongo::Session::ClientSession, & : -> T) : T | ServiceError forall T
    result = uninitialized T
    begin
      session.with_transaction do
        value = yield
        raise AbortOnServiceError.new(value) if value.is_a?(ServiceError)
        result = value
      end
    rescue ex : AbortOnServiceError
      return ex.error
    rescue ex : Mongo::Error
      raise mongo_transaction_error(ex)
    end
    result
  end

  private def mongo_transaction_error(ex : Mongo::Error) : TransactionError
    msg = Errors.safe_message(ex)
    if standalone_txn_error?(ex, msg)
      TransactionError.new(STANDALONE_MESSAGE)
    else
      TransactionError.new(msg)
    end
  end

  private def standalone_txn_error?(ex : Mongo::Error, msg : String) : Bool
    return true if msg.includes?("Transaction numbers are only allowed")
    return true if ex.is_a?(Mongo::Error::Command) && ex.code == 20
    false
  end

  private def bind_session(fiber : Fiber, session : Mongo::Session::ClientSession) : Nil
    @@fiber_sessions_lock.synchronize do
      prune_dead_sessions
      @@fiber_sessions[fiber] = session
    end
  end

  private def unbind_session(fiber : Fiber) : Nil
    @@fiber_sessions_lock.synchronize { @@fiber_sessions.delete(fiber) }
  end

  private def prune_dead_sessions : Nil
    @@fiber_sessions.reject! do |fiber, session|
      next false unless fiber.dead?
      begin
        session.end
      rescue
      end
      true
    end
  end

  # LCOV_EXCL_STOP
end
