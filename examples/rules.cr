require "json"
require "./support"

# Alumna::Testing.run_rule runs one rule and stops. It does not call the adapter.
# Mounting the rule on the service runs it in the pipeline, before the adapter,
# which is what AppClient exercises below.

Catalog = Alumna::Schema.new
  .str("title", min_length: 2)
  .float("price")

positive_price = Alumna::Rule.new do |ctx|
  price = ctx.data["price"]?
  negative = case price
             when Int64   then price <= 0
             when Float64 then price <= 0
             else              false
             end
  negative ? Alumna::ServiceError.bad_request("price must be positive") : nil
end

checked = Alumna::Testing.run_rule(
  Alumna.validate(Catalog),
  method: Alumna::ServiceMethod::Create,
  data: Alumna.hash(title: "x", price: 10.5),
)
raise "short title" unless checked.error.try(&.status) == 422

rejected = Alumna::Testing.run_rule(
  positive_price,
  method: Alumna::ServiceMethod::Create,
  data: Alumna.hash(title: "Laptop", price: 0.0),
)
raise "zero price" unless rejected.error.try(&.status) == 400
raise "run_rule does not write" if rejected.ctx.result

products = Alumna.mongo(Examples.client, Examples::DB, "products", Catalog) do
  before Alumna.validate(Catalog), on: :write
  before positive_price, on: :create
end
http = Alumna::Testing::AppClient.new(Alumna::App.new.use("/products", products))
headers = {"Content-Type" => "application/json"}

ok = http.post("/products", %({"title":"Laptop","price":10.5}), headers)
raise "mounted create #{ok.status} #{ok.body}" unless ok.status == 201

zero = http.post("/products", %({"title":"Laptop","price":0.0}), headers)
raise "mounted rule" unless zero.status == 400 && zero.json_hash["error"] == "price must be positive"

short = http.post("/products", %({"title":"x","price":10.5}), headers)
raise "mounted validate" unless short.status == 422

puts "rules ok"
