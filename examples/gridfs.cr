require "./support"

# GridFS works on a standalone server. File ids are ObjectId hex strings.
# open_upload_stream uploads on a background fiber. close waits and re-raises.
# download writes the bytes and also returns the file document.

Holder = Alumna::Schema.new.str("title", required: false)
products = Alumna.mongo(Examples.client, Examples::DB, "products", Holder)
gridfs = products.grid_fs(bucket_name: "fs", chunk_size_bytes: 255 * 1024)

upload = gridfs.open_upload_stream("file.txt", metadata: Alumna.hash(author: "Ada"))
upload.io << "some bytes"
upload.close
raise "id" unless upload.id.bytesize == 24

dest = IO::Memory.new
file = gridfs.download_to_stream(upload.id, dest)
dest.rewind
raise "bytes" unless dest.gets_to_end == "some bytes"
raise "filename" unless file["filename"] == "file.txt"
raise "metadata" unless file["metadata"].as(Hash)["author"] == "Ada"

notes = gridfs.upload_from_stream("notes.txt", IO::Memory.new("hello"))
raise "upload_from_stream" unless notes["filename"] == "notes.txt"

by_name = IO::Memory.new
named = gridfs.download_to_stream_by_name("file.txt", by_name, -1)
by_name.rewind
raise "revision -1 is the newest" unless by_name.gets_to_end == "some bytes" && named["id"] == upload.id

gridfs.rename(upload.id, "renamed.txt")
gridfs.rename_by_name("notes.txt", "notes-2.txt")
renamed = gridfs.download_to_stream_by_name("renamed.txt", IO::Memory.new, 0)
raise "rename" unless renamed["filename"] == "renamed.txt"

gridfs.delete(upload.id)
begin
  gridfs.delete(upload.id)
  raise "second delete should be 404"
rescue ex : Alumna::MongoAdapter::GridFSError
  raise "status" unless ex.status == 404
end

begin
  gridfs.download_to_stream("not-hex", IO::Memory.new)
  raise "bad hex should be 404"
rescue ex : Alumna::MongoAdapter::GridFSError
  raise "status" unless ex.status == 404
end

gridfs.delete_by_name("notes-2.txt")
puts "gridfs ok"
