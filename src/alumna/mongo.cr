require "./adapter/mongo"

module Alumna
  # Build a MongoAdapter. Optional block is `with svc yield` so you can mount rules.
  # Records travel AnyData → BSON → cryomongo → BSON → AnyData.

  def self.mongo(
    client : Mongo::Client,
    database : String,
    collection : String,
    schema : Schema?,
    max_limit : Int32? = nil,
  )
    MongoAdapter.new(client, database, collection, schema, max_limit)
  end

  def self.mongo(
    client : Mongo::Client,
    database : String,
    collection : String,
    schema : Schema?,
    max_limit : Int32? = nil,
    &
  )
    svc = MongoAdapter.new(client, database, collection, schema, max_limit)
    with svc yield
    svc
  end
end
