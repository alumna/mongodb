require "../spec_helper"

describe Alumna::MongoAdapter::Errors do
  it "maps duplicate key 11000 to 422 with the schema path when the index name is known" do
    name = "wave4_dup"
    schema = Alumna::Schema.new(strict: false)
      .str("email", unique: true)
      .str("name", required: false)
    adapter = mongo_adapter(name, schema)
    adapter.create_indexes!

    first = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(email: "a@test.com", name: "Ada"))))
    dup = as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(email: "a@test.com", name: "Bob"))))
    dup.status.should eq(422)
    dup.details["email"].should eq("already exists")

    second = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(email: "b@test.com", name: "Cara"))))
    patch_dup = as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: second["id"].as(String), data: Alumna.hash(email: "a@test.com"))))
    patch_dup.status.should eq(422)
    patch_dup.details["email"].should eq("already exists")

    update_dup = as_error(adapter.update(ctx(adapter, Alumna::ServiceMethod::Update, id: second["id"].as(String), data: Alumna.hash(email: "a@test.com"))))
    update_dup.status.should eq(422)
    update_dup.details["email"].should eq("already exists")

    oid = BSON::ObjectId.new
    mongo_coll(name).insert_one(BSON.build { |b|
      b["_id"] = oid
      b["email"] = "c@test.com"
    })
    begin
      mongo_coll(name).insert_one(BSON.build { |b|
        b["_id"] = oid
        b["email"] = "d@test.com"
      })
    rescue ex : Mongo::Error
      mapped = Alumna::MongoAdapter::Errors.from_mongo(ex)
      mapped.status.should eq(422)
      mapped.details["error"].should eq("already exists")
    end

    first["email"].should eq("a@test.com")

    constructed = Mongo::Error::Command.new(11000, "DuplicateKey", "E11000 duplicate key", nil)
    generic = Alumna::MongoAdapter::Errors.from_mongo(constructed)
    generic.status.should eq(422)
    generic.details["error"].should eq("already exists")
  end

  it "reads the index name from Command and CommandWrite messages" do
    map = {"uniq_c_email" => "email"} of String => String
    named = "E11000 duplicate key error collection: db.c index: uniq_c_email dup key: { email: \"a\" }"

    cmd = Mongo::Error::Command.new(11000, "DuplicateKey", named, nil)
    from_cmd = Alumna::MongoAdapter::Errors.from_mongo(cmd, map)
    from_cmd.status.should eq(422)
    from_cmd.details["email"].should eq("already exists")

    write_named = BSON.build do |b|
      b["0"] = BSON.build do |e|
        e["code"] = 11000_i32
        e["codeName"] = "DuplicateKey"
        e["errmsg"] = named
      end
    end
    from_write = Alumna::MongoAdapter::Errors.from_mongo(Mongo::Error::CommandWrite.new(write_named), map)
    from_write.details["email"].should eq("already exists")

    unknown = Mongo::Error::Command.new(11000, "DuplicateKey", named.gsub("uniq_c_email", "email_1"), nil)
    Alumna::MongoAdapter::Errors.from_mongo(unknown, map).details["error"].should eq("already exists")

    empty_name = Mongo::Error::Command.new(11000, "DuplicateKey", "E11000 x index:  dup key: { a: 1 }", nil)
    Alumna::MongoAdapter::Errors.from_mongo(empty_name, map).details["error"].should eq("already exists")

    trailing = Mongo::Error::Command.new(11000, "DuplicateKey", "E11000 x index: ", nil)
    Alumna::MongoAdapter::Errors.from_mongo(trailing, map).details["error"].should eq("already exists")

    no_dup = Mongo::Error::Command.new(11000, "DuplicateKey", "E11000 x index: uniq_c_email", nil)
    Alumna::MongoAdapter::Errors.from_mongo(no_dup, map).details["email"].should eq("already exists")

    empty_write = BSON.build do |b|
      b["0"] = BSON.build do |e|
        e["code"] = 11000_i32
        e["errmsg"] = ""
      end
    end
    Alumna::MongoAdapter::Errors.from_mongo(Mongo::Error::CommandWrite.new(empty_write), map).details["error"].should eq("already exists")

    no_errors = Alumna::MongoAdapter::Errors.from_mongo(Mongo::Error::CommandWrite.new(BSON.new), map)
    no_errors.status.should eq(500)
  end

  it "maps generic Mongo errors to 500 and strips URI userinfo" do
    cmd = Mongo::Error::Command.new(1, "InternalError", "boom mongodb://u:secret@127.0.0.1:27017/db", nil)
    mapped_cmd = Alumna::MongoAdapter::Errors.from_mongo(cmd)
    mapped_cmd.status.should eq(500)
    mapped_cmd.message.includes?("secret").should be_false
    mapped_cmd.message.includes?("mongodb://127.0.0.1:27017/db").should be_true

    net = Mongo::Error::Network.new("failed mongodb://user:pass@host/db")
    mapped_net = Alumna::MongoAdapter::Errors.from_mongo(net)
    mapped_net.status.should eq(500)
    mapped_net.message.includes?("pass").should be_false

    empty = Alumna::MongoAdapter::Errors.from_mongo(Mongo::Error.new(""))
    empty.status.should eq(500)
    empty.message.should eq("MongoDB error")

    generic = Alumna::MongoAdapter::Errors.from_mongo(Exception.new("nope"))
    generic.status.should eq(500)
    generic.message.should eq("Internal server error")

    other_write = BSON.build do |b|
      b["0"] = BSON.build do |e|
        e["code"] = 2_i32
        e["codeName"] = "BadValue"
        e["errmsg"] = "nope"
      end
    end
    write_err = Mongo::Error::CommandWrite.new(other_write)
    Alumna::MongoAdapter::Errors.from_mongo(write_err).status.should eq(500)
  end

  it "returns 500 when the client is closed" do
    client = Mongo::Client.new(MONGODB_URI)
    adapter = Alumna::MongoAdapter.new(client, TEST_DB, "wave4_closed", sample_schema)
    client.close
    oid = BSON::ObjectId.new.to_s

    as_error(adapter.find(ctx(adapter, Alumna::ServiceMethod::Find))).status.should eq(500)
    as_error(adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: oid))).status.should eq(500)
    as_error(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "x")))).status.should eq(500)
    as_error(adapter.update(ctx(adapter, Alumna::ServiceMethod::Update, id: oid, data: Alumna.hash(name: "x")))).status.should eq(500)
    as_error(adapter.patch(ctx(adapter, Alumna::ServiceMethod::Patch, id: oid, data: Alumna.hash(name: "x")))).status.should eq(500)
    as_error(adapter.remove(ctx(adapter, Alumna::ServiceMethod::Remove, id: oid))).status.should eq(500)
  end
end
