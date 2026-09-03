class Alumna::MongoAdapter
  # Errors raised by GridFS adapter helpers.
  #
  # This is an opt-in wrapper around cryomongo's GridFS API. It uses HTTP
  # status codes so callers can map 404 for "missing file" without treating
  # it like a 500.
  class GridFSError < Exception
    getter status : Int32

    def initialize(@status : Int32, message : String)
      super(message)
    end

    def self.not_found(message : String = "GridFS file not found") : GridFSError
      new(404, message)
    end
  end

  # Wrapper around a configured GridFS bucket for this adapter.
  #
  # GridFS works on standalone MongoDB servers (no replica set required).
  class GridFS
    DEFAULT_FIND_TIMEOUT_MS = 10_000_i64

    class UploadStream
      getter id : String
      getter io : IO

      def initialize(@id : String, @io : IO)
      end

      def close : Nil
        @io.close
      end
    end

    def initialize(@bucket : Mongo::GridFS::Bucket, @files : Mongo::Collection, @find_timeout_ms : Int64?)
    end

    # Opens an upload stream. The returned stream uses a background fiber in
    # the driver and must be closed so upload errors re-raise.
    def open_upload_stream(
      filename : String,
      *,
      id : String? = nil,
      metadata : Hash(String, AnyData)? = nil,
      chunk_size_bytes : Int32? = nil,
      timeout_ms : Int64? = nil,
    ) : UploadStream
      oid = parse_file_id!(id)
      io = @bucket.open_upload_stream(
        filename,
        id: oid,
        chunk_size_bytes: chunk_size_bytes,
        metadata: metadata,
        timeout_ms: timeout_ms,
      )
      UploadStream.new(Identity.hex(oid), io)
    end

    # Uploads a file from an IO stream and returns the stored file document.
    def upload_from_stream(
      filename : String,
      stream : IO,
      *,
      id : String? = nil,
      metadata : Hash(String, AnyData)? = nil,
      chunk_size_bytes : Int32? = nil,
      timeout_ms : Int64? = nil,
    ) : Hash(String, AnyData)
      oid = parse_file_id!(id)
      @bucket.upload_from_stream(
        filename,
        stream,
        id: oid,
        chunk_size_bytes: chunk_size_bytes,
        metadata: metadata,
        timeout_ms: timeout_ms,
      )
      file_document_by_oid!(oid)
    rescue ex : Mongo::Error
      raise gridfs_mongo_error(ex)
    end

    # Downloads the stored file by id into *destination* and returns the file document.
    def download_to_stream(id : String, destination : IO, *, timeout_ms : Int64? = nil) : Hash(String, AnyData)
      oid = parse_file_id!(id)
      @bucket.download_to_stream(oid, destination, timeout_ms: timeout_ms)
      file_document_by_oid!(oid)
    rescue ex : Mongo::Error
      raise gridfs_mongo_error(ex)
    end

    # Downloads the stored file by filename into *destination* and returns the file document.
    def download_to_stream_by_name(
      filename : String,
      destination : IO,
      revision : Int32 = -1,
      *,
      timeout_ms : Int64? = nil,
    ) : Hash(String, AnyData)
      @bucket.download_to_stream_by_name(filename, destination, revision, timeout_ms: timeout_ms)
      file_document_by_name!(filename, revision)
    rescue ex : Mongo::Error
      raise gridfs_mongo_error(ex)
    end

    # Deletes the stored file by id.
    def delete(id : String, *, timeout_ms : Int64? = nil) : Nil
      oid = parse_file_id!(id)
      @bucket.delete(oid, timeout_ms: timeout_ms)
      nil
    rescue ex : Mongo::Error
      raise gridfs_mongo_error(ex)
    end

    # Deletes every stored file whose filename matches.
    def delete_by_name(filename : String, *, timeout_ms : Int64? = nil) : Nil
      @bucket.delete_by_name(filename, timeout_ms: timeout_ms)
      nil
    rescue ex : Mongo::Error
      raise gridfs_mongo_error(ex)
    end

    # Renames a stored file by id.
    def rename(id : String, new_filename : String, *, timeout_ms : Int64? = nil) : Nil
      oid = parse_file_id!(id)
      @bucket.rename(oid, new_filename, timeout_ms: timeout_ms)
      nil
    rescue ex : Mongo::Error
      raise gridfs_mongo_error(ex)
    end

    # Renames every stored file whose filename matches.
    def rename_by_name(filename : String, new_filename : String, *, timeout_ms : Int64? = nil) : Nil
      @bucket.rename_by_name(filename, new_filename, timeout_ms: timeout_ms)
      nil
    rescue ex : Mongo::Error
      raise gridfs_mongo_error(ex)
    end

    private def parse_file_id!(id : String?) : BSON::ObjectId
      return BSON::ObjectId.new if id.nil? # id is only used for open_upload_stream.

      # GridFS file IDs are ObjectId hex strings (D3/D5). Invalid hex is 404, not 500.
      return BSON::ObjectId.new(id) if Identity.valid?(id)

      raise GridFSError.not_found("Invalid GridFS file id")
    end

    private def gridfs_mongo_error(ex : Mongo::Error) : GridFSError
      msg = ex.message || ""
      return GridFSError.not_found if gridfs_not_found_message?(msg)
      GridFSError.new(500, Errors.safe_message(ex))
    end

    private def gridfs_not_found_message?(msg : String) : Bool
      msg.includes?("File not found") || msg.includes?("Cannot find file") || msg.includes?("Cannot find revision")
    end

    private def file_document_by_oid!(oid : BSON::ObjectId) : Hash(String, AnyData)
      doc = @files.find_one({_id: oid}, timeout_ms: find_timeout_ms)
      raise GridFSError.not_found if doc.nil?
      file_to_record(doc)
    end

    private def file_document_by_name!(filename : String, revision : Int32) : Hash(String, AnyData)
      sort_order = revision >= 0 ? 1 : -1
      skip = revision >= 0 ? revision : -revision - 1

      doc = @files.find_one(
        {filename: filename},
        sort: {uploadDate: sort_order},
        skip: skip,
        timeout_ms: find_timeout_ms,
      )
      raise GridFSError.not_found if doc.nil?
      file_to_record(doc)
    end

    private def file_to_record(bson : BSON) : Hash(String, AnyData)
      # Walk BSON, not to_h and not a BSON::Serializable → Hash conversion.
      record = Hash(String, AnyData).new(initial_capacity: bson.size + 1)
      bson.each do |key, value, code, subtype|
        if key == "_id"
          record["id"] = BsonRead.to_any(value, code, subtype)
        else
          record[key] = BsonRead.to_any(value, code, subtype)
        end
      end
      record
    end

    private def find_timeout_ms : Int64?
      @find_timeout_ms || DEFAULT_FIND_TIMEOUT_MS
    end
  end

  # Configure a GridFS bucket helper for this adapter.
  #
  # * bucket_name defaults to "fs"
  # * chunk_size_bytes uses the cryomongo default when nil
  def grid_fs(bucket_name : String = "fs", chunk_size_bytes : Int32? = nil) : GridFS
    chunk = chunk_size_bytes || (255 * 1024)
    db = @client[@database]
    bucket = db.grid_fs(
      bucket_name: bucket_name,
      chunk_size_bytes: chunk,
    )
    files = db["#{bucket_name}.files"]
    timeout_ms = @client.options.timeout.try(&.total_milliseconds.to_i64)
    GridFS.new(bucket, files, timeout_ms)
  end
end

