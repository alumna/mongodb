require "../spec_helper"

describe "Alumna.mongo" do
  it "builds an adapter without a block" do
    drop_collection("wave4_factory")
    svc = Alumna.mongo(SHARED_CLIENT, TEST_DB, "wave4_factory", sample_schema)
    svc.should be_a(Alumna::MongoAdapter)
    created = as_hash(svc.create(ctx(svc, Alumna::ServiceMethod::Create, data: Alumna.hash(name: "Ada"))))
    created["name"].should eq("Ada")
  end

  it "builds an adapter with a block and optional max_limit" do
    drop_collection("wave4_factory_block")
    indexed = false
    svc = Alumna.mongo(SHARED_CLIENT, TEST_DB, "wave4_factory_block", sample_schema, max_limit: 2) do
      create_indexes!
      indexed = true
    end
    indexed.should be_true
    svc.should be_a(Alumna::MongoAdapter)
    svc.create_indexes!
    Alumna::MongoAdapter::Indexes.create!(mongo_coll("wave4_factory_block"), [] of BSON)
  end

  it "raises ArgumentError when schema is nil" do
    expect_raises(ArgumentError, "MongoAdapter requires a Schema") do
      Alumna.mongo(SHARED_CLIENT, TEST_DB, "wave4_factory_nil", nil)
    end
    expect_raises(ArgumentError, "MongoAdapter requires a Schema") do
      Alumna.mongo(SHARED_CLIENT, TEST_DB, "wave4_factory_nil_block", nil) { }
    end
    expect_raises(ArgumentError, "MongoAdapter requires a Schema") do
      Alumna::MongoAdapter.new(SHARED_CLIENT, TEST_DB, "wave4_factory_nil_ctor", nil)
    end
  end
end
