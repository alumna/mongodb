require "./support"

# create_indexes! writes unique: true, indexed: true, and schema.index.
# Duplicate key 11000 comes back as ServiceError 422, not a raised Mongo::Error.

UserSchema = Alumna::Schema.new
  .str("email", unique: true)
  .str("role", indexed: true)
  .index(["email", "role"])

users = Alumna.mongo(Examples.client, Examples::DB, "users", UserSchema)
users.create_indexes!

Examples.must(
  users.create(Examples.ctx(users, Alumna::ServiceMethod::Create, data: Alumna.hash(email: "ada@test.com", role: "admin"))),
  "first",
)
duplicate = users.create(Examples.ctx(users, Alumna::ServiceMethod::Create, data: Alumna.hash(email: "ada@test.com", role: "member")))
raise "expected 422" unless duplicate.is_a?(Alumna::ServiceError) && duplicate.status == 422
raise "field path" unless duplicate.details["email"]? == "already exists"

puts "indexes ok"
