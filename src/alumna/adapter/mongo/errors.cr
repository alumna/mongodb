class Alumna::MongoAdapter
  # Mongo errors → ServiceError. Duplicate key 11000 uses the index-name map when the server names the index.
  module Errors
    DUPLICATE_KEY     = 11000
    GENERIC_KEY       = "error"
    ALREADY_EXISTS    = "already exists".as(AnyData)
    EMPTY_INDEX_NAMES = {} of String => String
    INDEX_MARK        = " index: "
    DUP_MARK          = " dup key"

    def self.from_mongo(ex : Exception, index_names : Hash(String, String) = EMPTY_INDEX_NAMES) : ServiceError
      if duplicate_key?(ex)
        key = path_for(ex, index_names)
        ServiceError.unprocessable("Unique constraint violation", {key => ALREADY_EXISTS})
      elsif ex.is_a?(Mongo::Error)
        ServiceError.internal(safe_message(ex))
      else
        ServiceError.internal("Internal server error")
      end
    end

    private def self.duplicate_key?(ex : Exception) : Bool
      case ex
      when Mongo::Error::Command
        ex.code == DUPLICATE_KEY
      when Mongo::Error::CommandWrite
        ex.code == DUPLICATE_KEY
      else
        false
      end
    end

    private def self.path_for(ex : Exception, index_names : Hash(String, String)) : String
      name = index_name_from(errmsg(ex))
      return GENERIC_KEY unless name
      index_names[name]? || GENERIC_KEY
    end

    private def self.errmsg(ex : Exception) : String
      case ex
      when Mongo::Error::CommandWrite
        first = ex.errors.first?
        first ? first.message : ""
      else
        ex.message || ""
      end
    end

    # MongoDB 8: "E11000 duplicate key error collection: db.coll index: NAME dup key: { ... }"
    private def self.index_name_from(msg : String) : String?
      start = msg.index(INDEX_MARK)
      return nil unless start
      from = start + INDEX_MARK.size
      return nil if from >= msg.size
      stop = msg.index(DUP_MARK, from) || msg.size
      name = msg[from...stop].rstrip
      name.empty? ? nil : name
    end

    private def self.safe_message(ex : Exception) : String
      msg = ex.message
      return "MongoDB error" unless msg && !msg.empty?
      # Strip URI userinfo so a password in a connection error never leaves the adapter.
      msg.gsub(/\/\/[^\/\s]*@/, "//")
    end
  end
end
