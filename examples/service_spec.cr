require "spec"
require "./support"

# One example of a spec that calls the adapter.
# Run this file alone. `crystal spec` without a path only reads spec/.
#
#   crystal spec examples/service_spec.cr

describe "MongoAdapter service spec" do
  it "returns a 24-character hex id and drops id from the stored document" do
    products = Alumna.mongo(
      Examples.client,
      Examples::DB,
      "spec_products",
      Alumna::Schema.new.str("title").float("price"),
    )
    created = products.create(Examples.ctx(
      products,
      Alumna::ServiceMethod::Create,
      data: Alumna.hash(title: "Laptop", price: 10.5),
    ))
    created.should be_a(Hash(String, Alumna::AnyData))
    id = created.as(Hash)["id"].as(String)
    id.bytesize.should eq(24)

    got = products.get(Examples.ctx(products, Alumna::ServiceMethod::Get, id: id))
    got.should be_a(Hash(String, Alumna::AnyData))
    got.as(Hash).has_key?("_id").should be_false
    got.as(Hash)["title"].should eq("Laptop")
  end
end
