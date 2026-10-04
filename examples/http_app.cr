require "json"
require "./support"

# AppClient sends the request through the router in memory.
# Nothing listens on a port. JSON numbers without a fraction arrive as Int64,
# so a float field is written as 10.5, not 10.

# required_on: :create. A patch sends only the fields that change.
# validate on :write would reject that patch if title were required on every write.
Catalog = Alumna::Schema.new
  .str("title", min_length: 2, required_on: :create)
  .float("price", required_on: :create)

products = Alumna.mongo(Examples.client, Examples::DB, "products", Catalog) do
  before Alumna.validate(Catalog), on: :write
end

app = Alumna::App.new
app.use("/products", products)
http = Alumna::Testing::AppClient.new(app)
headers = {"Content-Type" => "application/json"}

created = http.post("/products", %({"title":"Laptop","price":10.5}), headers)
raise "create #{created.status} #{created.body}" unless created.status == 201
id = created.json_hash["id"].as(String)

one = http.get("/products/#{id}")
raise "get" unless one.status == 200 && one.json_hash["title"] == "Laptop"

listed = http.get("/products?price[$gt]=5&$sort=price:-1")
raise "find" unless listed.status == 200 && listed.json_array.size == 1

patched = http.patch("/products/#{id}", %({"price":8.5}), headers)
raise "patch #{patched.status} #{patched.body}" unless patched.status == 200 && patched.json_hash["price"] == 8.5

removed = http.delete("/products/#{id}")
raise "delete" unless removed.status == 204

missing = http.get("/products/#{id}")
raise "gone" unless missing.status == 404

invalid = http.post("/products", %({"title":"x","price":10.5}), headers)
raise "validate" unless invalid.status == 422

puts "http_app ok id=#{id}"
