require "../spec_helper"

describe "MongoAdapter gridfs" do
  it "uploads, downloads, renames, and deletes by id" do
    adapter = mongo_adapter("gridfs_by_id")
    gridfs = adapter.grid_fs(bucket_name: "gridfs_by_id", chunk_size_bytes: 8_i32)

    content = "hello gridfs".to_slice
    metadata = Alumna.hash(
      author: "Ada",
      nested: Alumna.hash(tag: "x"),
      bytes: Bytes[1, 2, 3],
    )

    upload = gridfs.open_upload_stream("file.txt", metadata: metadata)
    upload.io.write(content)
    upload.close

    downloaded_dest = IO::Memory.new
    file = gridfs.download_to_stream(upload.id, downloaded_dest)
    downloaded_dest.rewind
    downloaded_dest.gets_to_end.should eq("hello gridfs")

    file["filename"].as(String).should eq("file.txt")
    file["length"].as(Int64).should eq(content.size.to_i64)
    file["chunkSize"].as(Int64).should eq(8_i64)
    file["metadata"].as(Hash(String, Alumna::AnyData))["author"].should eq("Ada")
    file["metadata"].as(Hash(String, Alumna::AnyData))["nested"].as(Hash(String, Alumna::AnyData))["tag"].should eq("x")
    file["metadata"].as(Hash(String, Alumna::AnyData))["bytes"].as(Bytes).should eq(Bytes[1, 2, 3])

    gridfs.rename(upload.id, "renamed.txt")
    renamed_dest = IO::Memory.new
    renamed = gridfs.download_to_stream(upload.id, renamed_dest)
    renamed["filename"].as(String).should eq("renamed.txt")

    gridfs.delete(upload.id)

    # Deleting again raises a 404 from the driver and exercises the delete rescue.
    begin
      gridfs.delete(upload.id)
      raise "expected GridFSError"
    rescue ex : Alumna::MongoAdapter::GridFSError
      ex.status.should eq(404)
    end

    # Renaming a deleted file raises a 404 and exercises the rename rescue.
    begin
      gridfs.rename(upload.id, "again.txt")
      raise "expected GridFSError"
    rescue ex : Alumna::MongoAdapter::GridFSError
      ex.status.should eq(404)
    end

    begin
      gridfs.download_to_stream(upload.id, IO::Memory.new)
      raise "expected GridFSError"
    rescue ex : Alumna::MongoAdapter::GridFSError
      ex.status.should eq(404)
    end
  end

  it "supports a by-name path (rename by name + download by name)" do
    adapter = mongo_adapter("gridfs_by_name")
    gridfs = adapter.grid_fs(bucket_name: "gridfs_by_name")

    metadata = Alumna.hash(owner: "Ada", bytes: Bytes[9, 8, 7])
    upload = gridfs.open_upload_stream("old.txt", metadata: metadata)
    upload.io << "same name path"
    upload.close

    gridfs.rename_by_name("old.txt", "new.txt")

    dest = IO::Memory.new
    file = gridfs.download_to_stream_by_name("new.txt", dest)
    dest.rewind
    dest.gets_to_end.should eq("same name path")
    file["filename"].as(String).should eq("new.txt")
    file["metadata"].as(Hash(String, Alumna::AnyData))["owner"].should eq("Ada")

    gridfs.delete_by_name("new.txt")

    begin
      gridfs.delete_by_name("new.txt")
      raise "expected GridFSError"
    rescue ex : Alumna::MongoAdapter::GridFSError
      ex.status.should eq(404)
    end

    begin
      gridfs.rename_by_name("new.txt", "again_by_name.txt")
      raise "expected GridFSError"
    rescue ex : Alumna::MongoAdapter::GridFSError
      ex.status.should eq(404)
    end

    begin
      gridfs.download_to_stream_by_name("new.txt", IO::Memory.new)
      raise "expected GridFSError"
    rescue ex : Alumna::MongoAdapter::GridFSError
      ex.status.should eq(404)
    end
  end

  it "maps duplicate upload errors to status 500" do
    adapter = mongo_adapter("gridfs_duplicate")
    gridfs = adapter.grid_fs(bucket_name: "gridfs_duplicate")

    file_id = BSON::ObjectId.new.to_s
    dest1 = IO::Memory.new("same_id")
    gridfs.upload_from_stream("dup.txt", dest1, id: file_id, metadata: Alumna.hash(x: 1_i64))

    begin
      dest2 = IO::Memory.new("same_id_2")
      gridfs.upload_from_stream("dup.txt", dest2, id: file_id, metadata: Alumna.hash(x: 2_i64))
      raise "expected GridFSError"
    rescue ex : Alumna::MongoAdapter::GridFSError
      ex.status.should eq(500)
    end
  end

  it "returns a clear 404 on invalid file id hex" do
    adapter = mongo_adapter("gridfs_invalid_hex")
    gridfs = adapter.grid_fs(bucket_name: "gridfs_invalid_hex")

    begin
      gridfs.download_to_stream("not-object-id", IO::Memory.new)
      raise "expected GridFSError"
    rescue ex : Alumna::MongoAdapter::GridFSError
      ex.status.should eq(404)
    end
  end
end

