require "../spec_helper"

private def extra_types_document(oid : BSON::ObjectId) : BSON
  nested = BSON.build do |n|
    n["min"] = BSON::MinKey.new
    n["max"] = BSON::MaxKey.new
  end
  arr = BSON.build do |a|
    a["0"] = 3_i32
    a["1"] = BSON::Undefined.new
  end
  BSON.build do |b|
    b["_id"] = oid
    b["i32"] = 7_i32
    b["oid"] = BSON::ObjectId.new("aaaaaaaaaaaaaaaaaaaaaaaa")
    b["uuid"] = UUID.new("550e8400-e29b-41d4-a716-446655440000")
    b["dec"] = BSON::Decimal128.new("1.25")
    b["rx"] = BSON::Regex.new("foo", "i")
    b["min"] = BSON::MinKey.new
    b["max"] = BSON::MaxKey.new
    b["undef"] = BSON::Undefined.new
    b["ts"] = BSON::Timestamp.new(9_u32, 4_u32)
    b["js"] = BSON::Code.new("function(){}")
    b["js_scope"] = BSON::Code.new("return 1", BSON.build { |s| s["a"] = 1_i32 })
    b["sym"] = BSON::Symbol.new("sym")
    b["ptr"] = BSON::DBPointer.new("other", BSON::ObjectId.new("bbbbbbbbbbbbbbbbbbbbbbbb"))
    b["nested"] = nested
    b.append_array("arr", arr)
    b["late"] = BSON::DateTime.new(BSON::DateTime::MAX_TIME_MS + 1)
  end
end

describe "BSON write and read" do
  it "round-trips AnyData types through create and get" do
    adapter = mongo_adapter("wave4_bson_roundtrip")
    created_at = Time.utc(2026, 9, 1, 12, 0, 0)
    blob = Bytes[1, 2, 3, 4]
    big = Array(Alumna::AnyData).new(129) { |i| i.to_s }
    payload = {
      "id"      => "99".as(Alumna::AnyData),
      "_id"     => "nope".as(Alumna::AnyData),
      "name"    => "Ada".as(Alumna::AnyData),
      "age"     => 42_i64.as(Alumna::AnyData),
      "score"   => 1.5.as(Alumna::AnyData),
      "active"  => true.as(Alumna::AnyData),
      "created" => created_at.as(Alumna::AnyData),
      "blob"    => blob.as(Alumna::AnyData),
      "user"    => ({"name" => "Lovelace".as(Alumna::AnyData)} of String => Alumna::AnyData).as(Alumna::AnyData),
      "tags"    => ["math".as(Alumna::AnyData), "code".as(Alumna::AnyData)].as(Alumna::AnyData),
      "n"       => nil.as(Alumna::AnyData),
      "extra"   => big.as(Alumna::AnyData),
      "meta"    => ({
        "ok"    => false.as(Alumna::AnyData),
        "zero"  => 0.0.as(Alumna::AnyData),
        "empty" => ([] of Alumna::AnyData).as(Alumna::AnyData),
        "kid"   => ({} of String => Alumna::AnyData).as(Alumna::AnyData),
        "list"  => [
          ({"n" => "x".as(Alumna::AnyData)} of String => Alumna::AnyData).as(Alumna::AnyData),
        ].as(Alumna::AnyData),
      } of String => Alumna::AnyData).as(Alumna::AnyData),
    } of String => Alumna::AnyData

    created = as_hash(adapter.create(ctx(adapter, Alumna::ServiceMethod::Create, data: payload)))
    id = created["id"].as(String)
    id.size.should eq(24)
    id.should_not eq("99")
    created.has_key?("_id").should be_false
    created.has_key?("id").should be_true

    got = adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: id))
    got.should be_a(Hash(String, Alumna::AnyData))
    if got.is_a?(Hash(String, Alumna::AnyData))
      got["name"].should eq("Ada")
      got["age"].should eq(42_i64)
      got["age"].should be_a(Int64)
      got["score"].should eq(1.5)
      got["active"].should eq(true)
      got["created"].should eq(created_at)
      got["blob"].should eq(blob)
      got["n"].should be_nil
      user = got["user"].as(Hash(String, Alumna::AnyData))
      user["name"].should eq("Lovelace")
      tags = got["tags"].as(Array(Alumna::AnyData))
      tags.size.should eq(2)
      extra = got["extra"].as(Array(Alumna::AnyData))
      extra.size.should eq(129)
      meta = got["meta"].as(Hash(String, Alumna::AnyData))
      meta["ok"].should eq(false)
      meta["zero"].should eq(0.0)
    end
  end

  it "reads extra BSON types from a collection insert" do
    name = "wave4_bson_extra"
    adapter = mongo_adapter(name)
    oid = BSON::ObjectId.new
    mongo_coll(name).insert_one(extra_types_document(oid))

    got = adapter.get(ctx(adapter, Alumna::ServiceMethod::Get, id: oid.to_s))
    got.should be_a(Hash(String, Alumna::AnyData))
    if got.is_a?(Hash(String, Alumna::AnyData))
      got["id"].should eq(oid.to_s)
      got["i32"].should eq(7_i64)
      got["oid"].should eq("aaaaaaaaaaaaaaaaaaaaaaaa")
      got["uuid"].should be_a(String)
      got["dec"].should be_a(String)
      got["rx"].should eq("foo")
      got["min"].should eq("$minKey")
      got["max"].should eq("$maxKey")
      got["undef"].should eq("$undefined")
      got["ts"].should eq("9:4")
      got["js"].should eq("function(){}")
      got["js_scope"].should eq("return 1")
      got["sym"].should eq("sym")
      got["ptr"].should eq("other:bbbbbbbbbbbbbbbbbbbbbbbb")
      got["late"].should be_nil
      nested = got["nested"].as(Hash(String, Alumna::AnyData))
      nested["min"].should eq("$minKey")
      arr = got["arr"].as(Array(Alumna::AnyData))
      arr[0].should eq(3_i64)
      arr[1].should eq("$undefined")
    end
  end

  it "walks a local BSON document for types the decoder yields as Time or non-ObjectId _id" do
    t = Time.utc(2026, 1, 2, 3, 4, 5)
    Alumna::MongoAdapter::BsonRead.to_any(t, BSON::Element::DateTime, nil).should eq(t)
    Alumna::MongoAdapter::BsonRead.to_any(nil, BSON::Element::Null, nil).should be_nil
    Alumna::MongoAdapter::BsonRead.to_any(false, BSON::Element::Boolean, nil).should eq(false)
    Alumna::MongoAdapter::BsonRead.to_any(8_i32, BSON::Element::Int32, nil).should eq(8_i64)
    Alumna::MongoAdapter::BsonRead.to_any(9_i64, BSON::Element::Int64, nil).should eq(9_i64)
    Alumna::MongoAdapter::BsonRead.to_any(2.5, BSON::Element::Double, nil).should eq(2.5)
    Alumna::MongoAdapter::BsonRead.to_any("s", BSON::Element::String, nil).should eq("s")

    bytes = Bytes[9, 8, 7]
    copied = Alumna::MongoAdapter::BsonRead.to_any(bytes, BSON::Element::Binary, BSON::Binary::SubType::Generic)
    copied.should eq(bytes)

    raw = BSON.build do |b|
      b["_id"] = "not-object-id"
      b["k"] = "v"
    end
    rec = Alumna::MongoAdapter::BsonRead.to_record(raw, 1)
    rec["id"].should eq("not-object-id")
    rec["k"].should eq("v")
  end
end
