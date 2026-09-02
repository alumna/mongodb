require "../spec_helper"

describe Alumna::MongoAdapter::Identity do
  hex = BSON::ObjectId.new.to_s

  it "validates 24 hex chars and rejects AdapterSuite-style ids" do
    Alumna::MongoAdapter::Identity.valid?(hex).should be_true
    Alumna::MongoAdapter::Identity.valid?("99").should be_false
    Alumna::MongoAdapter::Identity.valid?("zzzzzzzzzzzzzzzzzzzzzzzz").should be_false
  end

  it "parse? returns nil on a short id and ObjectId on hex" do
    Alumna::MongoAdapter::Identity.parse?("99").should be_nil
    oid = Alumna::MongoAdapter::Identity.parse?(hex)
    oid.should be_a(BSON::ObjectId)
    if oid.is_a?(BSON::ObjectId)
      Alumna::MongoAdapter::Identity.hex(oid).should eq(hex)
      filter = Alumna::MongoAdapter::Identity.filter(oid)
      filter["_id"].should eq(oid)
    end
  end
end
