class Alumna::MongoAdapter
  # Raised when `#watch` cannot run (standalone), or the driver fails to open
  # or read the stream. Message uses `Errors.safe_message` (no URI password).
  class WatchError < Exception
  end

  WATCH_STANDALONE_MESSAGE = "MongoDB change streams need a replica set. Standalone servers cannot run them."

  # LCOV_EXCL_START - replica-set only; GitHub CI is standalone mongo:8.0

  # Wrapper around a cryomongo change-stream cursor.
  # `#next` waits. `#try_next` polls. The caller must `#close` (or use the
  # block form of `MongoAdapter#watch`, which closes in `ensure`).
  class ChangeStream
    def initialize(@cursor : Mongo::ChangeStream::Cursor, @field_count : Int32)
      @closed = false
    end

    # Wait for the next change. Nil when the cursor is exhausted.
    def next : Hash(String, AnyData)?
      element = @cursor.next
      case element
      when BSON
        decode_event(element)
      else
        nil
      end
    rescue ex : Mongo::Error
      raise WatchError.new(Errors.safe_message(ex))
    end

    # One poll. Nil when this batch is empty and the stream is still open.
    def try_next : Hash(String, AnyData)?
      element = @cursor.try_next
      return nil unless element
      decode_event(element)
    rescue ex : Mongo::Error
      raise WatchError.new(Errors.safe_message(ex))
    end

    # Cloned resume-token BSON bytes. Nil before the driver has a token.
    def resume_token : Bytes?
      token = @cursor.resume_token
      return nil unless token
      token.data.clone
    end

    def close : Nil
      return if @closed
      @closed = true
      @cursor.close
    end

    # Walk the change event once (D6). Event `_id` is the resume token, not a
    # record ObjectId — do not use `to_record` on the event itself. Nested
    # BSON values are views: clone token bytes and copy hashes before return.
    private def decode_event(bson : BSON) : Hash(String, AnyData)
      event = Hash(String, AnyData).new(initial_capacity: 8)
      bson.each do |key, value, code, subtype|
        case key
        when "_id"
          event["resume_token"] = value.data.clone if value.is_a?(BSON)
        when "operationType"
          event["operation_type"] = BsonRead.to_any(value, code, subtype)
        when "documentKey"
          next unless value.is_a?(BSON)
          key_hash = BsonRead.to_record(value, 1)
          event["document_key"] = key_hash
          if id = key_hash["id"]?
            event["document_id"] = id
          end
        when "fullDocument"
          event["full_document"] = BsonRead.to_record(value, @field_count) if value.is_a?(BSON)
        when "ns"
          event["ns"] = BsonRead.to_any(value, code, subtype)
        end
      end
      event
    end
  end

  # LCOV_EXCL_STOP

  # Watch this adapter's collection. Replica set (or mongos / sharded /
  # load-balanced) required. Standalone raises `WatchError`.
  #
  # *resume_after* is cloned BSON bytes of a prior event's `resume_token`
  # (D35). *full_document* is the driver's option (`updateLookup`, …).
  # *max_await_time_ms* bounds each getMore wait.
  #
  # Close the returned stream. Prefer the block form, which closes in `ensure`.
  def watch(
    resume_after : Bytes? = nil,
    max_await_time_ms : Int64? = nil,
    full_document : String? = nil,
  ) : ChangeStream
    return open_watch(resume_after, max_await_time_ms, full_document) if clustered_topology?
    raise WatchError.new(WATCH_STANDALONE_MESSAGE)
  end

  def watch(
    resume_after : Bytes? = nil,
    max_await_time_ms : Int64? = nil,
    full_document : String? = nil,
    & : Hash(String, AnyData) ->
  ) : Nil
    return iterate_watch(resume_after, max_await_time_ms, full_document) { |event| yield event } if clustered_topology?
    raise WatchError.new(WATCH_STANDALONE_MESSAGE)
  end

  # LCOV_EXCL_START - replica-set only; GitHub CI is standalone mongo:8.0

  private def iterate_watch(
    resume_after : Bytes?,
    max_await_time_ms : Int64?,
    full_document : String?,
    & : Hash(String, AnyData) ->
  ) : Nil
    stream = open_watch(resume_after, max_await_time_ms, full_document)
    begin
      loop do
        event = stream.next
        break unless event
        yield event
      end
    ensure
      stream.close
    end
  end

  private def open_watch(
    resume_after : Bytes?,
    max_await_time_ms : Int64?,
    full_document : String?,
  ) : ChangeStream
    token = resume_after.try { |bytes| BSON.new(bytes) }
    cursor = @collection.watch(
      resume_after: token,
      max_await_time_ms: max_await_time_ms,
      full_document: full_document,
    )
    ChangeStream.new(cursor, @field_count)
  rescue ex : BSON::Error
    msg = ex.message
    raise WatchError.new(msg && !msg.empty? ? msg : "Invalid resume token")
  rescue ex : Mongo::Error
    raise WatchError.new(Errors.safe_message(ex))
  end

  # LCOV_EXCL_STOP
end
